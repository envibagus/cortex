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
        }
    }
}
