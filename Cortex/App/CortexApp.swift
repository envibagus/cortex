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
    // Appearance preference: System / Light / Dark.
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.dark.rawValue
    private var appearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .dark }

    var body: some Scene {
        WindowGroup {
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
        }
        // .titleBar (NOT .hiddenTitleBar): hiding the band makes NavigationSplitView
        // render the sidebar as a detached floating inset panel on this macOS. The slim
        // band is the price of a flush, solid sidebar. See cortex-sidebar-window-chrome.
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // ⌘, opens the in-app Settings page (replacing the default Settings-window
            // menu item) so there is a single Settings UI, no separate window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") { model.route = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // ⌘K opens the Spotlight-style command palette.
            CommandGroup(after: .toolbar) {
                Button("Command Palette") { model.showCommandPalette.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Refresh") { Task { await model.refreshAll() } }
                    .keyboardShortcut("r", modifiers: .command)
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
