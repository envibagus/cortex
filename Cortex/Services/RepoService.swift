import Foundation

// MARK: - RepoService
//
// Discovers local git repositories under the user's project roots and, when `gh`
// is authenticated, the user's GitHub repositories. Computes per-repo signals used
// by Repos, Repo Pulse, and the hygiene engine (commits today, dirty files,
// behind/ahead remote, skill/agent counts, CLAUDE.md size).
//
// All disk and process work runs off the main actor in detached tasks; results are
// published back on the main actor. Everything is robust to a missing `git`/`gh`.

@MainActor
@Observable
final class RepoService {
    private(set) var repos: [RepoInfo] = []
    private(set) var gitHubRepos: [GitHubRepo] = []
    private(set) var isLoading = false
    private(set) var lastScan: Date?
    /// The user's GitHub contributions bucketed by day, from their contribution
    /// calendar (commits + PRs + issues + reviews), so the Home activity heatmap
    /// matches GitHub exactly rather than over-counting every author across every local
    /// clone. Keys are start-of-day `Date`s (local calendar) so they line up with the
    /// heatmap cell dates. Powers the "N contributions" clause in the heatmap tooltip.
    /// Populated off the main actor during `loadGitHub` via the gh GraphQL API; left
    /// empty when `gh` is unavailable or the call fails (the heatmap then shows sessions
    /// only).
    private(set) var commitsByDay: [Date: Int] = [:]
    /// Commits you authored today across all repos GitHub indexes (any branch),
    /// resolved via `gh api search/commits`. Local clones are often behind remote
    /// and work happens on PR branches, so this is the real "commits today".
    private(set) var commitsTodayGitHub: Int = 0
    var userLogin = NSUserName()
    var userName = AppModel.defaultUserName()

    /// Project roots scanned for local git repositories. Set by AppModel from the
    /// scan roots the user configures in onboarding / Settings (persisted as paths).
    var roots: [String] = []

    /// Drop scanned repo data to free memory when the window closes (roots/identity are
    /// kept; `loadLocal()` + `loadGitHub()` rebuild the rest on next open).
    func clear() {
        repos = []
        gitHubRepos = []
        commitsByDay = [:]
        commitsTodayGitHub = 0
        lastScan = nil
    }

    // MARK: - Derived signals

    var reposWithSkills: Int { repos.filter(\.hasSkills).count }
    var reposWithAgents: Int { repos.filter(\.hasAgents).count }
    var commitsToday: Int { repos.reduce(0) { $0 + $1.commitsToday } }
    var richestConfig: RepoInfo? { repos.max { ($0.skillCount + $0.agentCount) < ($1.skillCount + $1.agentCount) } }

    /// GitHub CONTRIBUTIONS today (commits + PRs + issues + reviews), summed from the
    /// contribution calendar - the exact number GitHub shows on your profile graph and
    /// what the heatmap uses. The single source for the "Contributions today" figure on
    /// Home + the stats tile, so they never disagree. NOTE: contributions are NOT the
    /// same as raw commits; see `commitsTodayGitHub` for the commit-only count.
    var contributionsToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return commitsByDay.filter { $0.key >= start }.values.reduce(0, +)
    }

    // MARK: - Local repositories (git)
    //
    // Scans each root for immediate subdirectories that contain a `.git` directory,
    // then drives the `git` binary per repo (concurrently) to gather live signals.

    func loadLocal() async {
        isLoading = true
        let roots = roots
        let scanned = await Task.detached(priority: .userInitiated) {
            await Self.scanLocal(roots: roots)
        }.value
        self.repos = scanned.sorted { lhs, rhs in
            (lhs.lastCommit ?? .distantPast) > (rhs.lastCommit ?? .distantPast)
        }
        self.lastScan = Date()
        self.isLoading = false
    }

    /// Find every git repo under `roots`, then resolve each concurrently into per-repo
    /// signals. The heatmap's per-day buckets come from GitHub (see `loadGitHub`), not
    /// from local git, so this no longer walks each repo's commit log.
    nonisolated static func scanLocal(roots: [String]) async -> [RepoInfo] {
        var repoPaths: [String] = []
        var seen = Set<String>()

        // Walk each root up to two levels deep so nested repos (e.g.
        // myorg/web-app) and git worktrees (where .git is a FILE, not a
        // directory) are all discovered, not just immediate subdirectories.
        for root in roots {
            Self.collectRepos(in: root, depth: 0, maxDepth: 2, into: &repoPaths, seen: &seen)
        }

        guard !repoPaths.isEmpty else { return [] }

        // Resolve each repo concurrently. A missing `git` binary yields nil per repo.
        return await withTaskGroup(of: RepoInfo?.self) { group in
            for path in repoPaths {
                group.addTask { Self.inspect(path: path) }
            }
            var repos: [RepoInfo] = []
            for await info in group {
                if let info { repos.append(info) }
            }
            return repos
        }
    }

    // Fixed parser for the GitHub contribution-calendar `date` field: dates arrive as
    // `yyyy-MM-dd`. A POSIX-locale formatter keeps parsing deterministic regardless of
    // the user's region settings.
    private nonisolated static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Recursively collect git working trees under `dir`, up to `maxDepth` levels.
    /// A directory whose `.git` exists (as a directory OR a worktree file) is
    /// recorded and not descended into. Heavy build/vendor dirs are skipped.
    private nonisolated static func collectRepos(
        in dir: String, depth: Int, maxDepth: Int,
        into out: inout [String], seen: inout Set<String>
    ) {
        let fm = FileManager.default
        let gitPath = (dir as NSString).appendingPathComponent(".git")
        if fm.fileExists(atPath: gitPath) {
            if seen.insert(dir).inserted { out.append(dir) }
            return
        }
        guard depth < maxDepth, let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let skip: Set<String> = ["node_modules", "Pods", "build", "DerivedData", ".build", "vendor", "dist", ".next"]
        for entry in entries.sorted() where !entry.hasPrefix(".") && !skip.contains(entry) {
            let path = (dir as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            collectRepos(in: path, depth: depth + 1, maxDepth: maxDepth, into: &out, seen: &seen)
        }
    }

    /// Build a `RepoInfo` for a single repository directory by querying `git`
    /// plus reading the repo's `.claude` config and `CLAUDE.md`.
    nonisolated static func inspect(path: String) -> RepoInfo? {
        let name = (path as NSString).lastPathComponent

        // Small wrapper: run git against this repo, return stdout (trimmed) or nil.
        func git(_ args: [String]) -> String? {
            guard let res = Shell.run(tool: "git", ["-C", path] + args), res.ok else { return nil }
            return res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // If git is missing entirely, the first call resolves to nil; still emit a
        // best-effort record so the repo (and its config) is not dropped silently.
        let gitAvailable = Shell.which("git") != nil

        // Current branch (nil when empty or git is unavailable).
        let currentBranch: String? = {
            guard gitAvailable, let b = git(["rev-parse", "--abbrev-ref", "HEAD"]), !b.isEmpty else { return nil }
            return b
        }()

        // Commits authored since local midnight.
        let commitsToday: Int = {
            guard gitAvailable, let s = git(["rev-list", "--count", "--since=midnight", "HEAD"]) else { return 0 }
            return Int(s) ?? 0
        }()

        // Uncommitted files: count nonempty porcelain lines.
        let uncommittedFiles: Int = {
            guard gitAvailable, let res = Shell.run(tool: "git", ["-C", path, "status", "--porcelain"]), res.ok else { return 0 }
            return res.stdout.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        }()

        // Behind / ahead vs upstream. Errors mean there is no upstream, so 0/0.
        var behind = 0, ahead = 0
        if gitAvailable, let s = git(["rev-list", "--count", "--left-right", "@{u}...HEAD"]) {
            let parts = s.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            if parts.count == 2 {
                behind = Int(parts[0]) ?? 0
                ahead = Int(parts[1]) ?? 0
            }
        }

        // Last commit time (epoch seconds).
        let lastCommit: Date? = {
            guard gitAvailable, let s = git(["log", "-1", "--format=%ct"]), let epoch = TimeInterval(s) else { return nil }
            return Date(timeIntervalSince1970: epoch)
        }()

        // Remote origin URL and GitHub detection.
        let remoteURL: String? = gitAvailable ? git(["remote", "get-url", "origin"]).flatMap { $0.isEmpty ? nil : $0 } : nil
        let isGitHub = remoteURL?.contains("github.com") ?? false

        // Claude config: skills are subdirectories under .claude/skills; agents are
        // entries under .claude/agents.
        let skillCount = directoryCount(at: (path as NSString).appendingPathComponent(".claude/skills"), directoriesOnly: true)
        let agentCount = directoryCount(at: (path as NSString).appendingPathComponent(".claude/agents"), directoriesOnly: false)

        // CLAUDE.md presence and line count.
        let claudeMdPath = (path as NSString).appendingPathComponent("CLAUDE.md")
        let hasClaudeMd = FileManager.default.fileExists(atPath: claudeMdPath)
        let claudeMdLines: Int = {
            guard hasClaudeMd, let text = try? String(contentsOfFile: claudeMdPath, encoding: .utf8) else { return 0 }
            return text.split(separator: "\n", omittingEmptySubsequences: false).count
        }()

        return RepoInfo(
            name: name,
            path: path,
            currentBranch: currentBranch,
            commitsToday: commitsToday,
            uncommittedFiles: uncommittedFiles,
            behind: behind,
            ahead: ahead,
            lastCommit: lastCommit,
            remoteURL: remoteURL,
            isGitHub: isGitHub,
            skillCount: skillCount,
            agentCount: agentCount,
            hasClaudeMd: hasClaudeMd,
            claudeMdLines: claudeMdLines
        )
    }

    /// Count entries in a directory. When `directoriesOnly` is true, only
    /// subdirectories are counted; otherwise visible files and directories.
    nonisolated static func directoryCount(at path: String, directoriesOnly: Bool) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return 0 }
        var count = 0
        for entry in entries where !entry.hasPrefix(".") {
            if directoriesOnly {
                var isDir: ObjCBool = false
                let child = (path as NSString).appendingPathComponent(entry)
                if fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue { count += 1 }
            } else {
                count += 1
            }
        }
        return count
    }

    // MARK: - GitHub repositories (gh)
    //
    // Lists the authenticated user's repos via `gh repo list --json ...`, decodes
    // the JSON payload, and resolves the user's login/name. Robust to `gh` being
    // missing or unauthenticated: in that case `gitHubRepos` is simply left empty.

    func loadGitHub() async {
        let result = await Task.detached(priority: .userInitiated) {
            Self.fetchGitHub()
        }.value
        self.gitHubRepos = result.repos.sorted { lhs, rhs in
            (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
        if let login = result.login, !login.isEmpty { self.userLogin = login }
        if let name = result.name, !name.isEmpty { self.userName = name }

        // Commits today come from GitHub (not local git), since local clones lag
        // remote and work lands on PR branches.
        let login = self.userLogin
        let from = Self.localMidnightUTC()
        self.commitsTodayGitHub = await Task.detached(priority: .utility) {
            Self.fetchCommitsToday(login: login, since: from)
        }.value

        // The heatmap's per-day buckets are the user's GitHub contribution calendar
        // (commits + PRs + issues + reviews), so the grid matches GitHub exactly rather
        // than over-counting every author across every local clone.
        self.commitsByDay = await Task.detached(priority: .utility) {
            Self.fetchContributionDays()
        }.value
    }

    /// The authenticated user's GitHub contribution calendar bucketed by day, keyed by
    /// start-of-day `Date` (local calendar) so the keys line up with the heatmap cells.
    /// Fetched via the `gh` GraphQL API (`viewer.contributionsCollection`). Returns an
    /// empty dictionary if `gh` is missing, unauthenticated, or the call/parse fails (the
    /// heatmap then shows sessions only).
    nonisolated static func fetchContributionDays() -> [Date: Int] {
        let query = """
        query { viewer { contributionsCollection { contributionCalendar { weeks { contributionDays { date contributionCount } } } } } }
        """
        guard Shell.which("gh") != nil,
              let res = Shell.run(tool: "gh", [
                "api", "graphql", "-f", "query=\(query)",
              ]), res.ok,
              let data = res.stdout.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ContributionsResponse.self, from: data)
        else { return [:] }

        let cal = Calendar.current
        var out: [Date: Int] = [:]
        let days = decoded.data.viewer.contributionsCollection.contributionCalendar.weeks
            .flatMap(\.contributionDays)
        for day in days {
            guard let parsed = shortDateFormatter.date(from: day.date) else { continue }
            let key = cal.startOfDay(for: parsed)
            out[key, default: 0] += day.contributionCount
        }
        return out
    }

    /// ISO8601 string for the start of the user's local day, expressed in UTC, so
    /// the GitHub search window matches the contribution graph's local-day boundary.
    nonisolated static func localMidnightUTC() -> String {
        let midnight = Calendar.current.startOfDay(for: Date())
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: midnight)
    }

    /// Count commits authored by `login` since `since` (ISO8601) via the GitHub
    /// commit search API. Returns 0 if gh is missing or the query fails.
    nonisolated static func fetchCommitsToday(login: String, since: String) -> Int {
        guard !login.isEmpty,
              let res = Shell.run(tool: "gh", [
                "api", "-X", "GET", "search/commits",
                "-f", "q=author:\(login) committer-date:>=\(since)",
                "--jq", ".total_count",
              ]), res.ok else { return 0 }
        return Int(res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Off-actor fetch + decode of GitHub repos and identity.
    nonisolated static func fetchGitHub() -> (repos: [GitHubRepo], login: String?, name: String?) {
        // Repo list. Missing/unauthenticated gh yields nil or a nonzero exit.
        var repos: [GitHubRepo] = []
        let fields = "nameWithOwner,name,owner,description,isPrivate,isFork,stargazerCount,primaryLanguage,updatedAt,url"
        if let res = Shell.run(tool: "gh", ["repo", "list", "--limit", "200", "--json", fields]), res.ok,
           let data = res.stdout.data(using: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([GHRepoDTO].self, from: data) {
                repos = decoded.map(\.repoInfo)
            }
        }

        // Identity. Reuse `gh api user` to surface login + display name.
        var login: String?
        var name: String?
        if let res = Shell.run(tool: "gh", ["api", "user", "--jq", "{login: .login, name: .name}"]), res.ok,
           let data = res.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            login = json["login"] as? String
            name = json["name"] as? String
        }

        return (repos, login, name)
    }
}

// MARK: - GitHub JSON decoding
//
// Mirrors the shape returned by `gh repo list --json`. Nested objects (owner,
// primaryLanguage) are decoded then flattened into the app's `GitHubRepo`.

// Mirrors the `gh api graphql` response for the viewer's contribution calendar:
// data.viewer.contributionsCollection.contributionCalendar.weeks[].contributionDays[].
private struct ContributionsResponse: Decodable {
    struct DataField: Decodable { let viewer: Viewer }
    struct Viewer: Decodable { let contributionsCollection: Collection }
    struct Collection: Decodable { let contributionCalendar: Calendar }
    struct Calendar: Decodable { let weeks: [Week] }
    struct Week: Decodable { let contributionDays: [Day] }
    struct Day: Decodable {
        let date: String           // yyyy-MM-dd
        let contributionCount: Int
    }
    let data: DataField
}

private struct GHRepoDTO: Decodable {
    struct Owner: Decodable { let login: String }
    struct Language: Decodable { let name: String }

    let nameWithOwner: String
    let name: String
    let owner: Owner
    let description: String?
    let isPrivate: Bool
    let isFork: Bool
    let stargazerCount: Int
    let primaryLanguage: Language?
    let updatedAt: Date?
    let url: String

    var repoInfo: GitHubRepo {
        GitHubRepo(
            nameWithOwner: nameWithOwner,
            name: name,
            owner: owner.login,
            description: (description?.isEmpty == true) ? nil : description,
            isPrivate: isPrivate,
            isFork: isFork,
            stars: stargazerCount,
            language: primaryLanguage?.name,
            updatedAt: updatedAt,
            url: url
        )
    }
}
