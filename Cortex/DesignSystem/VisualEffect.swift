import SwiftUI
import AppKit

// MARK: - VisualEffectView
//
// A thin SwiftUI wrapper over NSVisualEffectView so views can adopt real macOS
// vibrancy / translucency (the blurred, see-through material the system uses for
// sidebars). Used to give the main sidebar its translucent look.

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .followsWindowActiveState

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = state
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.state = state
    }
}

// MARK: - WindowConfigurator
//
// Reaches the hosting NSWindow to (1) hide the title text, (2) make the title bar
// transparent so the sidebar material reaches the top, and (3) make the window
// non-opaque so the sidebar's behind-window vibrancy actually blurs what's behind the
// window (a real translucent sidebar, not a flat fill). Applied once via .background().

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguringView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ConfiguringView)?.applyConfig()
    }

    // A view that configures its hosting window the moment it is attached (the earlier
    // approach read `.window` before the view was in the hierarchy, so it was always nil
    // and nothing applied). Re-applies on every SwiftUI update to survive overrides.
    private final class ConfiguringView: NSView {
        // Full-screen notification tokens, registered once per window (applyConfig runs
        // on every SwiftUI update, so without this guard observers would stack up).
        private var fullScreenObservers: [NSObjectProtocol] = []
        private weak var observedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyConfig()
        }

        func applyConfig() {
            guard let window else { return }
            // Hide ONLY the title text (keep the standard titleBar window style, which
            // is the only one that doesn't mangle the sidebar into an inset panel). The
            // band height itself is the macOS unified title-bar minimum and cannot be
            // shrunk here (.hiddenTitleBar / .unifiedCompact break the sidebar). The
            // visible "Cortex" comes from the detail column's navigation title, so it is
            // also cleared with .navigationTitle("") in ContentView, not just here.
            window.titleVisibility = .hidden
            window.title = ""
            observeFullScreen(window)
            // Re-apply on every SwiftUI update while full screen: page navigation swaps
            // the band's toolbar items, and AppKit can recreate the background views
            // VISIBLE in the process (this also covers attaching while already full
            // screen, where the enter notification fired before this view existed).
            applyFullScreenChromeIfNeeded(window)
        }

        // Hides the full-screen toolbar chrome now AND on the next runloop tick: AppKit
        // may (re)build the titlebar views after the current update pass, so the second
        // pass catches views that did not exist yet on the first.
        private func applyFullScreenChromeIfNeeded(_ window: NSWindow) {
            guard window.styleMask.contains(.fullScreen) else { return }
            Self.setFullScreenToolbarChromeHidden(true)
            DispatchQueue.main.async {
                guard window.styleMask.contains(.fullScreen) else { return }
                Self.setFullScreenToolbarChromeHidden(true)
            }
        }

        // Keep the title-bar band transparent in FULL SCREEN too. Windowed, the band is
        // kept clear by SwiftUI's `.toolbarBackground(.hidden, for: .windowToolbar)` in
        // ContentView. In full screen, AppKit reparents the unified toolbar into its own
        // NSToolbarFullScreenWindow and paints it with an opaque scroll-pocket material
        // that the SwiftUI modifier (and `titlebarAppearsTransparent`) cannot reach, so
        // the band rendered solid over the canvas. Fix: while in full screen, hide that
        // window's NSTitlebarBackgroundView / NSTitlebarSeparatorView (the toolbar ITEMS
        // live in sibling views and stay visible); what shows through is the main
        // window's canvas, matching the windowed look. Restored symmetrically on exit so
        // the long-tuned windowed chrome keeps its stock configuration.
        private func observeFullScreen(_ window: NSWindow) {
            guard observedWindow !== window else { return }
            removeFullScreenObservers()
            observedWindow = window
            let center = NotificationCenter.default
            fullScreenObservers.append(center.addObserver(
                forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.applyFullScreenChromeIfNeeded(window)
            })
            fullScreenObservers.append(center.addObserver(
                forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main
            ) { _ in
                Self.setFullScreenToolbarChromeHidden(false)
            })
        }

        /// Hides (or restores) the titlebar background + separator chrome inside every
        /// NSToolbarFullScreenWindow. Matches by class NAME only - no private API calls -
        /// so a future macOS that renames these views degrades to a no-op (the band shows
        /// its stock background again) instead of crashing.
        private static func setFullScreenToolbarChromeHidden(_ hidden: Bool) {
            for host in NSApp.windows
            where String(describing: type(of: host)) == "NSToolbarFullScreenWindow" {
                guard let root = host.contentView else { continue }
                setTitlebarChromeHidden(hidden, in: root)
            }
        }

        private static func setTitlebarChromeHidden(_ hidden: Bool, in view: NSView) {
            let className = String(describing: type(of: view))
            if className == "NSTitlebarBackgroundView" || className == "NSTitlebarSeparatorView" {
                view.isHidden = hidden
                return
            }
            for subview in view.subviews {
                setTitlebarChromeHidden(hidden, in: subview)
            }
        }

        private func removeFullScreenObservers() {
            fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
            fullScreenObservers.removeAll()
        }

        deinit { removeFullScreenObservers() }
    }
}
