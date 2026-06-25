import SwiftUI

// MARK: - UsageMiniRow
//
// One limit window rendered compactly: a label + status dot, a percent/reset caption,
// and a thin progress bar. Shared by the home Usage card (UsageBar) and the menu-bar
// panel so both read identically. The status dot + bar fill color come from UsageHeat;
// the percent caption (used vs left) and the reset caption (relative vs absolute clock)
// honor the menu-bar display preferences read from AppModel, so changing a preference
// updates every usage surface at once.

struct UsageMiniRow: View {
    @Environment(AppModel.self) private var model
    let metric: UsageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Label + status dot, with the reset / detail caption trailing.
            HStack(spacing: 7) {
                Text(metric.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Circle()
                    .fill(UsageHeat.color(metric.percent))
                    .frame(width: 7, height: 7)
                Spacer(minLength: 8)
                if let caption = rightCaption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // Track + fill (fill reflects consumption, so the bar grows as you use).
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairFill)
                    Capsule()
                        .fill(UsageHeat.color(metric.percent))
                        .frame(width: max(6, geo.size.width * CGFloat(metric.percent / 100)))
                }
            }
            .frame(height: 7)

            // Percent caption, phrased as used or remaining per the preference.
            Text(UsageDisplay.captionLabel(metric.percent, mode: model.menuBarUsageMode))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Right-hand caption: a dollar/extra detail when present, else the reset caption
    /// in the user's chosen style.
    private var rightCaption: String? {
        if let detail = metric.detail { return detail }
        if let resetsAt = metric.resetsAt {
            return UsageHeat.resetText(resetsAt,
                                       style: model.menuBarResetStyle,
                                       timeFormat: model.menuBarTimeFormat)
        }
        return nil
    }
}

// MARK: - UsageHistoryRows
//
// A small spend + token breakdown for Today / Last 7 Days / Last 30 Days, read from the
// local Claude Code session + cost data. Shared by the Usage page and the menu-bar
// panel. Format mirrors the reference: "$2.82 · 3.9M tokens" (compact money + tokens).

struct UsageHistoryRows: View {
    @Environment(AppModel.self) private var model

    private let windows: [(label: String, window: UsageStats.Window)] = [
        ("Today", .today), ("Last 7 Days", .days7), ("Last 30 Days", .days30),
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(windows, id: \.label) { entry in
                let totals = model.sessions.totals(window: entry.window)
                HStack(spacing: 8) {
                    Text(entry.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text("\(Fmt.moneyCompact(totals.cost)) \u{00B7} \(Fmt.compact(totals.tokens)) tokens")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
