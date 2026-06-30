import Foundation

// MARK: - HygieneScanner
//
// The actionable counterpart to HygieneEngine. Where HygieneEngine derives the
// score factors + the read-only "needs attention" issue list, this scanner finds
// concrete, fixable cruft across the user's workspace and pairs each finding with a
// one-tap action (kill a stray dev server, delete a stale branch, drop a stash,
// fast-forward a behind repo, move a dead directory to the Trash) plus a safe
// reveal/inspect for the rest.
//
// Everything reads live disk + git state off the main actor; results are published
// back on the main actor. The scan runs after the repo scan at bootstrap (and on
// refresh) so the Home score + the Health page share one source; an action removes
// just the resolved finding (see remove(id:)) instead of paying for a full re-scan.

@MainActor
@Observable
final class HygieneScanner {
    private(set) var sections: [HygieneSection] = []
    private(set) var isLoading = false
    private(set) var lastScan: Date?

    /// Total findings across every section (the big number in the summary ring).
    var totalCount: Int { sections.reduce(0) { $0 + $1.findings.count } }
    var criticalCount: Int { count(.critical) }
    var warningCount: Int { count(.warning) }
    var infoCount: Int { count(.info) }

    private func count(_ severity: HygieneIssue.Severity) -> Int {
        sections.reduce(0) { $0 + $1.findings.filter { $0.severity == severity }.count }
    }

    // MARK: Loading
    //
    // Takes the already-scanned repos + ports (so we don't re-discover them) plus the
    // raw scan roots (for the .env + dead-directory passes), runs the heavy git/disk
    // work off-main, and publishes one consistent snapshot.

    func load(repos: [RepoInfo], ports: [PortInfo], roots: [String]) async {
        isLoading = true
        let scanned = await Task.detached(priority: .userInitiated) {
            await Self.scan(repos: repos, ports: ports, roots: roots)
        }.value
        self.sections = scanned
        self.lastScan = Date()
        self.isLoading = false
    }

    /// Drop scanned findings to free memory when the window closes; reloaded on demand.
    func clear() {
        sections = []
        lastScan = nil
    }

    /// Optimistically drop a single resolved finding after its action succeeds, so the
    /// list + the Health score update instantly without re-running the whole git scan.
    /// Sections that empty out are removed so a cleared category disappears.
    func remove(id: String) {
        sections = sections.compactMap { section in
            let kept = section.findings.filter { $0.id != id }
            guard !kept.isEmpty else { return nil }
            var updated = section
            updated.findings = kept
            return updated
        }
    }

    // MARK: Top-level scan (off-main)
    //
    // Each pass is independent and skipped when its inputs are empty, so an unscanned
    // stack produces no noise. Sections appear in a fixed, most-actionable-first order.

    nonisolated static func scan(repos: [RepoInfo], ports: [PortInfo], roots: [String]) async -> [HygieneSection] {
        // The per-repo git work (stale branches + stashes) is the slow part; run it
        // concurrently across repos, mirroring RepoService's task-group pattern.
        let repoFindings = await withTaskGroup(of: (branches: [HygieneFinding], stashes: [HygieneFinding]).self) { group in
            for repo in repos {
                group.addTask {
                    (Self.staleBranches(repo: repo), Self.stashes(repo: repo))
                }
            }
            var branchAcc: [HygieneFinding] = []
            var stashAcc: [HygieneFinding] = []
            for await result in group {
                branchAcc.append(contentsOf: result.branches)
                stashAcc.append(contentsOf: result.stashes)
            }
            return (branches: branchAcc, stashes: stashAcc)
        }

        var out: [HygieneSection] = []

        let secrets = secretFindings(repos: repos)
        if !secrets.isEmpty {
            out.append(HygieneSection(
                kind: .secrets, title: "Secrets & .env Files",
                icon: "key.horizontal",
                info: "Local .env / credential files found in your repos. Ones committed to git or missing from .gitignore are the real risk.",
                findings: secrets))
        }

        let zombies = portFindings(ports: ports)
        if !zombies.isEmpty {
            out.append(HygieneSection(
                kind: .ports, title: "Listening Dev Servers",
                icon: "bolt.horizontal",
                info: "Dev servers still bound to a TCP port. Kill ones you forgot were running to free the port.",
                findings: zombies))
        }

        let branches = repoFindings.branches.sorted { $0.sortKey > $1.sortKey }
        if !branches.isEmpty {
            out.append(HygieneSection(
                kind: .staleBranches, title: "Stale Branches",
                icon: "arrow.triangle.branch",
                info: "Local branches with no commit in 30+ days (excluding the current + main/develop). Delete merged or abandoned ones.",
                findings: branches))
        }

        let stashes = repoFindings.stashes
        if !stashes.isEmpty {
            out.append(HygieneSection(
                kind: .stashes, title: "Stashes",
                icon: "tray.full",
                info: "git stash entries sitting across your repos. Drop the ones you no longer need.",
                findings: stashes))
        }

        let diverged = divergedFindings(repos: repos)
        if !diverged.isEmpty {
            out.append(HygieneSection(
                kind: .diverged, title: "Diverged from Remote",
                icon: "arrow.trianglehead.2.clockwise.rotate.90",
                info: "Repos behind their upstream (fast-forward pull) or ahead with unpushed commits (review + push yourself).",
                findings: diverged))
        }

        let dead = deadDirectoryFindings(repos: repos, roots: roots)
        if !dead.isEmpty {
            out.append(HygieneSection(
                kind: .deadDirs, title: "Dead Directories",
                icon: "folder.badge.minus",
                info: "Top-level folders under your scan roots with no git repo inside (at any depth) and nothing modified in 90+ days. Moves to the Trash (recoverable); reveal first if unsure.",
                findings: dead))
        }

        let uncommitted = uncommittedFindings(repos: repos)
        if !uncommitted.isEmpty {
            out.append(HygieneSection(
                kind: .uncommitted, title: "Uncommitted Changes",
                icon: "pencil.and.list.clipboard",
                info: "Working trees with uncommitted files. Commit or stash to keep them reviewable.",
                findings: uncommitted))
        }

        return out
    }

    // MARK: - Git helpers

    /// Run git against a repo; return trimmed stdout, or nil on failure / missing git.
    private nonisolated static func gitOut(_ repo: String, _ args: [String]) -> String? {
        guard let res = Shell.git(repo, args), res.ok else { return nil }
        return res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run git against a repo; return whether it exited 0 (used for boolean probes).
    private nonisolated static func gitOK(_ repo: String, _ args: [String]) -> Bool {
        Shell.git(repo, args)?.ok ?? false
    }

    // MARK: - Secrets / .env
    //
    // For each repo, scan the root + immediate child directories (bounded, no deep
    // walk) for .env and credential files, then classify each by its real git
    // exposure: committed (critical), unignored (warning), or properly gitignored
    // (info). Example/sample templates are skipped - they're meant to be committed.

    private nonisolated static func secretFindings(repos: [RepoInfo]) -> [HygieneFinding] {
        var out: [HygieneFinding] = []
        let fm = FileManager.default
        let skipChildren: Set<String> = ["node_modules", "Pods", "build", "DerivedData", ".build", "vendor", "dist", ".next", ".git"]

        for repo in repos {
            // Candidate directories: the repo root + its immediate subdirectories. Hidden
            // config dirs (.config, .aws, ...) are included so secrets there are caught;
            // only heavy build/vendor dirs and .git are skipped.
            var dirs = [repo.path]
            if let entries = try? fm.contentsOfDirectory(atPath: repo.path) {
                for entry in entries where !skipChildren.contains(entry) {
                    let child = (repo.path as NSString).appendingPathComponent(entry)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue { dirs.append(child) }
                }
            }

            for dir in dirs {
                guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                let secretFiles = files.filter(isSecretFile)
                guard !secretFiles.isEmpty else { continue }

                // Classify against the repo that actually GOVERNS this directory: a nested
                // repo or submodule has its own index + .gitignore, so checking the outer
                // repo would mislabel the file. `rev-parse --show-toplevel` resolves it.
                let govRepo = gitOut(dir, ["rev-parse", "--show-toplevel"]).flatMap { $0.isEmpty ? nil : $0 } ?? repo.path

                for file in secretFiles {
                    let path = (dir as NSString).appendingPathComponent(file)
                    let rel = relativePath(path, inRepo: govRepo)
                    let tracked = gitOK(govRepo, ["ls-files", "--error-unmatch", rel])
                    let ignored = gitOK(govRepo, ["check-ignore", "-q", rel])

                    let severity: HygieneIssue.Severity
                    let status: String
                    if tracked {
                        severity = .critical; status = "Committed to git"
                    } else if !ignored {
                        severity = .warning; status = "Not in .gitignore"
                    } else {
                        severity = .info; status = "Gitignored"
                    }

                    out.append(HygieneFinding(
                        id: "secret-\(path)",
                        title: rel,
                        detail: "\(status) \u{00B7} \(repo.name)",
                        command: nil,
                        severity: severity,
                        badge: repo.name,
                        action: .reveal(path: path),
                        sortKey: Double(severity.rawValue)))
                }
            }
        }
        return out.sorted { $0.sortKey > $1.sortKey }
    }

    /// Whether a filename looks like a secret / env file (excluding safe templates).
    private nonisolated static func isSecretFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        // Example / template envs are meant to be committed - never flag them.
        if lower.hasSuffix(".example") || lower.hasSuffix(".sample") || lower.hasSuffix(".template") || lower.hasSuffix(".dist") {
            return false
        }
        if lower == ".env" || lower.hasPrefix(".env.") || lower.hasPrefix(".env-") { return true }
        if lower.hasSuffix(".pem") || lower.hasSuffix(".key") || lower.hasSuffix(".p12") || lower.hasSuffix(".keystore") { return true }
        if lower == "credentials.json" || lower == ".npmrc" || lower == ".netrc" { return true }
        if lower.hasPrefix("secrets.") || lower.hasPrefix("secret.") { return true }
        return false
    }

    /// A repo-relative path for `git ls-files` / `check-ignore` (they want repo-relative).
    private nonisolated static func relativePath(_ path: String, inRepo repo: String) -> String {
        let prefix = repo.hasSuffix("/") ? repo : repo + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : (path as NSString).lastPathComponent
    }

    // MARK: - Listening dev servers (zombies)
    //
    // The dev-server-shaped listeners from the live port scan: a known dev runtime
    // (node/python/ruby/...) or any port in the common dev range, owned by the current
    // user, excluding real infrastructure (postgres/redis/mysql/docker/system agents).

    private nonisolated static func portFindings(ports: [PortInfo]) -> [HygieneFinding] {
        let me = NSUserName()
        let devCommands = ["node", "python", "ruby", "deno", "bun", "php", "next", "vite", "rails", "puma", "gunicorn", "uvicorn", "flask", "webpack", "nuxt", "ng"]
        let infra = ["postgres", "redis", "mysql", "mongod", "docker", "com.docke", "rapportd", "controlce", "sharingd", "rapport"]

        return ports.compactMap { port -> HygieneFinding? in
            guard port.user == me else { return nil }
            let cmd = port.command.lowercased()
            if infra.contains(where: { cmd.contains($0) }) { return nil }
            let isDev = devCommands.contains { cmd.hasPrefix($0) } || (3000...9999).contains(port.port)
            guard isDev else { return nil }

            let projectClause = port.project.map { " \u{00B7} \($0)" } ?? ""
            return HygieneFinding(
                id: "port-\(port.id)",
                title: "\(port.processName) on :\(port.port)",
                detail: "Listening (LISTEN) \u{00B7} pid \(port.pid)\(projectClause)",
                command: "kill \(port.pid)",
                severity: .info,
                badge: port.project,
                action: .kill(pid: port.pid, name: port.processName),
                sortKey: Double(port.port))
        }
        .sorted { $0.sortKey < $1.sortKey }
    }

    // MARK: - Stale branches
    //
    // Local branches with no commit in 30+ days, excluding the current branch and the
    // common protected names. Each carries the delete command; the action method
    // captures the tip SHA at delete time so the toast can offer Undo.

    private nonisolated static let protectedBranches: Set<String> = [
        "main", "master", "develop", "dev", "trunk", "release", "staging", "production", "prod", "HEAD",
    ]

    private nonisolated static func staleBranches(repo: RepoInfo) -> [HygieneFinding] {
        // refname<TAB>committerdate-unix<TAB>HEAD-marker ("*" for the current branch).
        guard let out = gitOut(repo.path, [
            "for-each-ref", "--format=%(refname:short)\t%(committerdate:unix)\t%(HEAD)", "refs/heads/",
        ]), !out.isEmpty else { return [] }

        let now = Date().timeIntervalSince1970
        let staleCutoff: TimeInterval = 30 * 86_400

        var findings: [HygieneFinding] = []
        for line in out.split(separator: "\n") {
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 2 else { continue }
            let name = cols[0]
            guard let when = TimeInterval(cols[1]) else { continue }
            let isCurrent = cols.count >= 3 && cols[2].trimmingCharacters(in: .whitespaces) == "*"
            if isCurrent || protectedBranches.contains(name) { continue }

            let ageSecs = now - when
            guard ageSecs > staleCutoff else { continue }
            let days = Int(ageSecs / 86_400)

            findings.append(HygieneFinding(
                id: "branch-\(repo.path)-\(name)",
                title: "\(name) (\(days)d old)",
                detail: repo.name,
                command: "git -C '\(repo.path)' branch -D '\(name)'",
                severity: days >= 90 ? .warning : .info,
                badge: repo.name,
                action: .deleteBranch(repoPath: repo.path, branch: name, repoName: repo.name),
                sortKey: ageSecs))
        }
        return findings
    }

    // MARK: - Stashes

    private nonisolated static func stashes(repo: RepoInfo) -> [HygieneFinding] {
        // refselector<TAB>commit-sha<TAB>subject, e.g. "stash@{0}\t<sha>\tOn main: wip ...".
        // The SHA is the stable handle: stash@{N} selectors renumber after any drop, so
        // the action resolves the live selector by SHA before dropping.
        guard let out = gitOut(repo.path, ["stash", "list", "--format=%gd\t%H\t%gs"]), !out.isEmpty else { return [] }

        var findings: [HygieneFinding] = []
        for line in out.split(separator: "\n") {
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 2, !cols[0].isEmpty else { continue }
            let ref = cols[0]
            let sha = cols[1]
            let message = cols.count >= 3 ? cols[2] : ref
            findings.append(HygieneFinding(
                id: "stash-\(repo.path)-\(sha)",
                title: message,
                detail: "\(ref) \u{00B7} \(repo.name)",
                command: "git -C '\(repo.path)' stash drop '\(ref)'",
                severity: .info,
                badge: repo.name,
                action: .dropStash(repoPath: repo.path, ref: ref, sha: sha, repoName: repo.name),
                sortKey: 0))
        }
        return findings
    }

    // MARK: - Diverged from remote
    //
    // Behind repos get a fast-forward Pull (always safe); ahead repos are surfaced for
    // review only - the app never pushes on your behalf.

    private nonisolated static func divergedFindings(repos: [RepoInfo]) -> [HygieneFinding] {
        var out: [HygieneFinding] = []
        for repo in repos {
            if repo.behind > 0 {
                out.append(HygieneFinding(
                    id: "behind-\(repo.path)",
                    title: "\(repo.name) (\u{2193}\(repo.behind))",
                    detail: "\(repo.behind) commit\(repo.behind == 1 ? "" : "s") behind remote",
                    command: "git -C '\(repo.path)' pull --ff-only",
                    severity: .info,
                    badge: repo.currentBranch,
                    action: .pull(repoPath: repo.path, repoName: repo.name),
                    sortKey: Double(repo.behind)))
            }
            if repo.ahead > 0 {
                out.append(HygieneFinding(
                    id: "ahead-\(repo.path)",
                    title: "\(repo.name) (\u{2191}\(repo.ahead))",
                    detail: "\(repo.ahead) unpushed commit\(repo.ahead == 1 ? "" : "s") \u{00B7} review + push yourself",
                    command: nil,
                    severity: .info,
                    badge: repo.currentBranch,
                    action: .reveal(path: repo.path),
                    sortKey: Double(repo.ahead)))
            }
        }
        return out.sorted { $0.sortKey > $1.sortKey }
    }

    // MARK: - Dead directories
    //
    // Top-level folders directly under a scan root that contain no git repo at ANY depth
    // and nothing modified in 90+ days. The repo + recency checks are a DEEP bounded walk
    // (not the shallow top-level mtime, which on macOS only changes when direct children
    // are added/removed) so an actively-edited folder, or one hiding a repo nested below
    // RepoService's scan depth, is never offered for the Trash. The action moves to the
    // Trash (recoverable), never rm -rf, and still confirms first.

    private nonisolated static func deadDirectoryFindings(repos: [RepoInfo], roots: [String]) -> [HygieneFinding] {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        let staleCutoff: TimeInterval = 90 * 86_400
        let repoPaths = repos.map(\.path)

        var out: [HygieneFinding] = []
        var seen = Set<String>()

        for root in roots {
            let expanded = (root as NSString).expandingTildeInPath
            guard let entries = try? fm.contentsOfDirectory(atPath: expanded) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                let path = (expanded as NSString).appendingPathComponent(entry)
                guard !seen.contains(path) else { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }

                // Cheap pre-filters: skip a repo at the top level or any known (depth <= 2)
                // repo nested under it.
                if fm.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) { continue }
                let prefix = path + "/"
                if repoPaths.contains(where: { $0 == path || $0.hasPrefix(prefix) }) { continue }

                // Deep verification: only flag when the whole tree is repo-free AND nothing
                // inside was modified within the window. Conservative on uncertainty.
                guard isDeadDirectory(path, cutoff: staleCutoff, now: now) else { continue }

                seen.insert(path)
                let attrs = try? fm.attributesOfItem(atPath: path)
                let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? now
                let days = Int(max(0, now - modified) / 86_400)
                out.append(HygieneFinding(
                    id: "dead-\(path)",
                    title: entry,
                    detail: "\(path.tildeAbbreviated) \u{00B7} no activity \(days)d",
                    command: nil,
                    severity: .info,
                    badge: nil,
                    action: .trash(path: path),
                    sortKey: Double(now - modified)))
            }
        }
        return out.sorted { $0.sortKey > $1.sortKey }
    }

    /// A bounded depth-first walk that returns false (ALIVE) the moment it finds a nested
    /// `.git` OR any entry modified within `cutoff`; true (dead) only if the whole tree is
    /// repo-free and untouched. If the entry budget is exhausted before proving that, it
    /// returns false - we never offer to Trash a folder we couldn't fully verify.
    private nonisolated static func isDeadDirectory(_ root: String, cutoff: TimeInterval, now: TimeInterval) -> Bool {
        let fm = FileManager.default
        var budget = 4_000
        var stack = [root]
        while let dir = stack.popLast() {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries {
                budget -= 1
                if budget <= 0 { return false }              // couldn't fully verify -> alive
                if entry == ".git" { return false }          // a repo lives somewhere inside
                let path = (dir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                if let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                   now - modified.timeIntervalSince1970 <= cutoff {
                    return false                             // something recent -> alive
                }
                if isDir.boolValue { stack.append(path) }
            }
        }
        return true
    }

    // MARK: - Uncommitted working trees

    private nonisolated static func uncommittedFindings(repos: [RepoInfo]) -> [HygieneFinding] {
        repos
            .filter { $0.uncommittedFiles > 0 }
            .sorted { $0.uncommittedFiles > $1.uncommittedFiles }
            .map { repo in
                HygieneFinding(
                    id: "dirty-\(repo.path)",
                    title: repo.name,
                    detail: "\(repo.uncommittedFiles) uncommitted file\(repo.uncommittedFiles == 1 ? "" : "s")",
                    command: nil,
                    severity: repo.uncommittedFiles >= 8 ? .warning : .info,
                    badge: repo.currentBranch,
                    action: .reveal(path: repo.path),
                    sortKey: Double(repo.uncommittedFiles))
            }
    }
}

// MARK: - Hygiene models
//
// Findings are pure data (Sendable, no SwiftUI types) so the off-main scanner can
// build them; the view derives labels/colors from the severity + action at render.

/// One concrete, fixable finding plus its one-tap action.
struct HygieneFinding: Identifiable, Sendable {
    var id: String
    var title: String
    var detail: String?        // secondary line (status / project / age)
    var command: String?       // mono command preview, when the action runs one
    var severity: HygieneIssue.Severity
    var badge: String?         // trailing tag (project / branch name)
    var action: HygieneAction
    var sortKey: Double         // section-local ordering (age, port, count, severity)
}

/// One grouped section of findings shown as a collapsible card.
struct HygieneSection: Identifiable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case secrets, ports, staleBranches, stashes, diverged, deadDirs, uncommitted
    }
    var kind: Kind
    var id: String { kind.rawValue }
    var title: String
    var icon: String           // SF Symbol
    var info: String           // (i) tooltip text
    var findings: [HygieneFinding]
}

/// The action a finding's button performs. Associated values carry everything the
/// AppModel action methods need; the view derives the label / glyph / confirm copy.
enum HygieneAction: Sendable, Hashable {
    case reveal(path: String)
    case kill(pid: Int, name: String)
    case deleteBranch(repoPath: String, branch: String, repoName: String)
    // `ref` is the display selector (stash@{N}); `sha` is the stable handle the action
    // re-resolves the live selector from, so a renumbered list can't drop the wrong one.
    case dropStash(repoPath: String, ref: String, sha: String, repoName: String)
    case pull(repoPath: String, repoName: String)
    case trash(path: String)

    /// Button label.
    var label: String {
        switch self {
        case .reveal: "Reveal"
        case .kill: "Kill"
        case .deleteBranch: "Delete"
        case .dropStash: "Drop"
        case .pull: "Pull"
        case .trash: "Trash"
        }
    }

    /// Button glyph.
    var systemImage: String {
        switch self {
        case .reveal: "magnifyingglass"
        case .kill: "xmark.octagon"
        case .deleteBranch: "trash"
        case .dropStash: "trash"
        case .pull: "arrow.down.circle"
        case .trash: "trash"
        }
    }

    /// Destructive actions read orange + show a confirm; safe ones (reveal/pull) don't.
    var isDestructive: Bool {
        switch self {
        case .reveal, .pull: false
        case .kill, .deleteBranch, .dropStash, .trash: true
        }
    }

    /// Reveal is read-only (no confirm); every action that changes state confirms first
    /// (Pull included - it mutates the working tree, even if fast-forward-only).
    var needsConfirm: Bool {
        if case .reveal = self { return false }
        return true
    }

    /// Confirmation dialog title.
    var confirmTitle: String {
        switch self {
        case .kill(_, let name): "Kill \(name)?"
        case .deleteBranch(_, let branch, _): "Delete branch \u{201C}\(branch)\u{201D}?"
        case .dropStash(_, let ref, _, _): "Drop \(ref)?"
        case .pull(_, let repoName): "Fast-forward pull \(repoName)?"
        case .trash(let path): "Move \u{201C}\((path as NSString).lastPathComponent)\u{201D} to the Trash?"
        case .reveal: ""
        }
    }

    /// Confirmation dialog message.
    var confirmMessage: String {
        switch self {
        case .kill(let pid, _): "Sends a terminate signal to pid \(pid). Unsaved work in that process is lost."
        case .deleteBranch: "The branch is deleted locally. You can Undo from the toast right after."
        case .dropStash: "The stash entry is removed. This can't be undone from here."
        case .pull: "Runs git pull --ff-only. Fast-forward only, so it can't create a merge or lose local commits."
        case .trash: "The folder is moved to the Trash (recoverable from there). Heuristic match - reveal it first if unsure."
        case .reveal: ""
        }
    }
}
