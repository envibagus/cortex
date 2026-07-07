import Foundation

// MARK: - EnvironmentScanner
//
// Resolves the developer command-line tools installed on this machine for the
// Environment page. For each catalogued tool it probes the usual install locations (via
// Shell.which, which also consults the login-shell PATH) and, when present, runs the
// tool's version command and parses the number out of the output. Binaries found on PATH
// that aren't catalogued are surfaced separately under Uncatalogued.
//
// The scan is lazy: it runs the first time the page appears (hasLoaded guards re-runs)
// and on an explicit refresh, never at app bootstrap, since resolving ~60 tools spawns a
// process each and is not needed until the page is opened.

@MainActor
@Observable
final class EnvironmentScanner {
    /// Every catalogued tool with its scan outcome (present or absent), catalogue order.
    private(set) var tools: [DetectedTool] = []
    /// Executables found on PATH that aren't in the catalogue, sorted by name.
    private(set) var uncatalogued: [DetectedTool] = []
    private(set) var isLoading = false
    private(set) var lastScan: Date?
    private(set) var hasLoaded = false
    /// Binary/command name -> its most recent line index in the shell history (higher =
    /// more recently used). Drives the "Last used" sort. Empty when history is unreadable.
    private(set) var lastUsed: [String: Int] = [:]

    /// Number of catalogued tools actually installed (drives the sidebar badge + subtitle).
    var presentCount: Int { tools.filter(\.present).count }

    /// Run the scan off-main. No-op if already loaded unless `force` is set (refresh).
    func load(force: Bool = false) async {
        if isLoading { return }            // a scan is already running; don't start a second
        if hasLoaded && !force { return }
        isLoading = true
        let known = Set(ToolCatalog.all.flatMap { [$0.name] + $0.aliases })
        let result = await Task.detached(priority: .userInitiated) {
            (catalogued: Self.detectAll(ToolCatalog.all),
             discovered: Self.discoverUncatalogued(known: known),
             history: Self.scanHistory())
        }.value
        tools = result.catalogued
        uncatalogued = result.discovered
        lastUsed = result.history
        lastScan = Date()
        hasLoaded = true
        isLoading = false
    }

    /// Read the version of an uncatalogued binary on demand (when it's selected in the
    /// detail pane). Catalogued tools already carry versions from the scan, so this only
    /// touches Uncatalogued rows and skips ones already probed.
    func probeVersion(forID id: String) {
        guard let idx = uncatalogued.firstIndex(where: { $0.id == id }),
              uncatalogued[idx].rawVersion == nil,
              let path = uncatalogued[idx].path else { return }
        let url = URL(fileURLWithPath: path)
        Task { @MainActor in
            let probed = await Task.detached(priority: .utility) { Self.readVersion(url) }.value
            guard let i = uncatalogued.firstIndex(where: { $0.id == id }) else { return }
            uncatalogued[i].version = probed.version
            // Mark as probed even on no output, so it isn't re-run every time it's selected.
            uncatalogued[i].rawVersion = probed.raw ?? "(no version output)"
        }
    }

    // MARK: - Scanning (off-main)

    /// Resolve every catalogued tool in parallel. `concurrentPerform` sizes its own thread
    /// pool to the hardware, so this doesn't block the Swift cooperative pool while the
    /// per-tool version processes wait.
    nonisolated static func detectAll(_ catalog: [CatalogTool]) -> [DetectedTool] {
        var results = [DetectedTool?](repeating: nil, count: catalog.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: catalog.count) { i in
            let detected = detect(catalog[i])
            lock.lock(); results[i] = detected; lock.unlock()
        }
        return results.compactMap { $0 }
    }

    /// Resolve one catalogued tool: find its binary (trying aliases), infer the install
    /// source from the path, then run its version command.
    nonisolated static func detect(_ tool: CatalogTool) -> DetectedTool {
        var result = DetectedTool(
            name: tool.name, displayName: tool.resolvedDisplayName, category: tool.category,
            blurb: tool.blurb, upgrade: tool.upgrade, present: false
        )
        // Off-PATH install locations probed before the standard dirs (tilde-expanded).
        let extra = tool.extraPaths.map { ($0 as NSString).expandingTildeInPath }
        for candidate in [tool.name] + tool.aliases {
            guard let url = Shell.which(candidate, extra: extra) else { continue }
            result.present = true
            result.path = url.path
            result.source = ToolInstallSource.infer(fromPath: url.path)
            let v = readVersion(url, args: tool.versionArgs)
            result.version = v.version
            result.rawVersion = v.raw
            return result
        }
        return result
    }

    /// Run a resolved binary's version command and pull the version number out of the
    /// output. Some tools print their version to stderr, so both streams are considered.
    nonisolated static func readVersion(_ url: URL, args: [String] = ["--version"]) -> (version: String?, raw: String?) {
        // Short timeout: a well-behaved tool prints its version instantly, so a slow one is
        // almost certainly misbehaving and shouldn't stall the whole (parallel) scan.
        let res = Shell.run(url, args, timeout: 10)
        let combined = res.stdout.isEmpty ? res.stderr : res.stdout
        let raw = firstNonEmptyLine(res.stdout) ?? firstNonEmptyLine(res.stderr)
        return (parseVersion(from: combined), raw)
    }

    /// Enumerate executables on PATH that aren't catalogued, deduped by name (first hit in
    /// PATH order wins). Versions are read lazily when a row is selected, so this stays
    /// cheap regardless of how many binaries are installed.
    nonisolated static func discoverUncatalogued(known: Set<String>) -> [DetectedTool] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var dirs = ["\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin",
                    "/opt/homebrew/bin", "/usr/local/bin"]
        dirs += Shell.loginPathDirs
        var seen = Set<String>()
        var out: [DetectedTool] = []
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in entries {
                if known.contains(name) || seen.contains(name) { continue }
                let full = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue,
                      fm.isExecutableFile(atPath: full) else { continue }
                seen.insert(name)
                out.append(DetectedTool(
                    name: name, displayName: name, category: .uncatalogued, present: true,
                    path: full, source: ToolInstallSource.infer(fromPath: full)
                ))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Map each command name to its most recent position in the shell history, so tools can
    /// be ranked by how recently they were run. The history (`$HISTFILE` or ~/.zsh_history)
    /// is plain lines, optionally prefixed by zsh extended-history `": <epoch>:<elapsed>;"`;
    /// timestamps aren't required since ordering is by line position (later = more recent).
    /// Read-only, local: only the leading command token + its line index are kept, never the
    /// full command text.
    nonisolated static func scanHistory() -> [String: Int] {
        let fm = FileManager.default
        let path = ProcessInfo.processInfo.environment["HISTFILE"]
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".zsh_history").path
        guard let data = fm.contents(atPath: path) else { return [:] }
        // zsh escapes non-ASCII bytes, so a strict UTF-8 decode can fail; fall back to Latin-1.
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [:] }

        var rank: [String: Int] = [:]
        var index = 0
        text.enumerateLines { line, _ in
            index += 1
            var command = line
            // Strip the extended-history prefix ": <epoch>:<elapsed>;" when present.
            if command.hasPrefix(":"), let semicolon = command.firstIndex(of: ";") {
                command = String(command[command.index(after: semicolon)...])
            }
            command = command.trimmingCharacters(in: .whitespaces)
            guard var token = command.split(separator: " ", maxSplits: 1,
                                            omittingEmptySubsequences: true).first.map(String.init) else { return }
            // Reduce an absolute path to its binary name (/opt/homebrew/bin/node -> node).
            if token.contains("/") { token = String(token.split(separator: "/").last ?? "") }
            guard !token.isEmpty else { return }
            rank[token] = index   // later line wins => most recent invocation
        }
        return rank
    }

    /// First dotted version number in the text ("2.53.0", "8.0", "20"), or nil.
    nonisolated static func parseVersion(from text: String) -> String? {
        for pattern in [#"\d+\.\d+(\.\d+)+"#, #"\d+\.\d+"#, #"\d+"#] {
            if let r = text.range(of: pattern, options: .regularExpression) {
                return String(text[r])
            }
        }
        return nil
    }

    /// The first non-blank line of some command output, trimmed.
    nonisolated static func firstNonEmptyLine(_ text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

// MARK: - Tool catalogue
//
// The known developer tools the Environment scan looks for, grouped by category. Adding a
// tool here makes it a first-class row with a friendly name and description; anything
// installed but not listed still appears under Uncatalogued. Version arguments default to
// `--version` and are overridden only where a tool differs.

enum ToolCatalog {
    static let all: [CatalogTool] = runtimes + versionControl + hosting + databases
        + mobile + media + shell + aiCLIs + build + wordpress

    // MARK: Runtimes & language toolchains
    static let runtimes: [CatalogTool] = [
        CatalogTool(name: "node", displayName: "Node.js", category: .runtimes, versionArgs: ["--version"],
                    blurb: "JavaScript runtime.", upgrade: "brew upgrade node"),
        CatalogTool(name: "npm", category: .runtimes, blurb: "Node package manager."),
        CatalogTool(name: "pnpm", category: .runtimes, blurb: "Fast, disk-efficient Node package manager.", upgrade: "brew upgrade pnpm"),
        CatalogTool(name: "yarn", category: .runtimes, blurb: "Node package manager."),
        CatalogTool(name: "bun", category: .runtimes, blurb: "JavaScript runtime, bundler, and package manager.", upgrade: "bun upgrade"),
        CatalogTool(name: "deno", category: .runtimes, blurb: "Secure runtime for JavaScript and TypeScript.", upgrade: "brew upgrade deno"),
        CatalogTool(name: "corepack", category: .runtimes, blurb: "Manages Node package-manager versions."),
        CatalogTool(name: "python3", displayName: "Python", category: .runtimes, blurb: "Python interpreter.", aliases: ["python"]),
        CatalogTool(name: "uv", category: .runtimes, blurb: "Python package and project manager.", upgrade: "brew upgrade uv"),
        CatalogTool(name: "uvx", category: .runtimes, blurb: "Run Python tools in ephemeral environments."),
        CatalogTool(name: "pipx", category: .runtimes, blurb: "Install and run Python CLI apps in isolated environments."),
        CatalogTool(name: "virtualenv", category: .runtimes, blurb: "Create isolated Python environments."),
        CatalogTool(name: "ruby", category: .runtimes, blurb: "Ruby interpreter."),
        CatalogTool(name: "php", category: .runtimes, blurb: "PHP interpreter."),
        CatalogTool(name: "rustc", displayName: "Rust", category: .runtimes, blurb: "Rust compiler.", upgrade: "rustup update"),
        CatalogTool(name: "cargo", category: .runtimes, blurb: "Rust package manager and build tool."),
        CatalogTool(name: "rustup", category: .runtimes, blurb: "Rust toolchain installer."),
        CatalogTool(name: "rustfmt", category: .runtimes, blurb: "Rust code formatter."),
        CatalogTool(name: "rust-analyzer", category: .runtimes, blurb: "Rust language server."),
        CatalogTool(name: "swift", category: .runtimes, blurb: "Swift compiler and package manager."),
        CatalogTool(name: "clang", category: .runtimes, blurb: "C/C++/Objective-C compiler."),
        CatalogTool(name: "go", displayName: "Go", category: .runtimes, versionArgs: ["version"], blurb: "Go compiler and toolchain.",
                    extraPaths: ["/usr/local/go/bin/go", "~/go/bin/go"]),
    ]

    // MARK: Version control & GitHub
    static let versionControl: [CatalogTool] = [
        CatalogTool(name: "git", category: .versionControl, blurb: "Distributed version control system."),
        CatalogTool(name: "gh", displayName: "GitHub CLI", category: .versionControl, blurb: "GitHub from the command line.", upgrade: "brew upgrade gh"),
        CatalogTool(name: "gpg", displayName: "GnuPG", category: .versionControl, blurb: "Encryption and signing, used for signed commits."),
    ]

    // MARK: Hosting & deploy
    static let hosting: [CatalogTool] = [
        CatalogTool(name: "vercel", category: .hosting, blurb: "Deploy and manage Vercel projects.", upgrade: "npm i -g vercel@latest"),
        CatalogTool(name: "netlify", category: .hosting, blurb: "Deploy and manage Netlify sites."),
        CatalogTool(name: "supabase", category: .hosting, blurb: "Manage Supabase projects, migrations, and functions.", upgrade: "brew upgrade supabase"),
        CatalogTool(name: "wrangler", category: .hosting, blurb: "Build and deploy Cloudflare Workers."),
        CatalogTool(name: "cloudflared", category: .hosting, blurb: "Cloudflare Tunnel client."),
        CatalogTool(name: "neonctl", category: .hosting, blurb: "Manage Neon Postgres from the command line."),
        CatalogTool(name: "gcloud", displayName: "Google Cloud SDK", category: .hosting, blurb: "Google Cloud command-line interface.",
                    extraPaths: ["/opt/homebrew/share/google-cloud-sdk/bin/gcloud", "~/google-cloud-sdk/bin/gcloud"]),
        CatalogTool(name: "op", displayName: "1Password CLI", category: .hosting, blurb: "Access 1Password secrets from the command line."),
    ]

    // MARK: Databases
    static let databases: [CatalogTool] = [
        CatalogTool(name: "mysql", category: .databases, blurb: "MySQL client."),
        CatalogTool(name: "sqlite3", category: .databases, blurb: "SQLite command-line shell."),
        CatalogTool(name: "redis-cli", category: .databases, blurb: "Redis command-line client."),
        CatalogTool(name: "psql", displayName: "PostgreSQL", category: .databases, blurb: "PostgreSQL client.",
                    extraPaths: ["/Applications/Postgres.app/Contents/Versions/latest/bin/psql", "/opt/homebrew/opt/libpq/bin/psql"]),
    ]

    // MARK: Mobile / iOS / Android
    static let mobile: [CatalogTool] = [
        CatalogTool(name: "flutter", category: .mobile, blurb: "Cross-platform app SDK."),
        CatalogTool(name: "pod", displayName: "CocoaPods", category: .mobile, blurb: "Dependency manager for Cocoa projects."),
        CatalogTool(name: "xcodegen", category: .mobile, blurb: "Generate Xcode projects from a spec."),
        CatalogTool(name: "swiftlint", category: .mobile, blurb: "Swift style and conventions linter."),
        CatalogTool(name: "idb", category: .mobile, blurb: "iOS Simulator and device automation."),
        CatalogTool(name: "adb", displayName: "Android Debug Bridge", category: .mobile, blurb: "Android device and emulator control.",
                    extraPaths: ["~/Library/Android/sdk/platform-tools/adb"]),
        CatalogTool(name: "xcodebuild", category: .mobile, versionArgs: ["-version"], blurb: "Build Xcode projects from the command line."),
    ]

    // MARK: Media, docs, scraping
    static let media: [CatalogTool] = [
        CatalogTool(name: "ffmpeg", category: .media, versionArgs: ["-version"], blurb: "Audio and video processing."),
        CatalogTool(name: "yt-dlp", category: .media, blurb: "Media downloader."),
        CatalogTool(name: "gallery-dl", category: .media, blurb: "Image gallery downloader."),
        CatalogTool(name: "tesseract", category: .media, blurb: "Optical character recognition engine."),
        CatalogTool(name: "pandoc", category: .media, blurb: "Universal document converter."),
        CatalogTool(name: "tidy", displayName: "tidy-html5", category: .media, blurb: "HTML/XML corrector and pretty-printer."),
        CatalogTool(name: "pdfinfo", displayName: "poppler", category: .media, versionArgs: ["-v"], blurb: "PDF document inspection (poppler utilities)."),
    ]

    // MARK: Search / data / shell
    static let shell: [CatalogTool] = [
        CatalogTool(name: "jq", category: .shell, blurb: "Command-line JSON processor."),
        CatalogTool(name: "rg", displayName: "ripgrep", category: .shell, blurb: "Fast recursive search."),
        CatalogTool(name: "curl", category: .shell, blurb: "Transfer data over network protocols."),
        CatalogTool(name: "fswatch", category: .shell, blurb: "File-change monitor."),
        CatalogTool(name: "duti", category: .shell, versionArgs: ["-v"], blurb: "Set default apps for file types on macOS."),
        CatalogTool(name: "cliclick", category: .shell, versionArgs: ["-V"], blurb: "Emulate mouse and keyboard from the shell."),
        CatalogTool(name: "create-dmg", category: .shell, blurb: "Build a styled macOS disk image."),
        CatalogTool(name: "fd", category: .shell, blurb: "Fast file finder."),
    ]

    // MARK: AI / agent CLIs
    static let aiCLIs: [CatalogTool] = [
        CatalogTool(name: "claude", displayName: "Claude Code", category: .aiCLIs, blurb: "Anthropic's agentic coding CLI."),
        CatalogTool(name: "codex", category: .aiCLIs, blurb: "OpenAI's coding agent CLI."),
        CatalogTool(name: "gemini", displayName: "Gemini CLI", category: .aiCLIs, blurb: "Google's Gemini command-line interface."),
        CatalogTool(name: "agy", displayName: "Antigravity", category: .aiCLIs, blurb: "Google's agentic coding CLI."),
    ]

    // MARK: Build tooling
    static let build: [CatalogTool] = [
        CatalogTool(name: "cmake", category: .build, blurb: "Cross-platform build-system generator."),
        CatalogTool(name: "autoconf", category: .build, blurb: "Generate configure scripts."),
        CatalogTool(name: "m4", category: .build, blurb: "Macro processor."),
        CatalogTool(name: "libtool", category: .build, blurb: "Generic library-building support."),
        CatalogTool(name: "pkg-config", category: .build, blurb: "Report installed library metadata.", aliases: ["pkgconf"]),
        CatalogTool(name: "gettext", category: .build, blurb: "Internationalization toolset."),
        CatalogTool(name: "make", category: .build, blurb: "Build automation tool."),
    ]

    // MARK: WordPress
    static let wordpress: [CatalogTool] = [
        CatalogTool(name: "wp", displayName: "WP-CLI", category: .wordpress, blurb: "Manage WordPress installs from the command line."),
    ]
}
