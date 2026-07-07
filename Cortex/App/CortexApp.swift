import SwiftUI
import AppKit

// MARK: - CortexApp
//
// App entry. A single main window: Settings is an in-app route (.settings), NOT a
// separate Settings scene, so there is one Settings UI (no duplication). ⌘, just
// navigates to it. The model is created once and shared through the environment;
// bootstrap kicks off on first appear.

@main
struct CortexApp: App {
    @State private var model = AppModel()
    // App delegate handles the Cmd-Q prompt (quit vs keep in the menu bar).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Appearance preference: System / Light / Dark.
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.dark.rawValue
    private var appearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .dark }

    var body: some Scene {
        // A `Window` (NOT `WindowGroup`): this is a singleton scene, so there is only ever
        // one main window. `openWindow(id: "main")` ORDERS THE EXISTING WINDOW TO THE FRONT
        // (or recreates it if it was closed to the menu bar via Cmd-W) - it can never spawn a
        // duplicate. A `WindowGroup` is a multi-window template: openWindow(id:) on a group
        // always creates a NEW window, which produced double windows every time a reopen path
        // (dock reopen / menu bar / revealMainWindow) fired against an already-open window.
        // The title text is blanked by WindowConfigurator (titleVisibility=.hidden), so the
        // "Cortex" here is only the accessibility / window-menu label.
        Window("Cortex", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1040, minHeight: 680)
                // Apply the theme NATIVELY via NSApp.appearance rather than
                // `.preferredColorScheme`. preferredColorScheme re-renders the whole
                // SwiftUI tree and, because the segmented control wraps the change in an
                // animation, crossfades every color (including all the GPU-heavy Liquid
                // Glass surfaces) at once - which made switching theme (especially to
                // "System") feel slow. Setting NSApp.appearance is an instant AppKit swap
                // that SwiftUI's semantic colors follow, with no animated storm.
                .onAppear { applyAppearance(appearance) }
                .onChange(of: appearanceRaw) { _, _ in applyAppearance(appearance) }
                .task { await model.bootstrap() }
                // Re-scan when the app regains focus so cost/usage stay current.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await model.refreshIfStale() }
                }
                // When the window closes, free the heavy parsed data so the app's
                // resident memory drops back down while only the menu bar keeps running.
                // Reopening the window re-runs bootstrap and reloads everything.
                .onDisappear { model.releaseHeavyData() }
        }
        // .titleBar (NOT .hiddenTitleBar): hiding the band makes NavigationSplitView
        // render the sidebar as a detached floating inset panel on this macOS. The slim
        // band is the price of a flush, solid sidebar. See cortex-sidebar-window-chrome.
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // "Check for Updates..." sits in the app menu, right under About Cortex.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates\u{2026}") { model.checkForUpdates(manual: true) }
            }
            // ⌘, opens the in-app Settings page (replacing the default Settings-window
            // menu item) so there is a single Settings UI, no separate window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") { model.route = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // ⌘N creates a new Library item for the current page (skill/agent/rule/command).
            CommandGroup(replacing: .newItem) {
                Button("New Item") { model.newItemForCurrentRoute() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            // ⌘B toggles the sidebar, beside the system sidebar commands. ⌘\ is kept as a
            // second binding for muscle memory (a menu item shows only one shortcut, so the
            // extra button carries the alternate key without a confusing duplicate label).
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") { model.toggleSidebar() }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Toggle Sidebar (\\)") { model.toggleSidebar() }
                    .keyboardShortcut("\\", modifiers: .command)
            }
            // ⌘K palette, ⌘F focus search, ⌘R refresh all, ⌘⇧R rescan the current page.
            CommandGroup(after: .toolbar) {
                Button("Command Palette") { model.showCommandPalette.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Find") { model.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Refresh") { Task { await model.refreshAll() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Rescan Page") { model.rescanCurrentPage() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            // "Go": ⌘1-9 jump to the first nine sidebar pages (top to bottom), plus
            // ⌘[ / ⌘] back/forward through route history and ⌘L to the Assistant.
            CommandMenu("Go") {
                ForEach(Array(model.sidebarVisibleRoutes.prefix(9).enumerated()), id: \.offset) { index, route in
                    Button(route.title) { model.route = route }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                Divider()
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[", modifiers: .command).disabled(!model.canGoBack)
                Button("Forward") { model.goForward() }
                    .keyboardShortcut("]", modifiers: .command).disabled(!model.canGoForward)
                Divider()
                Button("Assistant") { model.route = .assistant }
                    .keyboardShortcut("l", modifiers: .command)
            }
        }
    }

    /// Force the app's appearance natively. `System` clears the override so the app
    /// follows the macOS setting; Light / Dark pin a fixed appearance. Instant (no
    /// SwiftUI re-render animation).
    private func applyAppearance(_ appearance: AppAppearance) {
        let named: NSAppearance? = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = named
    }
}

// MARK: - App delegate (quit prompt)
//
// Cmd-Q (or Quit) prompts whether to fully quit or keep Cortex running in the menu bar.
// "Keep in Menu Bar" closes the window (which frees the heavy data via the window's
// onDisappear) and cancels termination, so only the lightweight menu bar stays. Cmd-W
// already just closes the window, leaving the menu bar - no prompt needed there.

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Refuse to run a second instance. Two processes sharing this bundle id each register
    /// a menu-bar status item for it, and that collision corrupts macOS's menu-bar
    /// placement for the app - the item can end up parked off-screen until the next login.
    /// If another instance is already running, hand off to it and quit before any UI or
    /// status item is created. The kill(pid, 0) probe confirms the other process is truly
    /// alive at the kernel level, so a stale entry can never make a fresh launch quit itself.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me && !$0.isTerminated && kill($0.processIdentifier, 0) == 0 }
        if let existing = others.first {
            existing.activate(options: [.activateAllWindows])
            // exit, not NSApp.terminate: terminate routes through applicationShouldTerminate,
            // whose "Keep in Menu Bar" prompt would cancel termination and let this duplicate
            // instance keep running - the exact collision this guard exists to prevent.
            exit(0)
        }
    }

    /// Clicking the dock icon (or `open`-ing the app) with no window reopens the main
    /// window via the captured openWindow action, which reliably re-runs bootstrap and
    /// reloads the data freed on close.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.current?.openMainWindow?() }
        return true
    }

    /// Closing the last window (Cmd-W) must NOT quit Cortex: it lives on in the menu bar
    /// with no window open. A single `Window` scene otherwise terminates the app when its
    /// only window closes, which made a plain Cmd-W surface the Cmd-Q quit prompt (and
    /// "Keep in Menu Bar" - which closes the window - re-fire it in a loop). Returning
    /// false closes the window (freeing heavy data via its onDisappear) and leaves the
    /// process + menu bar running; the window reopens on demand via openWindow(id:"main").
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Don't prompt if there's no menu bar to keep (e.g. it's been turned off).
        guard AppModel.current?.showMenuBarItem == true else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Quit Cortex?"
        alert.informativeText = "Quit completely, or keep Cortex running in the menu bar?"
        // "Keep in Menu Bar" is the DEFAULT (prominent) button - keeping Cortex around is the
        // safer, more common choice; fully quitting is the deliberate one.
        alert.addButton(withTitle: "Keep in Menu Bar") // .alertFirstButtonReturn (default)
        alert.addButton(withTitle: "Quit")             // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")           // .alertThirdButtonReturn

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Keep: close the window (frees the heavy data); keep the process + menu bar alive.
            NSApp.windows.filter { $0.styleMask.contains(.titled) }.forEach { $0.close() }
            return .terminateCancel
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
