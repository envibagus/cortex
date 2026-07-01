import SwiftUI

// MARK: - Menu-bar preference types
//
// The user-facing choices for the menu-bar item: how the icon renders, which limit it
// tracks, whether numbers read as used vs remaining, how reset times are written, and
// how often usage re-probes. All are stored on AppModel (Strategy C: a stored rawValue
// with a didSet that mirrors to UserDefaults) so changing one re-renders both the
// Settings UI and the menu bar. Labels mirror the segmented controls in Settings.

/// What the menu-bar item draws: the percentage as text, a progress ring, or stacked
/// Session/Weekly bars.
enum MenuBarIconMode: String, CaseIterable, Identifiable {
    case text, donut, bars, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .text: "Number"
        case .donut: "Ring"
        case .bars: "Bars"
        case .both: "Both"
        }
    }
}

/// Which limit window the menu bar shows by default (the panel always shows both).
enum UsageWindow: String, CaseIterable, Identifiable {
    case session, weekly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        }
    }
    /// The `UsageMetric.label` this window maps to in a probe result.
    var metricLabel: String { label }
}

/// Whether percentages read as the amount consumed ("42%") or the amount remaining
/// ("58% left"). "Glass half full or half empty."
enum UsageDisplayMode: String, CaseIterable, Identifiable {
    case used, left
    var id: String { rawValue }
    var label: String {
        switch self {
        case .used: "Used"
        case .left: "Left"
        }
    }
}

/// Whether a reset is written as a countdown ("Resets in 1h 44m") or a clock time
/// ("Resets today at 11:04").
enum ResetTimerStyle: String, CaseIterable, Identifiable {
    case relative, absolute
    var id: String { rawValue }
    var label: String {
        switch self {
        case .relative: "Relative"
        case .absolute: "Absolute"
        }
    }
}

/// Clock style for absolute reset times: follow the locale, or force 12 / 24 hour.
enum MenuBarTimeFormat: String, CaseIterable, Identifiable {
    case auto, twelveHour, twentyFourHour
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto"
        case .twelveHour: "12-hour"
        case .twentyFourHour: "24-hour"
        }
    }
}

/// How often the menu bar re-probes usage while the app is running.
enum MenuBarRefreshInterval: Int, CaseIterable, Identifiable {
    case m5 = 300, m10 = 600, m15 = 900
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .m5: "5 min"
        case .m10: "10 min"
        case .m15: "15 min"
        }
    }
}

// MARK: - Percent display helper

enum UsageDisplay {
    /// The percentage to SHOW for a metric given the used/left preference. The stored
    /// `metric.percent` is always the amount consumed; "Left" flips it to the remainder.
    static func shownPercent(_ percent: Double, mode: UsageDisplayMode) -> Double {
        mode == .left ? max(0, 100 - percent) : percent
    }

    /// A short menu-bar label like "42%" / "58%" for the chosen display mode.
    static func barLabel(_ percent: Double, mode: UsageDisplayMode) -> String {
        UsageHeat.percentLabel(shownPercent(percent, mode: mode))
    }

    /// A caption like "42% used" / "58% left" for the detail panel.
    static func captionLabel(_ percent: Double, mode: UsageDisplayMode) -> String {
        let shown = UsageHeat.percentLabel(shownPercent(percent, mode: mode))
        return mode == .left ? "\(shown) left" : "\(shown) used"
    }
}
