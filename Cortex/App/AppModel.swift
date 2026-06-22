import SwiftUI
import Observation
import AppKit

// MARK: - AppModel
//
// The single source of truth shared through the environment. Owns every data
// store, the current route, the command-palette state, and the user's settings,
// and orchestrates the initial + on-demand data loads.

@MainActor
@Observable
final class AppModel {
    // Navigation
    var route: Route = .readout
    var showCommandPalette = false

    // Assistant deep-link: a route an assistant CTA asked to open, plus an optional
    // search / scope for the destination to pre-apply when it appears. The target view
    // reads these once via consumePending(for:) and they clear.
    private(set) var pendingSearch: String?
    private(set) var pendingScope: String?
    private var pendingRoute: Route?

    /// Navigate from an assistant navigation CTA: switch route and stash any search /
    /// scope hint for the destination view to apply on appear.
    func runChatAction(_ action: ChatAction) {
        pendingRoute = action.route
        pendingSearch = action.search
        pendingScope = action.scope
        route = action.route
    }

    /// A destination view calls this on appear: returns (and clears) any pending search
    /// / scope queued for it by an assistant CTA. Returns nils when nothing is queued
    /// for this route, so views can apply it unconditionally.
    func consumePending(for route: Route) -> (search: String?, scope: String?) {
        guard pendingRoute == route else { return (nil, nil) }
        defer { pendingRoute = nil; pendingSearch = nil; pendingScope = nil }
        return (pendingSearch, pendingScope)
    }

    // New-item creation flow.
    // - newItemKind drives the creation modal (nil = hidden); set by NewItemMenu.
    // - recentlyCreatedID is the just-created item: ConfigBrowser floats it to the
    //   top of its list and ConfigItemDetail auto-opens it in the editor once.
    // - editingItemID is whichever library item is currently open in the markdown
    //   editor; ConfigItemRow draws a yellow border on that row.
    var newItemKind: ConfigKind?
    var recentlyCreatedID: String?
    var editingItemID: String?

    // Transient toast shown bottom-trailing (e.g. "Path copied"); auto-clears.
    var toast: String?
    // An optional action button on the current toast (e.g. "Undo" after a delete).
    var toastAction: ToastAction?
    private var toastClearTask: Task<Void, Never>?

    /// A tappable action attached to a toast (e.g. Undo). The handler runs on the main
    /// actor when tapped, then the toast dismisses.
    struct ToastAction: Identifiable {
        let id = UUID()
        var label: String
        var handler: () -> Void
    }

    /// Flash a short message in the bottom-right toast, replacing any current one. An
    /// optional action adds a trailing button (and uses a longer default duration so
    /// there's time to tap it, e.g. Undo).
    func showToast(_ message: String, action: ToastAction? = nil, duration: TimeInterval? = nil) {
        toast = message
        toastAction = action
        toastClearTask?.cancel()
        let seconds = duration ?? (action == nil ? 1.8 : 6)
        toastClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.toast = nil
            self?.toastAction = nil
        }
    }

    /// Run a toast action and dismiss the toast (used by the toast's button).
    func runToastAction() {
        let handler = toastAction?.handler
        toast = nil
        toastAction = nil
        toastClearTask?.cancel()
        handler?()
    }

    // Identity. Defaults to the macOS account name, then gets refined from `gh` at
    // bootstrap, unless the user has set an explicit override in Settings.
    var userName = AppModel.defaultUserName()
    var userLogin = NSUserName()

    // Settings (persisted via UserDefaults wrappers below)
    var monthlyBudget: Double? {
        get { let v = UserDefaults.standard.double(forKey: "monthlyBudget"); return v > 0 ? v : nil }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "monthlyBudget") }
    }

    // App-wide sort order for every library list pane (Skills / Agents / Rules /
    // Commands / Instructions / Plugins / Memory / MCP). Persisted as the enum's String
    // rawValue so the choice survives relaunch; an unknown/missing value falls back to
    // .name (the default A-Z order).
    // NOTE: these are backed by STORED, @Observable-tracked rawValue properties (not a
    // bare UserDefaults computed) so that changing the sort actually triggers a SwiftUI
    // re-render. A pure UserDefaults computed property is invisible to observation, so
    // the lists never re-sorted when the choice changed (the bug). didSet persists.
    private var librarySortRaw: String = UserDefaults.standard.string(forKey: "librarySort") ?? LibrarySort.name.rawValue {
        didSet { UserDefaults.standard.set(librarySortRaw, forKey: "librarySort") }
    }
    var librarySort: LibrarySort {
        get { LibrarySort(rawValue: librarySortRaw) ?? .name }
        set { librarySortRaw = newValue.rawValue }
    }

    // Sort order for the Sessions list pane. Same observed-stored-rawValue pattern.
    private var sessionSortRaw: String = UserDefaults.standard.string(forKey: "sessionSort") ?? SessionSort.recent.rawValue {
        didSet { UserDefaults.standard.set(sessionSortRaw, forKey: "sessionSort") }
    }
    var sessionSort: SessionSort {
        get { SessionSort(rawValue: sessionSortRaw) ?? .recent }
        set { sessionSortRaw = newValue.rawValue }
    }

    // User-set display name. When non-empty it always wins over the gh-resolved
    // name; cleared (empty) falls back to the macOS account name + gh resolution.
    var userNameOverride: String {
        get { UserDefaults.standard.string(forKey: "userNameOverride") ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: "userNameOverride")
            userName = trimmed.isEmpty ? AppModel.defaultUserName() : trimmed
            refreshAssistantContext()
        }
    }

    // Directories Cortex scans for local git repositories and project-level AI
    // config (skills, agents, rules). Configured on first launch and in Settings.
    // Stored (so SwiftUI observes changes) and mirrored to UserDefaults + the repo
    // scanner on every write. Seeded from UserDefaults; empty until the user picks
    // roots in onboarding. Mutate through addScanRoots / removeScanRoot.
    var scanRoots: [String] = (UserDefaults.standard.array(forKey: "scanRoots") as? [String]) ?? [] {
        didSet {
            UserDefaults.standard.set(scanRoots, forKey: "scanRoots")
            repos.roots = scanRoots
        }
    }

    // Whether first-run onboarding (the welcome + scan-root picker) has completed.
    // Stored so the ContentView overlay reacts when it flips; persisted on write.
    var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    // Sidebar pins: route raw values the user has marked important. They surface in a
    // "Pinned" section at the top of the sidebar (and are editable in Settings). Stored
    // so SwiftUI observes changes; persisted to UserDefaults on every write.
    var pinnedRoutes: [String] = (UserDefaults.standard.array(forKey: "pinnedRoutes") as? [String]) ?? [] {
        didSet { UserDefaults.standard.set(pinnedRoutes, forKey: "pinnedRoutes") }
    }

    /// Whether a route is currently pinned to the top of the sidebar.
    func isPinned(_ route: Route) -> Bool { pinnedRoutes.contains(route.rawValue) }

    /// Pin or unpin a route (toggles its presence in the "Pinned" section).
    func togglePin(_ route: Route) {
        if let idx = pinnedRoutes.firstIndex(of: route.rawValue) {
            pinnedRoutes.remove(at: idx)
        } else {
            pinnedRoutes.append(route.rawValue)
        }
    }

    /// Pinned routes, in pin order, resolved back to `Route` values.
    var pinnedRouteList: [Route] { pinnedRoutes.compactMap(Route.init(rawValue:)) }

    // Sidebar visibility: route raw values the user has HIDDEN from the sidebar. The
    // per-destination Show toggle in Settings writes here (default empty == everything
    // shown). Stored so SwiftUI observes changes; persisted to UserDefaults on write.
    // A few routes can never be hidden (see `canHide`) so the app stays navigable.
    var hiddenRoutes: [String] = (UserDefaults.standard.array(forKey: "hiddenRoutes") as? [String]) ?? [] {
        didSet { UserDefaults.standard.set(hiddenRoutes, forKey: "hiddenRoutes") }
    }

    /// Routes that must always remain reachable, so the user can never hide them out of
    /// existence: Settings (the only place to un-hide things) and Home (the default
    /// landing route). Their Show toggle is forced on + disabled in Settings.
    func canHide(_ route: Route) -> Bool {
        switch route {
        case .settings, .readout: return false
        default: return true
        }
    }

    /// Whether a route is currently hidden from the sidebar. Always-shown routes
    /// (see `canHide`) report false regardless of what is stored.
    func isHidden(_ route: Route) -> Bool {
        canHide(route) && hiddenRoutes.contains(route.rawValue)
    }

    /// Convenience inverse of `isHidden` (the Settings Show toggle binds to this).
    func isShown(_ route: Route) -> Bool { !isHidden(route) }

    /// Hide or show a route in the sidebar (no-op for always-shown routes).
    func toggleHidden(_ route: Route) {
        guard canHide(route) else { return }
        if let idx = hiddenRoutes.firstIndex(of: route.rawValue) {
            hiddenRoutes.remove(at: idx)
        } else {
            hiddenRoutes.append(route.rawValue)
        }
    }

    /// The macOS account's full name, falling back to the short login name.
    static func defaultUserName() -> String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? NSUserName() : full
    }

    // Stores
    let cost = CostService()
    let sessions: SessionStore
    let ports = PortService()
    let repos = RepoService()
    let config = ConfigScanner()
    let chat = ChatService()
    let hygiene = HygieneEngine()
    let library = LibraryStore()
    let usage = UsageService()
    // On-device AI one-line summaries for long agent descriptions (Foundation Models).
    let summaries = SummaryService()

    // Derived
    private(set) var stats = UsageStats()
    private(set) var didBootstrap = false
    // First-load hydration flag. Stays false until the FIRST data (sessions/ports/
    // config) has loaded and stats are computed, then flips true and stays true (later
    // refreshes never reset it). The Home page shows its skeleton shimmer while false.
    private(set) var isReady = false

    // When the network-heavy GitHub scan (commits today + contribution calendar) last
    // ran. Used to refresh it on its own longer throttle during navigation, so commits
    // pushed after launch appear without a manual Refresh (it was previously only
    // fetched at bootstrap / Refresh, which is why "commits today" could stick at 0).
    private var lastGitHubRefresh: Date = .distantPast

    // Running `claude` CLI processes keyed by their working-directory path, polled on a
    // short timer. Lets Live mark a project "active" because a Claude window is OPEN in
    // it (process running), not only when its transcript was written in the last 2 min -
    // so two open windows in a project both count even while idle.
    private(set) var runningClaudeByProject: [String: Int] = [:]

    /// Count of running `claude` windows across the user's known project folders (the
    /// Live sidebar badge). Matches detected process cwds against session project paths,
    /// so background/home claude processes (incl. the assistant's own `claude -p`) are
    /// excluded.
    var activeClaudeCount: Int {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let projectPaths = Set(sessions.sessions.map(\.projectPath))
        return runningClaudeByProject.reduce(0) { acc, kv in
            // Skip the home dir: the app's own `claude -p` assistant subprocess runs
            // there, and it isn't a project window the user opened.
            guard kv.key != home, projectPaths.contains(kv.key) else { return acc }
            return acc + kv.value
        }
    }

    /// Re-scan running `claude` processes off-main and publish the result.
    func refreshRunningClaude() {
        Task.detached(priority: .utility) {
            let map = ClaudeProcessScanner.runningByProject()
            await MainActor.run { self.runningClaudeByProject = map }
        }
    }

    init() {
        self.sessions = SessionStore(cost: cost)
        // didSet does not fire for the stored default, so do the initial sync here.
        repos.roots = scanRoots
    }

    /// First-run load: pricing, sessions, ports, config, repos, then hygiene.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        // Warm the login-shell PATH probe off-main so the first which() miss (e.g. the
        // assistant engine check) never blocks the UI resolving it synchronously.
        Task.detached(priority: .utility) { _ = Shell.loginPathDirs }

        cost.load()
        library.load()
        resolveIdentity()

        // Sessions + ports + config can all load concurrently.
        async let s: Void = sessions.load()
        async let p: Void = ports.load()
        async let c: Void = config.load(roots: scanRoots)
        _ = await (s, p, c)
        recomputeStats()
        // First local data is in (sessions/ports/config + stats): the Home page can now
        // crossfade from its skeleton to the real content. Set once; never reset.
        isReady = true
        summaries.ensureSummaries(for: config.agents)

        // Repos (git + gh) are slower; run the local git scan and the GitHub calls
        // concurrently so the commits-today number is not gated behind the local scan.
        async let local: Void = repos.loadLocal()
        async let gh: Void = repos.loadGitHub()
        _ = await (local, gh)
        lastGitHubRefresh = Date()
        if userNameOverride.isEmpty { userName = repos.userName }
        userLogin = repos.userLogin

        recomputeStats()
        refreshAssistantContext()
        refreshRunningClaude()
    }

    func recomputeStats() {
        stats = sessions.stats(window: .all)
        let month = sessions.stats(window: .days30)
        hygiene.recompute(repos: repos, config: config, stats: stats,
                          monthSpend: month.totalCost, monthlyBudget: monthlyBudget)
    }

    /// Refresh everything (toolbar refresh / ⌘R).
    func refreshAll() async {
        async let s: Void = sessions.load()
        async let p: Void = ports.load()
        async let c: Void = config.load(roots: scanRoots)
        async let local: Void = repos.loadLocal()
        async let gh: Void = repos.loadGitHub()
        _ = await (s, p, c, local, gh)
        lastGitHubRefresh = Date()
        // Re-probe live usage too, but only once it has been opened (avoids a
        // surprise Keychain access prompt on a plain ⌘R before the user visits Usage).
        if usage.hasLoaded { await usage.refresh() }
        recomputeStats()
        summaries.ensureSummaries(for: config.agents)
        refreshAssistantContext()
        showToast("Refreshed")
    }

    // MARK: - Library actions (with toast feedback)
    //
    // Thin wrappers over LibraryStore so any call site gets a consistent confirmation
    // toast (the store itself has no reference back to the toast). Favoriting, deleting,
    // saving, and collection membership all flash a short bottom-right toast.

    /// Toggle favorite for an item id and confirm with a toast.
    func toggleFavorite(_ id: String) {
        library.toggleFavorite(id)
        showToast(library.isFavorite(id) ? "Added to Favorites" : "Removed from Favorites")
    }

    /// Toggle collection membership and confirm with a toast naming the collection.
    func toggleMember(_ itemID: String, in collectionID: String) {
        let willAdd = !library.isMember(itemID, of: collectionID)
        library.toggleMember(itemID, in: collectionID)
        let name = library.collections.first { $0.id == collectionID }?.name ?? "collection"
        showToast(willAdd ? "Added to \(name)" : "Removed from \(name)")
    }

    /// Finish first-run onboarding: persist the chosen roots, mark onboarding done,
    /// and load the workspace for the first time.
    func completeOnboarding(roots: [String]) async {
        scanRoots = roots
        hasCompletedOnboarding = true
        await rescanWorkspace()
    }

    /// Append new scan roots (skipping ones already present) and rescan.
    func addScanRoots(_ paths: [String]) async {
        let fresh = paths.filter { !scanRoots.contains($0) }
        guard !fresh.isEmpty else { return }
        scanRoots.append(contentsOf: fresh)
        await rescanWorkspace()
    }

    /// Remove a scan root and rescan so repos/config update immediately.
    func removeScanRoot(_ path: String) async {
        guard scanRoots.contains(path) else { return }
        scanRoots.removeAll { $0 == path }
        await rescanWorkspace()
    }

    /// Reload everything that depends on the scan roots: local git repos and the
    /// project-level config scan. The scanRoots didSet has already synced
    /// repos.roots, so this just reloads and recomputes.
    func rescanWorkspace() async {
        async let local: Void = repos.loadLocal()
        async let c: Void = config.load(roots: scanRoots)
        _ = await (local, c)
        recomputeStats()
        summaries.ensureSummaries(for: config.agents)
        refreshAssistantContext()
    }

    /// Create a new skill / agent / rule / command from the modal: write the starter
    /// file (under ~/.claude, with the given display name), navigate to its library
    /// page, rescan so it appears, then float it to the top of the list and open it
    /// straight in the markdown editor.
    func createConfigItem(kind: ConfigKind, name: String) async {
        // 1. Write the starter file.
        guard let url = NewConfigItem.create(kind, name: name) else { return }
        // 2. Navigate to the kind's library route.
        route = NewConfigItem.route(for: kind)
        // 3. Rescan so the new item is picked up by the scanner.
        await rescanWorkspace()
        // 4. Resolve the scanned item's id by matching the file we just wrote (its
        //    stored path is the unresolved file.path), then mark it recently-created so
        //    ConfigBrowser floats it to the top and ConfigItemDetail auto-edits it.
        let created = config.items(of: kind).first { $0.path == url.path }
        recentlyCreatedID = created?.id
    }

    /// Create a starter CLAUDE.md at a repo's root (when it has none), rescan so it
    /// shows up in the repo's config + the Instructions list, jump to Instructions with
    /// it selected, and open the file in the user's editor to fill in (Instructions is
    /// read-only in-app). Wired to the "Create" button on the Repos detail CLAUDE.md row.
    func createRepoClaudeMd(at repoPath: String, repoName: String) async {
        let url = URL(fileURLWithPath: repoPath).appendingPathComponent("CLAUDE.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            let starter = """
            # \(repoName)

            Project instructions for Claude Code and other AI coding tools.

            ## Overview

            (What is this project, and what does it do?)

            ## Conventions

            -\u{0020}

            ## Notes

            -\u{0020}
            """
            do {
                try starter.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                showToast("Couldn't create CLAUDE.md")
                return
            }
            showToast("Created CLAUDE.md")
        }
        // Rescan so the new file is discovered, then jump to Instructions with it
        // selected and open it in the default editor for editing.
        await rescanWorkspace()
        route = .instructions
        recentlyCreatedID = config.instructions.first { $0.path == url.path }?.id
        NSWorkspace.shared.open(url)
    }

    /// Stale-guarded refresh used on app focus AND on sidebar navigation, so every page
    /// shows current data without a manual refresh. Re-scans sessions, local repos (git
    /// status / uncommitted counts), and config when the last scan is older than `maxAge`.
    /// The network-heavy GitHub scan (commits today + contribution calendar) runs on its
    /// OWN longer throttle so pushes appear without a manual Refresh, but tab-hopping
    /// doesn't hammer the network. The local scan is throttled by `sessions.lastScan`.
    func refreshIfStale(maxAge: TimeInterval = 45) async {
        guard didBootstrap else { return }
        // GitHub freshness on a ~2 min throttle, fired non-blocking so navigation stays
        // snappy. This is what makes "commits today" + the contribution heatmap update
        // after you push, instead of sticking at the bootstrap value.
        if Date().timeIntervalSince(lastGitHubRefresh) > 120 {
            lastGitHubRefresh = Date()
            Task { @MainActor in
                await repos.loadGitHub()
                if userNameOverride.isEmpty { userName = repos.userName }
                userLogin = repos.userLogin
                recomputeStats()
                refreshAssistantContext()
            }
        }
        if let last = sessions.lastScan, Date().timeIntervalSince(last) < maxAge { return }
        async let s: Void = sessions.load()
        async let local: Void = repos.loadLocal()
        async let c: Void = config.load(roots: scanRoots)
        _ = await (s, local, c)
        recomputeStats()
        refreshAssistantContext()
    }

    /// Seed the assistant with a compact snapshot of the live stack.
    func refreshAssistantContext() {
        let mcp = config.mcpServers.map(\.name).sorted().joined(separator: ", ")
        let skills = config.skills.count
        let agents = config.agents.count

        // Per-project breakdown keyed by FOLDER NAME (e.g. "llm-cheatsheet"), so the
        // assistant can answer "how many X in this project / the <folder> project"
        // accurately instead of guessing. Memory is counted per scope (folder name);
        // skills/agents/commands/mcp come from the same rollup the Stack tab uses.
        let memByProject = Dictionary(grouping: config.memories, by: \.scope).mapValues(\.count)
        let rollups = ProjectInsights.libraryRollups(config: config)
        var projectLines: [String] = []
        // Always surface every project that carries any memory or config, by folder name.
        let names = Set(rollups.map(\.projectName)).union(memByProject.keys)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for name in names.prefix(60) {
            let r = rollups.first { $0.projectName == name }
            let mem = memByProject[name] ?? r?.memory ?? 0
            let parts = [
                r.map { "\($0.skills) skills" }, r.map { "\($0.agents) agents" },
                r.map { "\($0.commands) commands" }, r.map { "\($0.mcp) MCP" },
                "\(mem) memory",
            ].compactMap { $0 }.joined(separator: ", ")
            projectLines.append("  - \(name): \(parts)")
        }
        let projectBlock = projectLines.isEmpty ? "  (none detected)" : projectLines.joined(separator: "\n")

        chat.stackContext = """
        - User: \(userName) (@\(userLogin))
        - Sessions: \(stats.sessions), messages: \(stats.messages), tokens: \(Fmt.compact(stats.totalTokens)), all-time cost: \(Fmt.money(stats.totalCost))
        - Favorite model: \(stats.favoriteModel ?? "n/a"); current streak: \(stats.currentStreak)d
        - Local repos: \(repos.repos.count) (\(repos.reposWithSkills) with skills, \(repos.reposWithAgents) with agents)
        - Skills: \(skills), Agents: \(agents), Hooks: \(config.hooks.count), Memory files: \(config.memories.count) (across all scopes)
        - MCP servers: \(mcp.isEmpty ? "none" : mcp)
        - Listening ports: \(ports.ports.map { String($0.port) }.joined(separator: ", "))
        - Per-project breakdown (by folder name; "Global" = user-level ~/.claude config):
        \(projectBlock)
        """
    }

    private func resolveIdentity() {
        guard let res = Shell.run(tool: "gh", ["api", "user", "--jq", "{login: .login, name: .name}"]), res.ok,
              let data = res.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let login = json["login"] as? String { userLogin = login; repos.userLogin = login }
        if let name = json["name"] as? String, !name.isEmpty {
            repos.userName = name
            if userNameOverride.isEmpty { userName = name }
        }
    }
}
