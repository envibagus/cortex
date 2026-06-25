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
        // A single identified window so the menu bar can reopen it via openWindow after
        // it's been closed to the menu bar (Cmd-W).
        WindowGroup(id: "main") {
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
            // ⌘\ toggles the sidebar, beside the system sidebar commands.
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") { model.toggleSidebar() }
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
    /// Clicking the dock icon (or `open`-ing the app) with no window reopens the main
    /// window via the captured openWindow action, which reliably re-runs bootstrap and
    /// reloads the data freed on close.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.current?.openMainWindow?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Don't prompt if there's no menu bar to keep (e.g. it's been turned off).
        guard AppModel.current?.showMenuBarItem == true else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Quit Cortex?"
        alert.informativeText = "Quit completely, or keep Cortex running in the menu bar?"
        alert.addButton(withTitle: "Quit")             // .alertFirstButtonReturn
        alert.addButton(withTitle: "Keep in Menu Bar") // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")           // .alertThirdButtonReturn

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .terminateNow
        case .alertSecondButtonReturn:
            // Close the window (frees the heavy data); keep the process + menu bar alive.
            NSApp.windows.filter { $0.styleMask.contains(.titled) }.forEach { $0.close() }
            return .terminateCancel
        default:
            return .terminateCancel
        }
    }
}
