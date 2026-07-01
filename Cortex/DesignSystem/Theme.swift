import SwiftUI
import AppKit

// MARK: - Dynamic color helper (kept for any explicit light/dark needs)

extension Color {
    /// A color that resolves per the view's effective appearance. Named `adaptive`
    /// (not an `init(light:dark:)`) to avoid colliding with MarkdownUI's same-named init.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua: return NSColor(dark)
            default: return NSColor(light)
            }
        })
    }
}

// MARK: - App appearance preference

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" }
    }
}

// MARK: - Theme
//
// Native-first tokens. Surfaces/text/strokes map to AppKit semantic colors and the
// data hues to system colors, so the whole app uses the standard macOS palette and
// adapts to light/dark automatically (matching a stock native app). Fonts map to the
// system text styles. Only the brand accent (coral) is custom.

enum Theme {
    // Brand / accent. The app uses ONLY orange + blue as UI accents (charts keep
    // their own multi-color palette), so the brand mark is orange, not coral.
    static let claude = Color.orange
    static let accent = Color.accentColor

    // Surfaces (native). canvas is the standard window background (NOT the darker
    // recessed under-page color, which read as a dim "overlay" next to the vibrant
    // sidebar); cards sit a touch above it via the system control background.
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let cardRaised = Color(nsColor: .controlBackgroundColor)
    static let stroke = Color(nsColor: .separatorColor)
    static let strokeStrong = Color(nsColor: .separatorColor)
    static let hairFill = Color.secondary.opacity(0.12)

    // Inline + block code colors (orange to fit the orange/blue palette, light/dark
    // aware). Defined here (this file does not import MarkdownUI) so Color(light:dark:)
    // stays unambiguous with MarkdownUI's own same-named initializer.
    static let codeText = Color.adaptive(light: Color(red: 0.78, green: 0.42, blue: 0.14),
                                          dark: Color(red: 0.96, green: 0.64, blue: 0.36))
    static let codeFill = Color.secondary.opacity(0.14)

    // Text (native semantic)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    // UI accent hues collapse to the app's only two accents: orange + blue. The UI
    // must never show a rainbow. Charts keep their own multi-color palette (`palette`,
    // `heatColor`, `hourColor`, and the per-model tints in SessionStore use DIRECT
    // Color values), so they are unaffected by this remap.
    static let blue = Color.blue
    static let orange = Color.orange
    static let green = Color.blue       // success / positive -> blue
    static let yellow = Color.orange    // highlight / caution -> orange
    static let purple = Color.blue      // -> blue
    static let warn = Color.orange

    // Radii & spacing
    static let radius: CGFloat = 10
    static let radiusSmall: CGFloat = 7
    static let cardPadding: CGFloat = 20

    // The ONE horizontal inset for page content, app-wide: every page's content (scroll
    // pages, split list + detail panes, headers) uses this so the left/right gutters line
    // up screen-to-screen, and the toolbar-band title lines up with it via
    // `titleLeadingInset`. `pageTopInset` is the gap below the title-bar band.
    static let pageHInset: CGFloat = 18
    static let pageTopInset: CGFloat = 16
    /// Leading pad for the toolbar-band page title, tuned so its text lines up with the
    /// page content's `pageHInset` left edge. The unified toolbar insets its leading
    /// content by ~9pt of its own (measured on screen), so this is `pageHInset - 9` to
    /// land the title text on the `pageHInset` edge.
    static let titleLeadingInset: CGFloat = pageHInset - 9
    /// Row insets for the custom split-pane lists (SplitDetailView, Collections). The
    /// native `.plain` List indents row content by ~8pt of its own (measured on screen),
    /// so this is `pageHInset - 8` to land the rounded selection highlight exactly on the
    /// `pageHInset` edge, flush with the filter bar's search field above it.
    static let splitListRowInset: CGFloat = pageHInset - 8

    /// Heatmap intensity ramp (level 0...4).
    static func heatColor(_ level: Int) -> Color {
        switch max(0, min(4, level)) {
        case 0: return Color.secondary.opacity(0.14)
        case 1: return Color.green.opacity(0.35)
        case 2: return Color.green.opacity(0.55)
        case 3: return Color.green.opacity(0.78)
        default: return Color.green
        }
    }

    /// Stable color for an hour-of-day bucket in the "When You Work" chart.
    static func hourColor(_ hour: Int) -> Color {
        switch hour {
        case 0..<6: return Color.secondary       // night
        case 6..<12: return Color.green          // morning
        case 12..<18: return Color.blue          // afternoon
        default: return Color.orange             // evening
        }
    }

    /// Palette cycled for arbitrary categorical series.
    static let palette: [Color] = [.blue, .green, .yellow, .orange, .purple, .teal]
}

// MARK: - Typography (system text styles)

extension Font {
    static let cortexTitle = Font.system(size: 24, weight: .bold)
    static let cortexHeadline = Font.headline
    static let cortexStatNumber = Font.system(size: 26, weight: .bold)
    static let cortexCaption = Font.caption
    static let cortexMono = Font.system(.callout, design: .monospaced)
}
