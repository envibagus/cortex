import SwiftUI
import Observation
import AppKit
import ServiceManagement

// MARK: - AppModel
//
// The single source of truth shared through the environment. Owns every data
// store, the current route, the command-palette state, and the user's settings,
// and orchestrates the initial + on-demand data loads.

@MainActor
@Observable
final class AppModel {
    // Navigation. The didSet records route changes for ⌘[ / ⌘] history (back/forward
    // set the route with isNavigatingHistory so they don't re-push).
    var route: Route = .readout {
        didSet {
            guard !isNavigatingHistory, route != oldValue else { return }
            if historyIndex < routeHistory.count - 1 {
                routeHistory.removeSubrange((historyIndex + 1)...)
            }
            routeHistory.append(route)
            historyIndex = routeHistory.count - 1
        }
    }
    var showCommandPalette = false
    // A Settings tab to land on when Settings is opened programmatically (e.g. the
    // menu-bar panel's Settings button). SettingsView consumes + clears it on appear.
    var settingsTabHint: String?

    // A local repo (its path == RepoInfo.id) to auto-select when the Repos page opens,
    // set by the Home "By project" tables so a row click deep-links to that repo.
    // ReposView consumes + clears it.
    var repoSelectionHint: String?

    // An item id (skill/agent path, or MCP server name) to auto-select when its library page
    // opens - set by the ⌘K palette so clicking a result deep-links to that exact item, not
    // just the page. The destination page (ConfigBrowser / ToolsView) consumes + clears it.
    var librarySelectionHint: String?

    // Route history for ⌘[ (back) / ⌘] (forward).
    private var routeHistory: [Route] = [.readout]
    private var historyIndex = 0
    private var isNavigatingHistory = false
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < routeHistory.count - 1 }
    func goBack() {
        guard canGoBack else { return }
        isNavigatingHistory = true; historyIndex -= 1; route = routeHistory[historyIndex]; isNavigatingHistory = false
    }
    func goForward() {
        guard canGoForward else { return }
        isNavigatingHistory = true; historyIndex += 1; route = routeHistory[historyIndex]; isNavigatingHistory = false
    }

    // ⌘F: bump this token; views with a search field observe it and focus theirs.
    private(set) var focusSearchToken = 0
    func focusSearch() { focusSearchToken += 1 }

    // ⌘B / ⌘\: bump this token; ContentView observes it and flips the sidebar's visibility.
    private(set) var sidebarToggleToken = 0
    func toggleSidebar() { sidebarToggleToken += 1 }

    // ⌘R: bumped by refreshAll so the current split page replays its skeleton while the
    // data reloads (a visible "checking for new data" cue). refreshIfStale does NOT bump
    // it, so ordinary tab-hopping never flashes a skeleton.
    private(set) var refreshToken = 0

    // The item id a keyboard ⌫ (Delete) asked to remove. The mounted detail pane watches
    // this and raises its OWN native confirmation when it matches, then clears it, so the
    // list-focused Delete reuses the existing confirm + Undo flow.
    var pendingDeleteItemID: String?

    /// Copy a path / endpoint to the clipboard and confirm with a toast (⌘C on a list row).
    func copyPath(_ path: String) {
        guard !path.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        showToast("Path copied")
    }

    /// The visible sidebar routes, top to bottom (pinned first, then each section's
    /// routes), excluding hidden routes and Settings. ⌘1-9 bind to the first nine, so the
    /// number matches the item's position in the sidebar (Home=1, Assistant=2, Skills=3, ...).
    var sidebarVisibleRoutes: [Route] {
        var out = pinnedRouteList.filter { !isHidden($0) }
        for section in Sidebar.sections {
            out.append(contentsOf: section.routes.filter { !isPinned($0) && !isHidden($0) })
        }
        return out
    }

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

    /// cmd+N: open the new-item creator for the current Library route's kind. No-op on
    /// pages that don't create items (the creatable kinds are skill/agent/rule/command).
    func newItemForCurrentRoute() {
        switch route {
        case .skills: newItemKind = .skill
        case .agents: newItemKind = .agent
        case .rules: newItemKind = .rule
        case .commands: newItemKind = .command
        default: break
        }
    }

    /// ⌘⇧R: rescan just the data behind the current page (cheaper + more targeted than a
    /// full refresh). Falls back to refreshAll on pages without a page-specific source.
    func rescanCurrentPage() {
        Task {
            switch route {
            case .ports: await ports.load()
            case .live, .sessions, .readout: await sessions.load(); recomputeStats()
            case .usage: if usage.hasLoaded { await usage.refresh() }
            default: await refreshAll(); return
            }
            showToast("Rescanned")
        }
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

    // MARK: - Menu-bar preferences
    //
    // All persisted via the same observed-stored-rawValue + didSet pattern as the sort
    // prefs above, so changing one re-renders both the Settings UI and the menu bar (the
    // controller observes these reads). Side-effecting prefs (visibility, live activity,
    // launch-at-login, hotkey) are applied through dedicated methods below.

    private var menuBarIconModeRaw: String = UserDefaults.standard.string(forKey: "menuBarIconMode") ?? MenuBarIconMode.text.rawValue {
        didSet { UserDefaults.standard.set(menuBarIconModeRaw, forKey: "menuBarIconMode") }
    }
    var menuBarIconMode: MenuBarIconMode {
        get { MenuBarIconMode(rawValue: menuBarIconModeRaw) ?? .text }
        set { menuBarIconModeRaw = newValue.rawValue }
    }

    private var menuBarPrimaryWindowRaw: String = UserDefaults.standard.string(forKey: "menuBarPrimaryWindow") ?? UsageWindow.session.rawValue {
        didSet { UserDefaults.standard.set(menuBarPrimaryWindowRaw, forKey: "menuBarPrimaryWindow") }
    }
    var menuBarPrimaryWindow: UsageWindow {
        get { UsageWindow(rawValue: menuBarPrimaryWindowRaw) ?? .session }
        set { menuBarPrimaryWindowRaw = newValue.rawValue }
    }

    private var menuBarUsageModeRaw: String = UserDefaults.standard.string(forKey: "menuBarUsageMode") ?? UsageDisplayMode.used.rawValue {
        didSet { UserDefaults.standard.set(menuBarUsageModeRaw, forKey: "menuBarUsageMode") }
    }
    var menuBarUsageMode: UsageDisplayMode {
        get { UsageDisplayMode(rawValue: menuBarUsageModeRaw) ?? .used }
        set { menuBarUsageModeRaw = newValue.rawValue }
    }

    private var menuBarResetStyleRaw: String = UserDefaults.standard.string(forKey: "menuBarResetStyle") ?? ResetTimerStyle.relative.rawValue {
        didSet { UserDefaults.standard.set(menuBarResetStyleRaw, forKey: "menuBarResetStyle") }
    }
    var menuBarResetStyle: ResetTimerStyle {
        get { ResetTimerStyle(rawValue: menuBarResetStyleRaw) ?? .relative }
        set { menuBarResetStyleRaw = newValue.rawValue }
    }

    private var menuBarTimeFormatRaw: String = UserDefaults.standard.string(forKey: "menuBarTimeFormat") ?? MenuBarTimeFormat.auto.rawValue {
        didSet { UserDefaults.standard.set(menuBarTimeFormatRaw, forKey: "menuBarTimeFormat") }
    }
    var menuBarTimeFormat: MenuBarTimeFormat {
        get { MenuBarTimeFormat(rawValue: menuBarTimeFormatRaw) ?? .auto }
        set { menuBarTimeFormatRaw = newValue.rawValue }
    }

    private var menuBarRefreshIntervalRaw: Int = (UserDefaults.standard.object(forKey: "menuBarRefreshInterval") as? Int) ?? MenuBarRefreshInterval.m5.rawValue {
        didSet { UserDefaults.standard.set(menuBarRefreshIntervalRaw, forKey: "menuBarRefreshInterval") }
    }
    var menuBarRefreshInterval: MenuBarRefreshInterval {
        get { MenuBarRefreshInterval(rawValue: menuBarRefreshIntervalRaw) ?? .m5 }
        set { menuBarRefreshIntervalRaw = newValue.rawValue }
    }

    /// Whether the menu-bar item is shown at all. Default true; toggling adds/removes the
    /// status item live.
    var showMenuBarItem: Bool = (UserDefaults.standard.object(forKey: "showMenuBarItem") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(showMenuBarItem, forKey: "showMenuBarItem")
            menuBar?.applyVisibility(showMenuBarItem)
        }
    }

    /// Whether live activity is enabled. Read-only mirror of the persisted flag; flip it
    /// through `setLiveActivity(_:)` so the hook install/uninstall + error surfacing run.
    private(set) var menuBarLiveActivityEnabled: Bool = (UserDefaults.standard.object(forKey: "menuBarLiveActivity") as? Bool) ?? false

    /// Play a soft chime when a turn longer than ~10 seconds finishes (trivial instant turns
    /// stay silent). Default off.
    var menuBarCompletionSound: Bool = (UserDefaults.standard.object(forKey: "menuBarCompletionSound") as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(menuBarCompletionSound, forKey: "menuBarCompletionSound")
            activity.completionSoundEnabled = menuBarCompletionSound
            // The chime is driven by the same turn-detection hooks/poll as live activity, so
            // it works INDEPENDENTLY: turning it on installs the hooks (if live activity isn't
            // already running them); turning it off tears them down only when live activity
            // isn't using them too.
            if menuBarCompletionSound {
                activity.completionSoundName = menuBarCompletionSoundName
                if !activity.isInstalled, let error = activity.enable() {
                    showToast(error, duration: 5)
                    // Install failed: roll the preference back off so we never persist an
                    // enabled-but-not-installed state (it would stay silently broken across
                    // launches). Assigning here does not re-enter didSet, so undo its side
                    // effects explicitly.
                    menuBarCompletionSound = false
                    UserDefaults.standard.set(false, forKey: "menuBarCompletionSound")
                    activity.completionSoundEnabled = false
                }
            } else if !menuBarLiveActivityEnabled, activity.isInstalled {
                activity.disable()
            }
        }
    }

    /// The chosen completion sound: a bundled "hero-complete-<pack>.caf". Default "soft".
    /// Same observed-stored-rawValue + didSet pattern as the other prefs; the name is
    /// mirrored into ActivityService so changing it takes effect on the next completion.
    private var menuBarCompletionSoundNameRaw: String = UserDefaults.standard.string(forKey: "menuBarCompletionSoundName") ?? "hero-complete-soft" {
        didSet {
            UserDefaults.standard.set(menuBarCompletionSoundNameRaw, forKey: "menuBarCompletionSoundName")
            activity.completionSoundName = menuBarCompletionSoundNameRaw
        }
    }
    var menuBarCompletionSoundName: String {
        get { menuBarCompletionSoundNameRaw }
        set { menuBarCompletionSoundNameRaw = newValue }
    }

    /// Show the spend breakdown (today / last 7 / last 30 days cost + tokens) in the menu
    /// bar dropdown panel. Default on; turn off to keep dollar amounts off the menu bar.
    var menuBarShowSpend: Bool = (UserDefaults.standard.object(forKey: "menuBarShowSpend") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(menuBarShowSpend, forKey: "menuBarShowSpend") }
    }

    /// Fire the one-shot confetti burst when a turn finishes. Display-only sub-option of live
    /// activity (the burst only shows while live activity is on), so no hooks to install here.
    /// Default on.
    var menuBarConfetti: Bool = (UserDefaults.standard.object(forKey: "menuBarConfetti") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(menuBarConfetti, forKey: "menuBarConfetti") }
    }

    // Global hotkey to toggle the panel, stored as a Carbon virtual keycode + modifier
    // mask. keyCode -1 means "unset" (keyCode 0 is a valid key).
    private var hotKeyCodeRaw: Int = (UserDefaults.standard.object(forKey: "menuBarHotKeyCode") as? Int) ?? -1 {
        didSet { UserDefaults.standard.set(hotKeyCodeRaw, forKey: "menuBarHotKeyCode") }
    }
    private var hotKeyModifiersRaw: Int = (UserDefaults.standard.object(forKey: "menuBarHotKeyModifiers") as? Int) ?? 0 {
        didSet { UserDefaults.standard.set(hotKeyModifiersRaw, forKey: "menuBarHotKeyModifiers") }
    }

    /// The configured global hotkey, or nil when unset.
    var menuBarHotKey: HotKeyCombo? {
        get { hotKeyCodeRaw >= 0 ? HotKeyCombo(keyCode: UInt32(hotKeyCodeRaw), carbonModifiers: UInt32(hotKeyModifiersRaw)) : nil }
        set {
            hotKeyCodeRaw = newValue.map { Int($0.keyCode) } ?? -1
            hotKeyModifiersRaw = Int(newValue?.carbonModifiers ?? 0)
            menuBar?.applyHotKey(newValue)
        }
    }

    /// Whether the app is registered to launch at login (reads the live service status).
    var menuBarLaunchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { setLaunchAtLogin(newValue) }
    }

    /// Register / unregister the app as a login item, surfacing failures as a toast
    /// (unsigned builds can't register; that is expected).
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            showToast("Couldn't update Launch at Login")
        }
    }

    /// Turn live activity on or off: install/remove the Claude Code hooks and start/stop
    /// the state-file watcher. Surfaces install failures and leaves the flag off on error.
    func setLiveActivity(_ on: Bool) {
        if on {
            activity.completionSoundEnabled = menuBarCompletionSound
            activity.completionSoundName = menuBarCompletionSoundName
            // Install the hooks + poll unless the completion sound already has them running.
            if !activity.isInstalled, let error = activity.enable() {
                menuBarLiveActivityEnabled = false
                UserDefaults.standard.set(false, forKey: "menuBarLiveActivity")
                showToast(error, duration: 5)
                return
            }
            menuBarLiveActivityEnabled = true
            workflows.start()
            showToast("Live activity on")
        } else {
            workflows.stop()
            menuBarLiveActivityEnabled = false
            // Keep the turn-detection monitoring alive if the completion sound still needs it.
            if !menuBarCompletionSound { activity.disable() }
            showToast("Live activity off")
        }
        UserDefaults.standard.set(menuBarLiveActivityEnabled, forKey: "menuBarLiveActivity")
    }

    /// Bring the main window to the front (from a menu-bar action), optionally switching
    /// to a route first. The main scene is a single `Window`, so `openMainWindow`
    /// (openWindow(id: "main")) orders the existing window forward, or recreates it if it
    /// was closed to the menu bar - its .task then re-runs bootstrap and reloads the data
    /// freed on close. No manual NSApp.windows lookup is needed: the singleton scene
    /// handles both cases and can't produce a duplicate. `activate` first so the click
    /// steals focus from whatever app was frontmost (ignoringOtherApps is soft-deprecated
    /// on macOS 14+, but it's the reliable way to force-front a .regular app from a status
    /// item; plain `activate()` often fails to bring the window forward).
    func revealMainWindow(route: Route? = nil) {
        if let route { self.route = route }
        NSApp.activate(ignoringOtherApps: true)
        openMainWindow?()
    }

    /// Check GitHub for a newer release. A manual check (menu / Settings) always reports
    /// the result in an alert; the automatic launch check only flashes a toast when a
    /// newer version is available. Install stays manual (the app isn't notarized).
    func checkForUpdates(manual: Bool) {
        Task { @MainActor in
            await updates.check()
            if manual {
                let alert = NSAlert()
                if updates.updateAvailable, let url = updates.releaseURL {
                    alert.messageText = "Update available"
                    alert.informativeText = "\(updates.latestTag ?? "A newer version") is available. You're on \(updates.currentVersion)."
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
                } else if let error = updates.lastError {
                    alert.messageText = "Couldn't check for updates"
                    alert.informativeText = error
                    alert.runModal()
                } else {
                    alert.messageText = "You're up to date"
                    alert.informativeText = "Cortex \(updates.currentVersion) is the latest version."
                    alert.runModal()
                }
            } else if updates.updateAvailable, let url = updates.releaseURL {
                showToast("Update available: \(updates.latestTag ?? "")",
                          action: ToastAction(label: "Download") { NSWorkspace.shared.open(url) },
                          duration: 8)
            }
        }
    }

    /// Create the menu-bar controller and start the long-lived refresh loops. Idempotent.
    func startMenuBar() {
        if menuBar == nil {
            menuBar = MenuBarController(model: self)
            menuBar?.start()
            // One automatic update check per launch (notifies via toast if newer).
            checkForUpdates(manual: false)
        }
        // Live activity + the workflow scan are one opt-in: both run only when enabled, so a
        // user who left it off pays no background hook polling or projects-tree scanning.
        // Resume the turn-detection poll if EITHER live activity or the completion sound is
        // on (both rely on the same installed hooks). The workflow scan is live-activity only.
        if menuBarLiveActivityEnabled || menuBarCompletionSound {
            activity.completionSoundEnabled = menuBarCompletionSound
            activity.completionSoundName = menuBarCompletionSoundName
            activity.resumeIfInstalled()
        }
        if menuBarLiveActivityEnabled {
            workflows.start()
        }
        startBackgroundLoops()
    }

    /// Long-lived loops that keep usage + running-claude fresh independent of the window.
    private func startBackgroundLoops() {
        guard usageLoop == nil else { return }
        usageLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                // After a loud probe failure, retry soon (so a network blip / rate-limit
                // doesn't leave the gauge stale for a full interval); otherwise wait the
                // configured interval.
                let full = Double(self.menuBarRefreshInterval.rawValue)
                let secs = self.usage.claudeTransientlyFailing ? min(full, 30) : full
                try? await Task.sleep(for: .seconds(secs))
                guard !Task.isCancelled else { break }
                if self.usage.hasLoaded { await self.usage.refresh() }
            }
        }
        claudeLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                // The running-`claude` scan feeds ONLY the Live page + its sidebar badge, so
                // skip the periodic `ps` scan while Live is hidden (nothing else reads it).
                // The loop stays alive on a slow idle tick and resumes scanning the moment
                // Live is shown again. This only pauses Cortex's own poll; no OS process is
                // signalled or slept.
                if self.isHidden(.live) {
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
                self.refreshRunningClaude()
                try? await Task.sleep(for: .seconds(self.route == .live ? 8 : 30))
            }
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
    // Actionable workspace-hygiene findings (Health > Hygiene tab): stale branches,
    // stashes, stray dev servers, .env exposure, dead dirs, diverged/dirty repos.
    let hygieneScanner = HygieneScanner()
    let library = LibraryStore()
    let usage = UsageService()
    // Live "what is Claude Code doing now" signal for the menu bar (off until enabled).
    let activity = ActivityService()
    // Live progress of running dynamic workflows (N/M subagents done) for the menu bar.
    let workflows = WorkflowMonitor()
    // Checks the public GitHub repo for a newer release (notify + link; no auto-install).
    let updates = UpdateService()
    // On-device AI one-line summaries for long agent descriptions (Foundation Models).
    let summaries = SummaryService()

    /// Shared handle so the AppKit app delegate (quit prompt) can reach the live model.
    @ObservationIgnored static weak var current: AppModel?

    // The menu-bar item controller (NSStatusItem + popover + global hotkey). Created
    // once at bootstrap; nil until then. Owns no app state, just renders model state.
    @ObservationIgnored var menuBar: MenuBarController?
    /// SwiftUI's openWindow action, captured once the main window first appears, so the
    /// menu bar can reliably reopen the window after it's been closed (when the heavy data
    /// was freed). nil until the window has appeared at least once.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    // Long-lived background loops (usage re-probe + running-claude scan) kept on the
    // model so they outlive the window: the menu bar must stay fresh even with no window.
    @ObservationIgnored private var usageLoop: Task<Void, Never>?
    @ObservationIgnored private var claudeLoop: Task<Void, Never>?

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
        AppModel.current = self
        Self.migrateSummaryBackendDefault()
    }

    /// One-time migration: the AI-summary default is Apple Intelligence (on-device, no
    /// extra Claude sessions / menu-bar noise). Installs still carrying the short-lived
    /// Claude default flip to Apple once. A deliberate later choice sticks, because the
    /// flag is then set and this never runs again.
    private static func migrateSummaryBackendDefault() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "didMigrateSummaryDefaultToApple") else { return }
        if d.string(forKey: "summaryBackend") == SummaryBackend.claude.rawValue {
            d.set(SummaryBackend.apple.rawValue, forKey: "summaryBackend")
        }
        d.set(true, forKey: "didMigrateSummaryDefaultToApple")
    }

    /// First-run load: pricing, sessions, ports, config, repos, then hygiene.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        // Warm the login-shell PATH probe off-main so the first which() miss (e.g. the
        // assistant engine check) never blocks the UI resolving it synchronously.
        Task.detached(priority: .utility) { _ = Shell.loginPathDirs }

        // Bring up the menu-bar item + window-independent refresh loops right away, so it
        // appears at launch rather than after the slower repo / GitHub scans below.
        startMenuBar()

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
        // Run the actionable hygiene scan now (after repos) so the Home score + the
        // Health page are derived from the same findings, not a lazy per-page scan.
        await loadHygiene()
        refreshAssistantContext()
        refreshRunningClaude()
    }

    /// Free the heavy parsed data (sessions, repos, config, derived stats) when the main
    /// window closes, so the resident set drops while only the menu bar keeps running.
    /// The usage probe + menu bar + background loops stay live; reopening the window
    /// re-runs `bootstrap()` (didBootstrap is reset) and reloads everything.
    func releaseHeavyData() {
        sessions.clear()
        repos.clear()
        config.clear()
        hygieneScanner.clear()
        stats = UsageStats()
        didBootstrap = false
        isReady = false
    }

    func recomputeStats() {
        stats = sessions.stats(window: .all)
        let month = sessions.stats(window: .days30)
        hygiene.recompute(repos: repos, config: config, stats: stats,
                          monthSpend: month.totalCost, monthlyBudget: monthlyBudget)
    }

    /// Refresh everything (toolbar refresh / ⌘R).
    func refreshAll() async {
        // Replay the current split page's skeleton while the reload runs, so a manual
        // refresh visibly reloads (and any new data lands behind the shimmer).
        refreshToken += 1
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
        await loadHygiene()
        summaries.ensureSummaries(for: config.agents)
        refreshAssistantContext()
        showToast("Refreshed")
    }

    // MARK: - Hygiene scan + actions
    //
    // The scan runs eagerly at bootstrap/refresh (so Home + Health share one source).
    // Each action runs its git/kill operation off-main, and on success drops just the
    // resolved finding from the scan (instant list + score update) rather than paying
    // for a full re-scan; failures leave the finding in place.

    /// Run the actionable hygiene scan from current repos + ports + scan roots.
    func loadHygiene() async {
        await hygieneScanner.load(repos: repos.repos, ports: ports.ports, roots: scanRoots)
    }

    /// Shared scaffold for the simple fixes (kill / drop / pull): run `work` off-main,
    /// then on success drop the resolved finding + toast, else toast the failure.
    private func runHygieneFix(findingID: String, success: String, failure: String,
                               _ work: @escaping @Sendable () -> Bool) {
        Task { @MainActor in
            let ok = await Task.detached(priority: .userInitiated) { work() }.value
            if ok { hygieneScanner.remove(id: findingID); showToast(success) }
            else { showToast(failure) }
        }
    }

    /// Send a terminate signal to a listening process.
    func killProcess(pid: Int, name: String, findingID: String) {
        runHygieneFix(findingID: findingID,
                      success: "Killed \(name) (pid \(pid))",
                      failure: "Couldn't kill pid \(pid)") {
            Shell.run(tool: "kill", ["\(pid)"])?.ok ?? false
        }
    }

    /// Delete a local branch. The tip SHA is read from `branch -D`'s own output (one
    /// operation, no rev-parse/delete race), so the Undo always points to the real tip.
    func deleteBranch(repoPath: String, branch: String, repoName: String, findingID: String) {
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Shell.git(repoPath, ["branch", "-D", branch])
            }.value
            guard let result, result.ok else { showToast("Couldn't delete \(branch)"); return }
            hygieneScanner.remove(id: findingID)

            // Offer Undo by recreating the branch at the SHA git reported it was at.
            let undo: ToastAction? = Self.parseDeletedSHA(result.stdout).map { sha in
                ToastAction(label: "Undo") { [weak self] in
                    Task { @MainActor in
                        _ = await Task.detached(priority: .userInitiated) {
                            Shell.git(repoPath, ["branch", branch, sha])
                        }.value
                        await self?.loadHygiene()
                    }
                }
            }
            showToast("Deleted \(branch) in \(repoName)", action: undo)
        }
    }

    /// The abbreviated SHA from `git branch -D` output ("Deleted branch X (was abc1234).").
    private static func parseDeletedSHA(_ output: String) -> String? {
        guard let mark = output.range(of: "(was ") else { return nil }
        let rest = output[mark.upperBound...]
        guard let end = rest.firstIndex(of: ")") else { return nil }
        let sha = rest[..<end].trimmingCharacters(in: .whitespaces)
        return sha.isEmpty ? nil : sha
    }

    /// Drop a git stash. The selector (stash@{N}) is re-resolved from the stash's commit
    /// SHA right before dropping, so a list that renumbered after an earlier drop can't
    /// make this remove the wrong entry.
    func dropStash(repoPath: String, sha: String, ref: String, repoName: String, findingID: String) {
        runHygieneFix(findingID: findingID,
                      success: "Dropped \(ref) in \(repoName)",
                      failure: "Couldn't drop \(ref) in \(repoName)") {
            guard let list = Shell.git(repoPath, ["stash", "list", "--format=%gd %H"])?.stdout else { return false }
            let selector = list.split(separator: "\n")
                .first { $0.contains(sha) }?
                .split(separator: " ").first.map(String.init) ?? ref
            return Shell.git(repoPath, ["stash", "drop", selector])?.ok ?? false
        }
    }

    /// Fast-forward pull a repo that's behind its upstream.
    func pullRepo(repoPath: String, repoName: String, findingID: String) {
        runHygieneFix(findingID: findingID,
                      success: "Pulled \(repoName)",
                      failure: "Couldn't fast-forward \(repoName)") {
            guard let git = Shell.which("git") else { return false }
            // GIT_TERMINAL_PROMPT=0: never block on a credential prompt the GUI can't
            // answer. hooksPath=/dev/null: don't run the repo's (possibly slow/arbitrary)
            // post-merge hook unattended from the app.
            return Shell.run(git, ["-C", repoPath, "-c", "core.hooksPath=/dev/null", "pull", "--ff-only"],
                             env: ["GIT_TERMINAL_PROMPT": "0"]).ok
        }
    }

    /// Move a dead directory to the Trash (recoverable).
    func trashDirectory(path: String, findingID: String) {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            hygieneScanner.remove(id: findingID)
            showToast("Moved \(url.lastPathComponent) to Trash")
        } catch {
            showToast("Couldn't move to Trash")
        }
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

        // Last-30-days spend so the assistant can answer "how much this month" from a real
        // figure instead of only the all-time total.
        let last30Cost = sessions.stats(window: .days30).totalCost

        chat.stackContext = """
        - User: \(userName) (@\(userLogin))
        - Sessions: \(stats.sessions), messages: \(stats.messages), tokens: \(Fmt.compact(stats.totalTokens))
        - Cost: \(Fmt.money(stats.totalCost)) all-time, \(Fmt.money(last30Cost)) in the last 30 days
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
