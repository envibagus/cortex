import SwiftUI

// MARK: - ProjectInsights
//
// Pure aggregation helpers that roll the global data stores up BY PROJECT, for the
// per-project tables on the home Models / Library / Stack tabs. No state of its own:
// value types + static functions. Session and config rollups are cheap (in-memory
// grouping); the tech rollup re-walks each project on disk off the main actor,
// because the global TechStack has no per-project breakdown (see note on techRollups).

// One project's rolled-up session metrics (Models tab).
struct ProjectSessionRollup: Identifiable, Sendable, Hashable {
    var id: String { projectPath }
    var projectName: String
    var projectPath: String
    var sessions: Int
    var messages: Int
    var tokens: Int
    var cost: Double
    var dominantModel: String?      // display name, most-used across the group
    var otherModels: [String]       // remaining display names, freq order
    var lastActive: Date
}

// One project's attached library config (Library tab).
struct ProjectLibraryRollup: Identifiable, Sendable, Hashable {
    var id: String { projectName }
    var projectName: String
    var skills: Int
    var agents: Int
    var commands: Int
    var mcp: Int
    var memory: Int

    var total: Int { skills + agents + commands + mcp + memory }
}

// One project's detected tech (Stack tab).
struct ProjectTechRollup: Identifiable, Sendable, Hashable {
    var id: String { projectPath }
    var projectName: String
    var projectPath: String
    var languages: [String]   // top languages by file count
    var frameworks: [String]  // detected framework / ecosystem names
}

enum ProjectInsights {

    // MARK: Models tab - sessions grouped by project

    @MainActor
    static func sessionRollups(_ sessions: [ClaudeSession]) -> [ProjectSessionRollup] {
        let groups = Dictionary(grouping: sessions, by: { $0.projectPath })
        var out: [ProjectSessionRollup] = []
        out.reserveCapacity(groups.count)

        for (path, group) in groups {
            // Rank models by how often they appear across the project's sessions, then
            // map to display names (dedup, preserving rank).
            var freq: [String: Int] = [:]
            for session in group { for model in session.models { freq[model, default: 0] += 1 } }
            var seen = Set<String>()
            var displays: [String] = []
            for (key, _) in freq.sorted(by: { $0.value > $1.value }) {
                let name = CostService.displayName(key)
                if seen.insert(name).inserted { displays.append(name) }
            }

            out.append(ProjectSessionRollup(
                projectName: group.first?.projectName ?? URL(fileURLWithPath: path).lastPathComponent,
                projectPath: path,
                sessions: group.count,
                messages: group.reduce(0) { $0 + $1.messageCount },
                tokens: group.reduce(0) { $0 + $1.usage.total },
                cost: group.reduce(0) { $0 + $1.cost },
                dominantModel: displays.first,
                otherModels: Array(displays.dropFirst()),
                lastActive: group.map(\.endedAt).max() ?? .distantPast
            ))
        }
        // Most-spent first; ties broken by most-recent activity.
        return out.sorted { ($0.cost, $0.lastActive) > ($1.cost, $1.lastActive) }
    }

    // MARK: Library tab - config grouped by project
    //
    // ConfigItem carries projectName (when not global); MCP servers and memory carry a
    // per-project `scope` (the project dir name). Hooks have no project association in
    // the data model, so they are intentionally omitted from the per-project table.

    @MainActor
    static func libraryRollups(config: ConfigScanner) -> [ProjectLibraryRollup] {
        // Every project that contributes at least one config item.
        var names = Set<String>()
        for item in config.items where !item.isGlobal {
            if let p = item.projectName, !p.isEmpty { names.insert(p) }
        }
        let generic: Set<String> = ["user", "global", "project"]
        for server in config.mcpServers where !generic.contains(server.scope) { names.insert(server.scope) }
        for memory in config.memories where memory.scope != "Global" { names.insert(memory.scope) }

        func count(_ kind: ConfigKind, _ project: String) -> Int {
            config.items.filter { !$0.isGlobal && $0.projectName == project && $0.kind == kind }.count
        }

        let rollups = names.map { project in
            ProjectLibraryRollup(
                projectName: project,
                skills: count(.skill, project),
                agents: count(.agent, project),
                commands: count(.command, project),
                mcp: config.mcpServers.filter { $0.scope == project }.count,
                memory: config.memories.filter { $0.scope == project }.count
            )
        }
        // Richest config first, then alphabetical.
        return rollups
            .filter { $0.total > 0 }
            .sorted { ($0.total, $1.projectName.lowercased()) > ($1.total, $0.projectName.lowercased()) }
    }

    // MARK: Stack tab - per-project tech, re-derived off-main
    //
    // The global ConfigScanner.techStack is a single aggregate with no per-project
    // split, and its scanners are private. So we re-walk each discovered repo here
    // (bounded, off the main actor) and detect languages by file extension and
    // frameworks by manifest. Self-contained on purpose to avoid touching ConfigScanner;
    // fold into a per-project TechStack there if that scanner is ever extended.

    static func techRollups(repos: [RepoInfo]) async -> [ProjectTechRollup] {
        let projects = repos.map { (name: $0.name, path: $0.path) }
        return await Task.detached(priority: .utility) {
            projects
                .compactMap { scanProject(name: $0.name, path: $0.path) }
                .sorted { $0.projectName.lowercased() < $1.projectName.lowercased() }
        }.value
    }

    // Walk one project (bounded), counting code files by language and detecting
    // frameworks from manifests. Returns nil if nothing recognizable was found.
    private nonisolated static func scanProject(name: String, path: String) -> ProjectTechRollup? {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path)
        let skip: Set<String> = [
            "node_modules", ".git", ".next", "dist", "build", "DerivedData", "Pods",
            ".venv", "venv", "__pycache__", "vendor", ".build", "target", ".gradle",
            "Carthage", ".idea", ".turbo", "out", "coverage", ".cache", "tmp",
        ]
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return nil }

        var langCounts: [String: Int] = [:]
        var frameworks = Set<String>()
        var budget = 800

        for case let url as URL in walker {
            if budget <= 0 { break }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if skip.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            budget -= 1
            detectManifest(url, into: &frameworks)
            if let lang = language(forExtension: url.pathExtension.lowercased()) {
                langCounts[lang, default: 0] += 1
            }
        }

        let languages = langCounts.sorted { $0.value > $1.value }.prefix(4).map(\.key)
        let frameworkList = frameworks.sorted()
        if languages.isEmpty && frameworkList.isEmpty { return nil }
        return ProjectTechRollup(projectName: name, projectPath: path,
                                 languages: Array(languages), frameworks: frameworkList)
    }

    // Detect a framework / ecosystem from a manifest file.
    private nonisolated static func detectManifest(_ url: URL, into frameworks: inout Set<String>) {
        switch url.lastPathComponent.lowercased() {
        case "package.json":
            guard let data = try? Data(contentsOf: url), data.count < 500_000,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            var deps = Set<String>()
            for key in ["dependencies", "devDependencies"] {
                if let d = json[key] as? [String: Any] { deps.formUnion(d.keys) }
            }
            for (dep, label) in jsFrameworks where deps.contains(dep) { frameworks.insert(label) }
            if !deps.contains(where: { jsFrameworks[$0] != nil }) { frameworks.insert("Node") }
        case "package.swift": frameworks.insert("SwiftPM")
        case "pubspec.yaml": frameworks.insert("Flutter")
        case "cargo.toml": frameworks.insert("Cargo")
        case "go.mod": frameworks.insert("Go")
        case "requirements.txt", "pyproject.toml", "pipfile": frameworks.insert("Python")
        case "gemfile": frameworks.insert("Ruby")
        case "composer.json": frameworks.insert("Composer")
        case "pom.xml": frameworks.insert("Maven")
        case "build.gradle", "build.gradle.kts": frameworks.insert("Gradle")
        default: break
        }
    }

    private nonisolated static let jsFrameworks: [String: String] = [
        "next": "Next.js", "react": "React", "react-native": "React Native", "expo": "Expo",
        "vue": "Vue", "nuxt": "Nuxt", "svelte": "Svelte", "@sveltejs/kit": "SvelteKit",
        "@angular/core": "Angular", "express": "Express", "fastify": "Fastify",
        "@nestjs/core": "NestJS", "vite": "Vite", "tailwindcss": "Tailwind",
        "electron": "Electron", "astro": "Astro", "@remix-run/react": "Remix",
        "solid-js": "Solid", "three": "Three.js",
    ]

    // Map a lowercased file extension to a language name, or nil to ignore (data/docs).
    private nonisolated static func language(forExtension ext: String) -> String? {
        switch ext {
        case "swift": "Swift"
        case "ts", "tsx", "mts", "cts": "TypeScript"
        case "js", "jsx", "mjs", "cjs": "JavaScript"
        case "py": "Python"
        case "rb": "Ruby"
        case "go": "Go"
        case "rs": "Rust"
        case "java": "Java"
        case "kt", "kts": "Kotlin"
        case "c": "C"
        case "h", "hpp", "hh": "C/C++ header"
        case "cpp", "cc", "cxx": "C++"
        case "m": "Objective-C"
        case "mm": "Objective-C++"
        case "cs": "C#"
        case "php": "PHP"
        case "dart": "Dart"
        case "sh", "bash", "zsh", "fish": "Shell"
        case "html", "htm": "HTML"
        case "css", "less": "CSS"
        case "scss", "sass": "SCSS"
        case "vue": "Vue"
        case "svelte": "Svelte"
        case "sql": "SQL"
        case "lua": "Lua"
        case "ex", "exs": "Elixir"
        case "scala": "Scala"
        case "hs": "Haskell"
        case "r": "R"
        case "jl": "Julia"
        default: nil
        }
    }
}
