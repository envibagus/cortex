import Foundation

// MARK: - ConfigScanner
//
// Discovers the user's AI-coding configuration on disk across many tools: skills,
// agents, commands, rules, plugins, instructions, MCP servers, hooks, and memory.
// The scan runs entirely off the main actor and publishes the parsed arrays back
// on the main actor.
//
// Broad coverage across tools:
//
//   SKILLS    global tool skill dirs (~/.claude/skills, ~/.cursor/skills, ...),
//             plugin/marketplace skills under ~/.claude/plugins (installed_plugins.json
//             + a recursive walk of cache/ and marketplaces/), and project-level
//             .claude/skills, .cursor/skills, .codex/skills, .config/amp/skills,
//             .opencode/skills across the user's repos.
//   AGENTS    global ~/.claude|.cursor|.codex/agents and project .claude|.cursor|.codex/agents.
//   COMMANDS  ~/.claude/commands/*.md and project .claude/commands/*.md.
//   RULES     ~/.cursor/rules, ~/.windsurf/rules, ~/.codeium/windsurf/memories
//             and project .cursor/rules, .windsurf/rules.
//   PLUGINS   installed_plugins.json -> one ConfigItem(.plugin) each.
//   INSTRUCT  ~/.claude/CLAUDE.md plus project CLAUDE.md / AGENTS.md.
//   MCP       union of ~/.claude.json (.mcpServers + per-project projects.<path>.mcpServers),
//             ~/.claude/.mcp.json, ~/.claude/mcp.json, ~/.mcp.json, and each project's .mcp.json.
//   MEMORY    ~/.claude/memory/*.md plus project .claude/memory/*.md.
//   HOOKS     settings.json / settings.local.json.
//
// All items are deduped by a resolved/canonical path id so the same skill installed
// for multiple tools (often via symlinks) counts once. Only structural config fields
// are read; embedded secrets (env headers, tokens) are never extracted.

@MainActor
@Observable
final class ConfigScanner {
    private(set) var items: [ConfigItem] = []      // skills / agents / commands / rules / plugins / instructions
    private(set) var mcpServers: [MCPServer] = []
    private(set) var hooks: [HookItem] = []
    private(set) var memories: [MemoryItem] = []
    // The real tech stack (languages + frameworks) detected across the scan roots.
    private(set) var techStack = TechStack()
    private(set) var isLoading = false
    private(set) var lastScan: Date?

    func items(of kind: ConfigKind) -> [ConfigItem] { items.filter { $0.kind == kind } }
    var skills: [ConfigItem] { items(of: .skill) }
    var agents: [ConfigItem] { items(of: .agent) }
    var commands: [ConfigItem] { items(of: .command) }
    var rules: [ConfigItem] { items(of: .rule) }
    var plugins: [ConfigItem] { items(of: .plugin) }
    var instructions: [ConfigItem] { items(of: .instruction) }

    /// Drop scanned config (including the per-item file contents) to free memory when the
    /// window closes. `load(roots:)` rebuilds it on next open.
    func clear() {
        items = []
        mcpServers = []
        hooks = []
        memories = []
        techStack = TechStack()
        lastScan = nil
    }

    // MARK: - Loading
    //
    // Scan off the main actor, then publish the arrays atomically on the main actor
    // so views observe one consistent snapshot.

    func load(roots: [String]) async {
        isLoading = true
        let rootURLs = roots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let parsed = await Task.detached(priority: .userInitiated) { Self.scan(roots: rootURLs) }.value
        self.items = parsed.items
        self.mcpServers = parsed.mcpServers
        self.hooks = parsed.hooks
        self.memories = parsed.memories
        self.techStack = parsed.techStack
        self.lastScan = Date()
        self.isLoading = false
    }

    // MARK: - Scan output

    nonisolated struct ScanOutput: Sendable {
        var items: [ConfigItem] = []
        var mcpServers: [MCPServer] = []
        var hooks: [HookItem] = []
        var memories: [MemoryItem] = []
        var techStack = TechStack()
    }

    // MARK: - Project roots
    //
    // The same roots RepoService walks (passed in from the user's configured scan
    // roots). Project directories are discovered as the immediate subdirectories AND
    // one level deeper (depth <= 2), skipping heavy build/vendor directories,
    // mirroring RepoService.collectRepos.

    private static let skipDirNames: Set<String> = [
        "node_modules", "Pods", "build", "DerivedData", ".build",
        "vendor", "dist", ".next", ".git",
    ]

    // MARK: - Top-level scan (off-main)

    nonisolated static func scan(roots: [URL]) -> ScanOutput {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let claude = home.appendingPathComponent(".claude")

        // Resolve the set of project directories once and reuse for every per-project source.
        let projects = discoverProjectDirectories(roots: roots)

        var out = ScanOutput()

        // Config items, deduped by resolved/canonical id.
        var collector = ItemCollector()
        collectGlobalSkills(home: home, into: &collector)
        collectPluginSkills(claude: claude, into: &collector)
        collectGlobalAgents(home: home, into: &collector)
        collectGlobalCommands(claude: claude, into: &collector)
        collectGlobalRules(home: home, into: &collector)
        collectProjectConfigs(projects: projects, into: &collector)
        var allItems = collector.items

        // Plugins (the Plugins tab) and instructions are listed, not path-deduped as skills.
        allItems += scanPlugins(in: claude.appendingPathComponent("plugins"))
        allItems += scanInstructions(claude: claude, projects: projects)
        out.items = allItems.sorted {
            $0.kind == $1.kind
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.kind.rawValue < $1.kind.rawValue
        }

        out.mcpServers = scanMCPServers(claude: claude, home: home, projects: projects)
        out.hooks = scanHooks(claude: claude)
        out.memories = scanMemories(claude: claude, projects: projects)
        out.techStack = scanTechStack(projects: projects)
        return out
    }

    // MARK: - Tech stack (languages + frameworks across the scanned repos)
    //
    // Languages come from a bounded file-extension census per project (no file reads,
    // just path checks, capped so big repos can't stall the scan). Frameworks come
    // from parsing each project's root manifests (package.json, Package.swift, etc.).
    // Both are approximate-by-design: this is an at-a-glance overview, not a SBOM.

    private nonisolated static func scanTechStack(projects: [URL]) -> TechStack {
        var fileCountByLanguage: [String: Int] = [:]
        // language name -> set of project names that contain at least one file of it
        var projectsByLanguage: [String: Set<String>] = [:]
        // framework name -> (icon, set of project names that use it)
        var frameworkRepos: [String: (icon: String, repos: Set<String>)] = [:]

        for project in projects {
            let projectName = project.lastPathComponent
            countLanguages(in: project, projectName: projectName, depth: 0, maxDepth: 3,
                           budget: Box(400), into: &fileCountByLanguage, projects: &projectsByLanguage)
            detectFrameworks(in: project, projectName: projectName, into: &frameworkRepos)
        }

        let total = fileCountByLanguage.values.reduce(0, +)
        let languages = fileCountByLanguage
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(12)
            .map { name, count in
                LanguageUsage(name: name, fileCount: count,
                              percent: total > 0 ? Int((Double(count) / Double(total) * 100).rounded()) : 0,
                              projectCount: projectsByLanguage[name]?.count ?? 0)
            }
        let frameworks = frameworkRepos
            .map { name, v in FrameworkUsage(name: name, icon: v.icon, repoCount: v.repos.count) }
            .sorted { $0.repoCount != $1.repoCount ? $0.repoCount > $1.repoCount : $0.name < $1.name }

        return TechStack(languages: Array(languages), frameworks: frameworks)
    }

    /// A tiny reference counter so the bounded file budget is shared across recursion.
    private final class Box { var remaining: Int; init(_ n: Int) { remaining = n } }

    /// Bounded extension census for one project: counts source files by language,
    /// skipping vendor/build dirs and stopping once the per-project budget is spent.
    private nonisolated static func countLanguages(
        in dir: URL, projectName: String, depth: Int, maxDepth: Int, budget: Box,
        into counts: inout [String: Int], projects: inout [String: Set<String>]
    ) {
        guard budget.remaining > 0 else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return }

        for entry in entries {
            if budget.remaining <= 0 { return }
            if isDirectory(entry) {
                if skipDirNames.contains(entry.lastPathComponent) { continue }
                if depth < maxDepth {
                    countLanguages(in: entry, projectName: projectName, depth: depth + 1, maxDepth: maxDepth,
                                   budget: budget, into: &counts, projects: &projects)
                }
            } else if let lang = language(forExtension: entry.pathExtension.lowercased()) {
                counts[lang, default: 0] += 1
                // Record that THIS project contains the language (for the "in N projects" line).
                projects[lang, default: []].insert(projectName)
                budget.remaining -= 1
            }
        }
    }

    /// Map a file extension to a human language name (nil = not a tracked source file).
    private nonisolated static func language(forExtension ext: String) -> String? {
        switch ext {
        case "swift": return "Swift"
        case "ts", "tsx": return "TypeScript"
        case "js", "jsx", "mjs", "cjs": return "JavaScript"
        case "py": return "Python"
        case "rb": return "Ruby"
        case "go": return "Go"
        case "rs": return "Rust"
        case "java": return "Java"
        case "kt", "kts": return "Kotlin"
        case "c", "h": return "C"
        case "cpp", "cc", "cxx", "hpp": return "C++"
        case "m", "mm": return "Objective-C"
        case "cs": return "C#"
        case "php": return "PHP"
        case "dart": return "Dart"
        case "sh", "bash", "zsh": return "Shell"
        case "css", "scss", "sass", "less": return "CSS"
        case "html", "htm": return "HTML"
        case "vue": return "Vue"
        case "svelte": return "Svelte"
        case "sql": return "SQL"
        default: return nil
        }
    }

    /// Parse a project's root manifests for the frameworks/libraries it depends on.
    private nonisolated static func detectFrameworks(
        in project: URL, projectName: String, into out: inout [String: (icon: String, repos: Set<String>)]
    ) {
        func note(_ name: String, _ icon: String) {
            out[name, default: (icon, [])].repos.insert(projectName)
        }
        let fm = FileManager.default

        // package.json -> JS/TS frameworks (dependencies + devDependencies keys).
        let pkg = project.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: pkg),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var deps: [String] = []
            for key in ["dependencies", "devDependencies"] {
                if let map = root[key] as? [String: Any] { deps += map.keys }
            }
            for dep in deps {
                if let pretty = jsFramework(dep) { note(pretty, "shippingbox") }
            }
        }
        // Swift Package.swift -> Swift Package Manager.
        if fm.fileExists(atPath: project.appendingPathComponent("Package.swift").path) {
            note("Swift Package Manager", "swift")
        }
        // Python requirements / pyproject -> a few well-known frameworks.
        for pyFile in ["requirements.txt", "pyproject.toml"] {
            let url = project.appendingPathComponent(pyFile)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let lower = text.lowercased()
                for (needle, pretty) in pyFrameworks where lower.contains(needle) { note(pretty, "shippingbox") }
            }
        }
        // Other ecosystems: presence of the manifest is enough to name the framework.
        let manifests: [(String, String, String)] = [
            ("Cargo.toml", "Cargo (Rust)", "shippingbox"),
            ("go.mod", "Go modules", "shippingbox"),
            ("Gemfile", "Bundler (Ruby)", "shippingbox"),
            ("pubspec.yaml", "Flutter / Dart", "shippingbox"),
            ("composer.json", "Composer (PHP)", "shippingbox"),
            ("pom.xml", "Maven (Java)", "shippingbox"),
            ("build.gradle", "Gradle", "shippingbox"),
            ("build.gradle.kts", "Gradle", "shippingbox"),
        ]
        for (file, pretty, icon) in manifests where fm.fileExists(atPath: project.appendingPathComponent(file).path) {
            note(pretty, icon)
        }
    }

    /// Map a notable npm package name to a display name (nil = not highlighted).
    private nonisolated static func jsFramework(_ dep: String) -> String? {
        switch dep {
        case "react", "react-dom": return "React"
        case "next": return "Next.js"
        case "vue": return "Vue"
        case "svelte", "@sveltejs/kit": return "Svelte"
        case "@angular/core": return "Angular"
        case "express": return "Express"
        case "fastify": return "Fastify"
        case "@nestjs/core": return "NestJS"
        case "tailwindcss": return "Tailwind CSS"
        case "vite": return "Vite"
        case "electron": return "Electron"
        case "three": return "Three.js"
        case "@supabase/supabase-js": return "Supabase"
        case "prisma", "@prisma/client": return "Prisma"
        case "typescript": return "TypeScript"
        default: return nil
        }
    }

    /// Python framework needles matched (case-insensitively) in requirements/pyproject.
    private nonisolated static let pyFrameworks: [(String, String)] = [
        ("django", "Django"), ("flask", "Flask"), ("fastapi", "FastAPI"),
        ("torch", "PyTorch"), ("tensorflow", "TensorFlow"), ("pandas", "pandas"),
        ("numpy", "NumPy"), ("streamlit", "Streamlit"),
    ]

    // MARK: - Project discovery
    //
    // Immediate subdirectories of each root plus one extra level (depth <= 2), so
    // monorepo children (e.g. myorg/web-app) are also probed. A directory that
    // looks like a project (has .git OR any tool config dir) stops descent.

    private nonisolated static func discoverProjectDirectories(roots: [URL]) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        for root in roots {
            collectProjectDirs(in: root, depth: 0, maxDepth: 2, into: &out, seen: &seen)
        }
        return out
    }

    private nonisolated static func collectProjectDirs(
        in dir: URL, depth: Int, maxDepth: Int, into out: inout [URL], seen: inout Set<String>
    ) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return }

        // Treat any directory at depth >= 1 as a candidate project: probe it.
        if depth >= 1, seen.insert(dir.path).inserted {
            out.append(dir)
        }

        // Stop descending once this directory is itself a git repo.
        let gitPath = dir.appendingPathComponent(".git").path
        if depth >= 1, fm.fileExists(atPath: gitPath) { return }

        guard depth < maxDepth,
              let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        else { return }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") || skipDirNames.contains(name) { continue }
            guard isDirectory(entry) else { continue }
            collectProjectDirs(in: entry, depth: depth + 1, maxDepth: maxDepth, into: &out, seen: &seen)
        }
    }

    // MARK: - Global skills
    //
    // Each tool's global skills directory, when it exists. A skill dir is a folder
    // of <skill>/SKILL.md (or <skill>/AGENTS.md), with loose *.md/*.mdc also accepted.

    private nonisolated static func collectGlobalSkills(home: URL, into collector: inout ItemCollector) {
        let configHome = xdgConfigHome(home: home)
        let dirs: [(String, ToolKind)] = [
            (".claude/skills", .claude),
            (".cursor/skills", .cursor),
            (".codex/skills", .codex),
            (".copilot/skills", .claude),          // no copilot ToolKind; closest is claude
            (".augment/skills", .claude),          // no augment ToolKind; closest is claude
            (".agents/skills", .claude),           // global agents dir
            (".gemini/antigravity/skills", .antigravity),
            (".pi/agent/skills", .custom),
        ]
        for (sub, tool) in dirs {
            collectFromDirectory(home.appendingPathComponent(sub),
                                 tool: tool, kind: .skill, isGlobal: true, projectName: nil,
                                 into: &collector)
        }
        // XDG-based tools (amp / opencode) live under $XDG_CONFIG_HOME (default ~/.config).
        collectFromDirectory(configHome.appendingPathComponent("amp/skills"),
                             tool: .amp, kind: .skill, isGlobal: true, projectName: nil, into: &collector)
        collectFromDirectory(configHome.appendingPathComponent("opencode/skills"),
                             tool: .opencode, kind: .skill, isGlobal: true, projectName: nil, into: &collector)
    }

    // MARK: - Plugin skills
    //
    // The largest source of skills. Three passes, all deduped by resolved path:
    //   1. installed_plugins.json -> each installPath/skills/<skill>/SKILL.md
    //   2. recursive walk of ~/.claude/plugins/cache for any <dir>/SKILL.md
    //   3. recursive walk of ~/.claude/plugins/marketplaces for any <dir>/SKILL.md
    // All are attributed to the .claude source.

    private nonisolated static func collectPluginSkills(claude: URL, into collector: inout ItemCollector) {
        let pluginsDir = claude.appendingPathComponent("plugins")

        // 1. installed_plugins.json -> installPath/skills.
        let installedFile = pluginsDir.appendingPathComponent("installed_plugins.json")
        if let data = try? Data(contentsOf: installedFile),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let pluginsMap = (root["plugins"] as? [String: Any]) ?? root
            for (_, value) in pluginsMap {
                for record in pluginRecords(value) {
                    guard let installPath = (record["installPath"] as? String)?.nilIfEmpty else { continue }
                    let skillsDir = URL(fileURLWithPath: installPath).appendingPathComponent("skills")
                    collectFromDirectory(skillsDir, tool: .claude, kind: .skill,
                                         isGlobal: true, projectName: nil, into: &collector)
                }
            }
        }

        // 2 & 3. Recursive walk of cache/ and marketplaces/ for any SKILL.md.
        for sub in ["cache", "marketplaces"] {
            collectSkillFilesRecursively(pluginsDir.appendingPathComponent(sub),
                                         tool: .claude, depth: 0, maxDepth: 6, into: &collector)
        }
    }

    /// Walk a directory tree (bounded depth) collecting every `<dir>/SKILL.md`.
    /// Skips heavy/vendor directories. Each SKILL.md becomes a .skill item, deduped
    /// by resolved path so cache + marketplaces overlap (and symlinks) merge.
    private nonisolated static func collectSkillFilesRecursively(
        _ dir: URL, tool: ToolKind, depth: Int, maxDepth: Int, into collector: inout ItemCollector
    ) {
        let fm = FileManager.default
        let resolved = dir.resolvingSymlinksInPath()
        guard let entries = try? fm.contentsOfDirectory(
            at: resolved, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return }

        // A SKILL.md directly inside this directory makes it a skill.
        let skillFile = resolved.appendingPathComponent("SKILL.md")
        if fm.fileExists(atPath: skillFile.path) {
            addSkillLike(file: skillFile, dirName: resolved.lastPathComponent, isDir: true,
                         tool: tool, kind: .skill, isGlobal: true, projectName: nil, into: &collector)
        }

        guard depth < maxDepth else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            if skipDirNames.contains(name) { continue }
            guard isDirectory(entry) else { continue }
            collectSkillFilesRecursively(entry, tool: tool, depth: depth + 1, maxDepth: maxDepth, into: &collector)
        }
    }

    /// Reduce a plugin entry's value to its install records (array-of-records or single dict).
    private nonisolated static func pluginRecords(_ value: Any) -> [[String: Any]] {
        if let records = value as? [[String: Any]] { return records }
        if let record = value as? [String: Any] { return [record] }
        return []
    }

    // MARK: - Global agents / commands / rules

    private nonisolated static func collectGlobalAgents(home: URL, into collector: inout ItemCollector) {
        let dirs: [(String, ToolKind)] = [
            (".claude/agents", .claude),
            (".cursor/agents", .cursor),
            (".codex/agents", .codex),
        ]
        for (sub, tool) in dirs {
            collectFromDirectory(home.appendingPathComponent(sub),
                                 tool: tool, kind: .agent, isGlobal: true, projectName: nil, into: &collector)
        }
    }

    private nonisolated static func collectGlobalCommands(claude: URL, into collector: inout ItemCollector) {
        collectFromDirectory(claude.appendingPathComponent("commands"),
                             tool: .claude, kind: .command, isGlobal: true, projectName: nil, into: &collector)
    }

    private nonisolated static func collectGlobalRules(home: URL, into collector: inout ItemCollector) {
        let dirs: [(String, ToolKind)] = [
            (".claude/rules", .claude),
            (".cursor/rules", .cursor),
            (".windsurf/rules", .windsurf),
            (".codeium/windsurf/memories", .windsurf),
        ]
        for (sub, tool) in dirs {
            collectFromDirectory(home.appendingPathComponent(sub),
                                 tool: tool, kind: .rule, isGlobal: true, projectName: nil, into: &collector)
        }
    }

    // MARK: - Project-level configs
    //
    // For each project directory, probe well-known tool subpaths and scan each as
    // skills / agents / commands / rules. Items are global=false and carry the
    // project directory name.

    private nonisolated static func collectProjectConfigs(projects: [URL], into collector: inout ItemCollector) {
        let probes: [(String, ToolKind, ConfigKind)] = [
            (".claude/skills", .claude, .skill),
            (".cursor/skills", .cursor, .skill),
            (".codex/skills", .codex, .skill),
            (".config/amp/skills", .amp, .skill),
            (".opencode/skills", .opencode, .skill),
            (".claude/agents", .claude, .agent),
            (".cursor/agents", .cursor, .agent),
            (".codex/agents", .codex, .agent),
            (".claude/commands", .claude, .command),
            (".cursor/rules", .cursor, .rule),
            (".windsurf/rules", .windsurf, .rule),
        ]
        for project in projects {
            let projectName = project.lastPathComponent
            for (sub, tool, kind) in probes {
                collectFromDirectory(project.appendingPathComponent(sub),
                                     tool: tool, kind: kind, isGlobal: false,
                                     projectName: projectName, into: &collector)
            }
        }
    }

    // MARK: - Shared directory collector
    //
    // Given a directory, collect skill/agent/command/rule items from:
    //   - subdirectories that contain a SKILL.md or AGENTS.md (directory style)
    //   - loose *.md / *.mdc files (excluding meta files like README/CLAUDE/AGENTS)
    // Symlinked directories are followed via resolvingSymlinksInPath. Each item is
    // deduped by its resolved path so the same file seen via multiple tools merges.

    private nonisolated static func collectFromDirectory(
        _ directory: URL, tool: ToolKind, kind: ConfigKind, isGlobal: Bool, projectName: String?,
        into collector: inout ItemCollector
    ) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else { return }

        let resolvedDir = directory.resolvingSymlinksInPath()
        guard let entries = try? fm.contentsOfDirectory(
            at: resolvedDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return }

        for entry in entries {
            if isDirectory(entry) {
                let skillFile = entry.appendingPathComponent("SKILL.md")
                let agentsFile = entry.appendingPathComponent("AGENTS.md")
                if fm.fileExists(atPath: skillFile.path) {
                    addSkillLike(file: skillFile, dirName: entry.lastPathComponent, isDir: true,
                                 tool: tool, kind: kind, isGlobal: isGlobal, projectName: projectName,
                                 into: &collector)
                } else if fm.fileExists(atPath: agentsFile.path) {
                    addSkillLike(file: agentsFile, dirName: entry.lastPathComponent, isDir: true,
                                 tool: tool, kind: kind, isGlobal: isGlobal, projectName: projectName,
                                 into: &collector)
                } else if kind == .agent, let primary = preferredMarkdownFile(in: entry) {
                    // A directory-style agent that uses an arbitrarily named *.md.
                    addSkillLike(file: primary, dirName: entry.lastPathComponent, isDir: true,
                                 tool: tool, kind: kind, isGlobal: isGlobal, projectName: projectName,
                                 into: &collector)
                }
            } else {
                let ext = entry.pathExtension.lowercased()
                guard ext == "md" || ext == "mdc" else { continue }
                guard !ignoredFileNames.contains(entry.lastPathComponent) else { continue }
                addSkillLike(file: entry, dirName: entry.deletingPathExtension().lastPathComponent, isDir: false,
                             tool: tool, kind: kind, isGlobal: isGlobal, projectName: projectName,
                             into: &collector)
            }
        }
    }

    /// Filenames that are tool config / meta files, not skills.
    private static let ignoredFileNames: Set<String> = [
        "README.md", "README", "CLAUDE.md", "AGENTS.md", "AGENTS.override.md",
        "global_rules.md", "SYSTEM.md", "APPEND_SYSTEM.md",
        "LICENSE.md", "LICENSE", "CHANGELOG.md",
    ]

    /// Pick the primary markdown file for a directory-style agent: prefer a file
    /// matching the directory name, else the sole candidate, else nil.
    private nonisolated static func preferredMarkdownFile(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return nil }
        let candidates = entries.filter { url in
            let ext = url.pathExtension.lowercased()
            guard ext == "md" || ext == "mdc" else { return false }
            return !ignoredFileNames.contains(url.lastPathComponent)
        }
        let dirName = directory.lastPathComponent.lowercased()
        if let match = candidates.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == dirName }) {
            return match
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Build one skill/agent/command/rule ConfigItem from a markdown file and add it
    /// to the collector (deduping by canonical resolved path).
    private nonisolated static func addSkillLike(
        file: URL, dirName: String, isDir: Bool, tool: ToolKind, kind: ConfigKind,
        isGlobal: Bool, projectName: String?, into collector: inout ItemCollector
    ) {
        let physical = file.resolvingSymlinksInPath()
        let content = (try? String(contentsOf: physical, encoding: .utf8))
            ?? (try? String(contentsOf: file, encoding: .utf8))
            ?? ""
        let front = frontmatter(in: content)
        let name = front["name"]?.nilIfEmpty ?? firstHeading(in: content) ?? dirName
        let detail = front["description"]?.nilIfEmpty
            ?? firstParagraph(in: content)
            ?? kind.singular
        let attrs = fileAttributes(physical)
        let resolvedID = canonicalResolvedID(for: file)

        let item = ConfigItem(
            id: resolvedID,
            name: name,
            detail: detail,
            path: file.path,
            kind: kind,
            source: tool,
            isGlobal: isGlobal,
            projectName: projectName,
            fileSize: attrs.size,
            modified: attrs.modified,
            content: content,
            frontmatter: front
        )
        collector.add(item)
    }

    /// Canonical, stable id for a skill/agent file. Plugin cache paths embed volatile
    /// version components, so collapse them to a version-free identity so the same
    /// plugin skill (cache vs marketplace, or across versions) dedupes to one entry.
    private nonisolated static func canonicalResolvedID(for fileURL: URL) -> String {
        let resolved = fileURL.resolvingSymlinksInPath().path
        let path = fileURL.path

        // .../.claude/plugins/cache/<publisher>/<plugin>/<version>/skills/<skill>/SKILL.md
        if let range = path.range(of: ".claude/plugins/cache/") {
            let parts = String(path[range.upperBound...]).components(separatedBy: "/")
            if parts.count >= 6, parts[3] == "skills" {
                return "claude-plugin:\(parts[0])/\(parts[1])/\(parts[4])"
            }
        }
        // .../.claude/plugins/marketplaces/<marketplace>/<skill>/SKILL.md
        if let range = path.range(of: ".claude/plugins/marketplaces/") {
            let parts = String(path[range.upperBound...]).components(separatedBy: "/")
            if parts.count >= 3, parts.last == "SKILL.md" {
                // Use marketplace + skill folder name; ignore intervening version dirs.
                let marketplace = parts[0]
                let skill = parts[parts.count - 2]
                return "claude-plugin:\(marketplace)/\(skill)"
            }
        }
        return resolved
    }

    // MARK: - Plugins (the Plugins tab)
    //
    // Installed Claude Code plugins from ~/.claude/plugins/installed_plugins.json,
    // each surfaced as one ConfigItem(.plugin). Separate from plugin SKILLS above.

    private nonisolated static func scanPlugins(in dir: URL) -> [ConfigItem] {
        let file = dir.appendingPathComponent("installed_plugins.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        let pluginsMap = (root["plugins"] as? [String: Any]) ?? root
        var out: [ConfigItem] = []
        for (rawKey, value) in pluginsMap {
            guard let record = pluginRecords(value).first else { continue }
            if let item = pluginItem(rawKey: rawKey, record: record) {
                out.append(item)
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Build one plugin ConfigItem from a "name@marketplace" key and its install record.
    private nonisolated static func pluginItem(rawKey: String, record: [String: Any]) -> ConfigItem? {
        let parts = rawKey.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts.first.map(String.init)?.nilIfEmpty ?? rawKey
        let marketplace = parts.count > 1 ? String(parts[1]).nilIfEmpty : nil

        let installPath = (record["installPath"] as? String)?.nilIfEmpty
        let version = (record["version"] as? String)?.nilIfEmpty

        var bits: [String] = []
        if let marketplace { bits.append(marketplace) }
        if let version { bits.append("v\(version)") }
        if bits.isEmpty, let installPath {
            bits.append(URL(fileURLWithPath: installPath).lastPathComponent)
        }
        let detail = bits.isEmpty ? "Plugin" : bits.joined(separator: " · ")

        var content = ""
        var size = 0
        var modified = Date(timeIntervalSince1970: 0)
        if let installPath {
            let installURL = URL(fileURLWithPath: installPath)
            let manifest = installURL.appendingPathComponent("plugin.json")
            let readme = installURL.appendingPathComponent("README.md")
            if let manifestText = (try? String(contentsOf: manifest, encoding: .utf8))?.nilIfEmpty {
                content = manifestText
            } else if let readmeText = (try? String(contentsOf: readme, encoding: .utf8))?.nilIfEmpty {
                content = readmeText
            }
            let attrs = fileAttributes(installURL)
            size = attrs.size
            modified = attrs.modified
        }

        return ConfigItem(
            id: "plugin:\(rawKey)",
            name: name,
            detail: detail,
            path: installPath ?? rawKey,
            kind: .plugin,
            source: .claude,
            isGlobal: true,
            projectName: nil,
            fileSize: size,
            modified: modified,
            content: content,
            frontmatter: [:]
        )
    }

    // MARK: - Instructions
    //
    // The global ~/.claude/CLAUDE.md, plus CLAUDE.md and AGENTS.md found in each
    // discovered project directory.

    private nonisolated static func scanInstructions(claude: URL, projects: [URL]) -> [ConfigItem] {
        var out: [ConfigItem] = []

        let globalFile = claude.appendingPathComponent("CLAUDE.md")
        if let item = instructionItem(file: globalFile, name: "Global") {
            out.append(item)
        }

        for project in projects {
            for fileName in ["CLAUDE.md", "AGENTS.md"] {
                let file = project.appendingPathComponent(fileName)
                if let item = instructionItem(file: file, name: project.lastPathComponent, detail: fileName) {
                    out.append(item)
                }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func instructionItem(file: URL, name: String, detail: String? = nil) -> ConfigItem? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let attrs = fileAttributes(file)
        return ConfigItem(
            id: file.path,
            name: name,
            detail: detail ?? file.lastPathComponent,
            path: file.path,
            kind: .instruction,
            source: .claude,
            isGlobal: true,
            projectName: nil,
            fileSize: attrs.size,
            modified: attrs.modified,
            content: content,
            frontmatter: [:]
        )
    }

    // MARK: - MCP servers
    //
    // Union over: ~/.claude.json (top-level .mcpServers AND per-project
    // projects.<path>.mcpServers), ~/.claude/.mcp.json, ~/.claude/mcp.json,
    // ~/.mcp.json, and each project's .mcp.json. Deduped by name (first seen wins).
    // A server first seen in a project carries that project as its scope.

    private nonisolated static func scanMCPServers(claude: URL, home: URL, projects: [URL]) -> [MCPServer] {
        let needsAuth = authNeedingNames(claude: claude)
        var byName: [String: MCPServer] = [:]
        var order: [String] = []

        func ingest(_ pairs: [(String, [String: Any])], scope: String) {
            for (name, value) in pairs where byName[name] == nil {
                guard let server = makeServer(name: name, value: value, scope: scope, needsAuth: needsAuth)
                else { continue }
                byName[name] = server
                order.append(name)
            }
        }

        // User-scope global config files first (these take precedence over project ones).
        ingest(mcpServerObjects(at: home.appendingPathComponent(".claude.json")), scope: "user")
        ingest(mcpServerObjects(at: claude.appendingPathComponent(".mcp.json")), scope: "user")
        ingest(mcpServerObjects(at: claude.appendingPathComponent("mcp.json")), scope: "user")
        ingest(mcpServerObjects(at: home.appendingPathComponent(".mcp.json")), scope: "user")

        // Per-project mcpServers nested inside ~/.claude.json (projects.<path>.mcpServers).
        for (projectPath, pairs) in projectScopedMCP(at: home.appendingPathComponent(".claude.json")) {
            let scope = URL(fileURLWithPath: projectPath).lastPathComponent
            ingest(pairs, scope: scope)
        }

        // Each discovered project's own .mcp.json.
        for project in projects {
            let file = project.appendingPathComponent(".mcp.json")
            ingest(mcpServerObjects(at: file), scope: project.lastPathComponent)
        }

        return order.compactMap { byName[$0] }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Top-level "mcpServers" object from a JSON file, if any.
    private nonisolated static func mcpServerObjects(at url: URL) -> [(String, [String: Any])] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return [] }
        return servers.compactMap { key, value in
            (value as? [String: Any]).map { (key, $0) }
        }
    }

    /// Per-project "mcpServers" nested under projects.<path>.mcpServers in ~/.claude.json.
    private nonisolated static func projectScopedMCP(at url: URL) -> [(String, [(String, [String: Any])])] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else { return [] }
        var out: [(String, [(String, [String: Any])])] = []
        for (projectPath, value) in projects {
            guard let dict = value as? [String: Any],
                  let servers = dict["mcpServers"] as? [String: Any] else { continue }
            let pairs: [(String, [String: Any])] = servers.compactMap { key, v in
                (v as? [String: Any]).map { (key, $0) }
            }
            if !pairs.isEmpty { out.append((projectPath, pairs)) }
        }
        return out
    }

    /// Build one MCPServer. stdio when a "command" is present, else sse/http by type/url.
    private nonisolated static func makeServer(
        name: String, value: [String: Any], scope: String, needsAuth: Set<String>
    ) -> MCPServer? {
        let auth = needsAuth.contains(name)
        if let command = (value["command"] as? String)?.nilIfEmpty {
            let args = (value["args"] as? [Any])?.compactMap { ($0 as? CustomStringConvertible)?.description } ?? []
            let full = ([command] + args).joined(separator: " ")
            return MCPServer(
                id: name, name: name, transport: "stdio",
                command: full, url: nil, scope: scope,
                needsAuth: auth, toolCount: 0
            )
        }
        if let url = (value["url"] as? String)?.nilIfEmpty {
            let type = (value["type"] as? String)?.lowercased()
            let transport = type == "sse" ? "sse" : "http"
            return MCPServer(
                id: name, name: name, transport: transport,
                command: nil, url: url, scope: scope,
                needsAuth: auth, toolCount: 0
            )
        }
        return nil
    }

    /// Best-effort set of server names needing auth, from ~/.claude/mcp-needs-auth-cache.json.
    private nonisolated static func authNeedingNames(claude: URL) -> Set<String> {
        let url = claude.appendingPathComponent("mcp-needs-auth-cache.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return Set(root.keys)
    }

    // MARK: - Hooks
    //
    // Flatten the "hooks" object from settings.json and settings.local.json.
    // Shape: { EventName: [ { matcher?, hooks: [ { type, command } ] } ] }.

    private nonisolated static func scanHooks(claude: URL) -> [HookItem] {
        var out: [HookItem] = []
        for fileName in ["settings.json", "settings.local.json"] {
            let url = claude.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hooks = root["hooks"] as? [String: Any] else { continue }

            for (event, rawGroups) in hooks {
                guard let groups = rawGroups as? [[String: Any]] else { continue }
                for group in groups {
                    let matcher = (group["matcher"] as? String)?.nilIfEmpty
                    let inner = (group["hooks"] as? [[String: Any]]) ?? []
                    for hook in inner {
                        guard let command = (hook["command"] as? String)?.nilIfEmpty else { continue }
                        out.append(HookItem(
                            id: "\(fileName):\(event):\(matcher ?? ""):\(command)",
                            event: event,
                            matcher: matcher,
                            command: command,
                            source: fileName
                        ))
                    }
                }
            }
        }
        return out.sorted {
            $0.event == $1.event
                ? $0.command < $1.command
                : $0.event.localizedCaseInsensitiveCompare($1.event) == .orderedAscending
        }
    }

    // MARK: - Memory
    //
    // Three sources: ~/.claude/memory/*.md (Global), the per-project agent memory under
    // ~/.claude/projects/<slug>/memory/*.md (where Claude Code actually keeps project
    // memories - this is the big one, easily 100s of files), and each scanned repo's
    // own .claude/memory/*.md. The "hook" line is the first meaningful line.

    private nonisolated static func scanMemories(claude: URL, projects: [URL]) -> [MemoryItem] {
        var out: [MemoryItem] = []

        // Global agent memory.
        out += memoryItems(in: claude.appendingPathComponent("memory"), scope: "Global")

        // Per-project agent memory: ~/.claude/projects/<slug>/memory/. The <slug> is the
        // project cwd with "/" -> "-". Resolve it to a readable name by matching the
        // user's known project dirs (exact + hyphen-safe, since encoding a real path
        // preserves its hyphens), falling back to a best-effort slug decode.
        let nameBySlug = Dictionary(
            projects.map { ($0.path.replacingOccurrences(of: "/", with: "-"), $0.lastPathComponent) },
            uniquingKeysWith: { first, _ in first }
        )
        let projectsRoot = claude.appendingPathComponent("projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for dir in dirs {
            let slug = dir.lastPathComponent
            let decoded = URL(fileURLWithPath: SessionStore.decodeSlug(slug)).lastPathComponent
            let scope = nameBySlug[slug] ?? (decoded.isEmpty ? slug : decoded)
            out += memoryItems(in: dir.appendingPathComponent("memory"), scope: scope)
        }

        // Repo-level memory committed inside a working tree.
        for project in projects {
            let dir = project.appendingPathComponent(".claude/memory")
            out += memoryItems(in: dir, scope: project.lastPathComponent)
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func memoryItems(in dir: URL, scope: String) -> [MemoryItem] {
        markdownFiles(in: dir).map { file in
            let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let attrs = fileAttributes(file)
            let hook = firstNonEmptyLine(in: content).map(stripMarkdown) ?? "Memory"
            return MemoryItem(
                id: file.path,
                name: file.lastPathComponent,
                hook: hook,
                path: file.path,
                scope: scope,
                modified: attrs.modified,
                sizeBytes: attrs.size
            )
        }
    }

    // MARK: - Environment

    private nonisolated static func xdgConfigHome(home: URL) -> URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
        }
        return home.appendingPathComponent(".config")
    }

    // MARK: - YAML frontmatter parser
    //
    // Extracts "key: value" pairs from a leading --- ... --- block. Handles flat
    // scalars (stripping matching surrounding quotes) AND block scalars - the folded
    // (">", ">-") and literal ("|", "|-") styles where the value lives on the
    // following more-indented lines. Without the block-scalar handling, a common
    // `description: >-` agent header was parsed as the literal string ">-" instead of
    // the paragraph that follows it. Nested mappings and list items are ignored.

    nonisolated static func frontmatter(in content: String) -> [String: String] {
        let lines = content.components(separatedBy: "\n")
        guard let firstReal = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[firstReal].trimmingCharacters(in: .whitespaces) == "---" else { return [:] }

        var result: [String: String] = [:]
        var i = firstReal + 1
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." { break }   // end of block
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("-") {
                i += 1; continue                                // blank / comment / list item
            }
            guard let colon = trimmed.firstIndex(of: ":") else { i += 1; continue }

            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { i += 1; continue }
            let rawValue = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            // Block scalar: the value indicator is ">" or "|" (optionally followed by a
            // chomping "-"/"+" and/or an indent digit). The real text is the run of
            // following lines indented deeper than this key; fold them into one line.
            if let indicator = rawValue.first, indicator == ">" || indicator == "|" {
                let keyIndent = raw.prefix { $0 == " " }.count
                var blockLines: [String] = []
                i += 1
                while i < lines.count {
                    let bl = lines[i]
                    let blTrimmed = bl.trimmingCharacters(in: .whitespaces)
                    if blTrimmed == "---" || blTrimmed == "..." { break }
                    if blTrimmed.isEmpty { i += 1; continue }   // blank line inside the block
                    if bl.prefix(while: { $0 == " " }).count <= keyIndent { break }  // dedent = sibling key
                    blockLines.append(blTrimmed)
                    i += 1
                }
                // Fold to a single space-joined line (the detail field is shown on one
                // line); good enough as a one-line summary of a multi-line description.
                result[key] = blockLines.joined(separator: " ")
            } else {
                result[key] = unquote(rawValue)
                i += 1
            }
        }
        return result
    }

    /// Strip a single pair of matching surrounding quotes.
    private nonisolated static func unquote(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, let last = s.last else { return s }
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    // MARK: - Markdown text helpers

    /// First markdown heading text (a line beginning with one or more "#").
    private nonisolated static func firstHeading(in content: String) -> String? {
        for line in linesAfterFrontmatter(content) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let text = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// First non-empty, non-heading paragraph line (good as a description fallback).
    private nonisolated static func firstParagraph(in content: String) -> String? {
        for line in linesAfterFrontmatter(content) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            return stripMarkdown(trimmed)
        }
        return nil
    }

    /// First non-empty line of the whole document (after the frontmatter block).
    private nonisolated static func firstNonEmptyLine(in content: String) -> String? {
        linesAfterFrontmatter(content)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// Document lines with any leading frontmatter block removed.
    private nonisolated static func linesAfterFrontmatter(_ content: String) -> [String] {
        let lines = content.components(separatedBy: "\n")
        guard let firstReal = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[firstReal].trimmingCharacters(in: .whitespaces) == "---" else { return lines }
        // Find the closing fence after the opening one.
        if let closeOffset = lines[(firstReal + 1)...].firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces); return t == "---" || t == "..."
        }) {
            return Array(lines[(closeOffset + 1)...])
        }
        return lines
    }

    /// Remove light markdown decoration from a single line.
    private nonisolated static func stripMarkdown(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        while let first = s.first, first == "#" || first == ">" || first == "-" || first == "*" || first == "+" {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = collapseLinks(s)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Reduce markdown links "[label](target)" to just "label".
    private nonisolated static func collapseLinks(_ input: String) -> String {
        var result = ""
        var rest = Substring(input)
        while let open = rest.firstIndex(of: "[") {
            result += rest[..<open]
            let afterOpen = rest[rest.index(after: open)...]
            guard let close = afterOpen.firstIndex(of: "]") else {
                result += rest[open...]; return result
            }
            let label = afterOpen[..<close]
            let afterClose = afterOpen[afterOpen.index(after: close)...]
            if afterClose.first == "(", let paren = afterClose.firstIndex(of: ")") {
                result += label
                rest = afterClose[afterClose.index(after: paren)...]
            } else {
                result += "[" + label + "]"
                rest = afterClose
            }
        }
        result += rest
        return result
    }

    // MARK: - Filesystem helpers

    /// List immediate *.md files in a directory (non-recursive), sorted by name.
    private nonisolated static func markdownFiles(in dir: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return entries
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Size (bytes) and modification date for a file, with sane fallbacks.
    private nonisolated static func fileAttributes(_ url: URL) -> (size: Int, modified: Date) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let modified = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        return (size, modified)
    }
}

// MARK: - ItemCollector
//
// Accumulates ConfigItems while deduping by a stable id (resolved/canonical path).
// The first item seen for an id wins, but if a later item has a non-nil global flag
// preference we keep the first to preserve a deterministic snapshot. Tools that
// install the same skill via symlinks therefore collapse to a single entry.

private struct ItemCollector {
    private var byID: [String: ConfigItem] = [:]
    private var order: [String] = []

    mutating func add(_ item: ConfigItem) {
        if byID[item.id] == nil {
            byID[item.id] = item
            order.append(item.id)
        }
    }

    var items: [ConfigItem] { order.compactMap { byID[$0] } }
}

// MARK: - Small string convenience

private extension String {
    /// nil when the string is empty after trimming, else the original string.
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

// MARK: - Tech stack models
//
// The detected stack across the scanned repos. Foundation-only (icon is an SF Symbol
// name string) so the off-main scanner can build it without importing SwiftUI.

struct LanguageUsage: Identifiable, Sendable, Hashable {
    var id: String { name }
    var name: String
    var fileCount: Int
    var percent: Int
    var projectCount: Int = 0   // how many of the scanned projects contain this language
}

struct FrameworkUsage: Identifiable, Sendable, Hashable {
    var id: String { name }
    var name: String
    var icon: String      // SF Symbol name
    var repoCount: Int    // how many of the scanned repos use it
}

struct TechStack: Sendable {
    var languages: [LanguageUsage] = []
    var frameworks: [FrameworkUsage] = []
}
