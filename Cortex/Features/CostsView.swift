import SwiftUI
import Charts

// MARK: - CostsView (the finance dashboard)
//
// A focused spend dashboard for your Claude Code usage, rebuilt with stock-native
// macOS containers. Top KPIs (native GroupBoxes) cover all-time and this-month
// spend; a window selector (All / 30d / 7d) drives every chart below it:
// cost-by-model bars, a daily spend bar chart, a cost-share donut, and a native
// Table per-model breakdown. When a monthly budget is set, a native ProgressView
// tracks this-month spend against it. All numbers read live from the model.

struct CostsView: View {
    @Environment(AppModel.self) private var model

    // Window selector for the charts below the KPI header.
    @State private var window: UsageStats.Window = .days30

    var body: some View {
        // Windowed stats power the charts; the KPI header uses fixed windows.
        let stats = model.sessions.stats(window: window)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Page title
                VStack(alignment: .leading, spacing: 3) {
                    Text("Costs")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.primary)
                    Text("What your Claude Code usage is costing you")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // All-time + this-month spend KPIs
                CostKPIRow()

                // Optional budget burn-down for the current month
                if let budget = model.monthlyBudget, budget > 0 {
                    BudgetCard(budget: budget)
                }

                // Cost by model (bars) + cost share (donut), symmetrical: equal-height
                // cards via the shared fill-height card style.
                HStack(alignment: .top, spacing: 14) {
                    CostByModelCard(stats: stats, window: window)
                    CostShareCard(stats: stats)
                }
                .groupBoxStyle(CortexGroupBoxStyle(fillHeight: true))

                // Daily spend over the selected window
                DailySpendCard(stats: stats, window: window)

                // Per-model cost + token breakdown table
                ModelBreakdownCard(stats: stats)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WindowPicker(window: $window)
            }
        }
    }
}

// MARK: - Window picker (All / 30d / 7d) as a Liquid Glass segmented control

private struct WindowPicker: View {
    @Binding var window: UsageStats.Window

    var body: some View {
        GlassSegmentedControl(items: UsageStats.Window.allCases, selection: $window) { $0.rawValue }
    }
}

// MARK: - KPI tile (native GroupBox: caption label over a big value + sublabel)

private struct KPITile: View {
    var label: String
    var value: String
    var dot: Color
    var sublabel: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                // Label row with status dot
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 7, height: 7)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Big value
                Text(value)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                // Sublabel
                Text(sublabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - KPI header (all-time + this-month estimates)
//
// All-time spend comes from the precomputed model.stats; the this-month estimate
// is the 30-day window. Both are fixed regardless of the chart window so they
// stay stable as a reference point.

private struct CostKPIRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let allTime = model.stats.totalCost
        let month = model.sessions.stats(window: .days30)
        let week = model.sessions.stats(window: .days7)

        HStack(spacing: 14) {
            KPITile(label: "All-Time Spend", value: Fmt.money(allTime),
                    dot: .secondary, sublabel: "\(model.stats.sessions) sessions")
            KPITile(label: "This Month (30d)", value: Fmt.money(month.totalCost),
                    dot: .secondary, sublabel: dailyAverage(month.totalCost, days: 30))
            KPITile(label: "This Week (7d)", value: Fmt.money(week.totalCost),
                    dot: .secondary, sublabel: dailyAverage(week.totalCost, days: 7))
            KPITile(label: "Total Tokens", value: Fmt.compact(model.stats.totalTokens),
                    dot: .secondary, sublabel: "all models")
        }
    }

    /// A "~$X.XX/day" sublabel from a windowed total.
    private func dailyAverage(_ total: Double, days: Int) -> String {
        "~\(Fmt.money(total / Double(days)))/day"
    }
}

// MARK: - Budget card (this-month spend vs monthly budget)
//
// Shows a native ProgressView colored by burn ratio: green under 70%, amber under
// 100%, red at/over budget. Reads the live 30-day spend against monthlyBudget.

private struct BudgetCard: View {
    @Environment(AppModel.self) private var model
    let budget: Double

    var body: some View {
        let spend = model.sessions.stats(window: .days30).totalCost
        let ratio = budget > 0 ? spend / budget : 0
        let clamped = max(0, min(1, ratio))
        let tint = budgetTint(ratio)
        let remaining = budget - spend

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Header with status badge
                HStack {
                    Label("Monthly Budget", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(Int((ratio * 100).rounded()))% used")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ratio >= 1 ? Color.white : tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ratio >= 1 ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)),
                                    in: Capsule())
                }

                // Spend vs budget figures
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Fmt.money(spend))
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .foregroundStyle(.primary)
                    Text("of \(Fmt.money(budget))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // Native progress track
                ProgressView(value: clamped)
                    .progressViewStyle(.linear)
                    .tint(tint)

                // Remaining / overage footnote
                Text(footnote(remaining: remaining))
                    .font(.caption)
                    .foregroundStyle(remaining < 0 ? HygieneIssue.Severity.critical.tint : Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Green under 70%, amber under 100%, red once at or over budget.
    private func budgetTint(_ ratio: Double) -> Color {
        switch ratio {
        case ..<0.7: return Theme.green
        case ..<1.0: return Theme.warn
        default: return HygieneIssue.Severity.critical.tint
        }
    }

    /// Remaining headroom, or how far over budget the month already is.
    private func footnote(remaining: Double) -> String {
        if remaining < 0 {
            return "\(Fmt.money(abs(remaining))) over budget this month."
        }
        return "\(Fmt.money(remaining)) remaining this month."
    }
}

// MARK: - Cost by Model card (LabeledContent spend rows)
//
// Mirrors the Readout's cost rows but is driven by the selected window. Bottom
// footer carries the window's total spend.

private struct CostByModelCard: View {
    let stats: UsageStats
    let window: UsageStats.Window

    var body: some View {
        // Drop zero-token noise models (e.g. "<synthetic>") so this list matches the
        // Home donut/table, which already filter `tokens > 0`.
        let models = stats.costByModel.filter { $0.tokens > 0 }
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Native header
                HStack {
                    Label("Cost by Model", systemImage: "dollarsign.circle")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(window.rawValue).font(.caption).foregroundStyle(.tertiary)
                }
                if models.isEmpty {
                    CortexEmptyState(icon: "dollarsign.circle", title: "No spend yet",
                                   message: "Model costs will appear here.")
                } else {
                    // Aligned rows mirroring StatsModelTable: fixed-width leading dot,
                    // flexible left-aligned name, right-aligned monospaced cost. Dividers
                    // between rows keep the column readable.
                    VStack(spacing: 0) {
                        ForEach(models) { m in
                            HStack {
                                HStack(spacing: 8) {
                                    Circle().fill(m.tint).frame(width: 8, height: 8)
                                    Text(m.display)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(Fmt.money(m.cost))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 84, alignment: .trailing)
                            }
                            .padding(.vertical, 7)
                            if m.id != models.last?.id { Divider() }
                        }
                    }
                    Divider()
                    // Total spend footer for the window
                    HStack {
                        Text("Total")
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Fmt.money(stats.totalCost))
                            .font(.callout.monospacedDigit().bold())
                            .foregroundStyle(.primary)
                            .frame(width: 84, alignment: .trailing)
                    }
                    .padding(.top, 7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Cost share card (donut by model + legend)
//
// A donut of spend share per model with a compact legend showing each model's
// share percentage of the window's total spend.

private struct CostShareCard: View {
    let stats: UsageStats
    // Mirrors the donut's hovered slice so the legend highlights + dims to match.
    @State private var hovered: Int?

    var body: some View {
        // Drop zero-token noise models (e.g. "<synthetic>") so the share matches the
        // Home donut/table; among those, only chart models that actually cost something.
        let models = stats.costByModel.filter { $0.tokens > 0 && $0.cost > 0 }
        let total = models.reduce(0) { $0 + $1.cost }
        // Distinct color PER SLICE (by index), so two same-family models (e.g. Opus 4.8
        // and Opus 4.7) don't both render yellow. The legend dots reuse the same colors.
        let slices = models.enumerated().map { idx, m in
            DonutSlice(label: m.display, value: m.cost, tint: DonutPalette.color(idx))
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Native header
                Label("Cost Share", systemImage: "chart.pie")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if slices.isEmpty || total <= 0 {
                    CortexEmptyState(icon: "chart.pie", title: "No spend yet",
                                   message: "Spend share appears once you run sessions.")
                } else {
                    HStack(alignment: .center, spacing: 16) {
                        // Donut with the total spend centered inside; hover mirrors up.
                        ZStack {
                            DonutChart(slices: slices, size: 132, selection: $hovered)
                            VStack(spacing: 1) {
                                Text(Fmt.money(total))
                                    .font(.system(.headline, design: .rounded).weight(.bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                Text("total")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        // Per-model share legend: hovered row stays lit, the rest dim.
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(models.enumerated()), id: \.element.id) { idx, m in
                                CostShareLegendRow(name: m.display, share: m.cost / total,
                                                   tint: DonutPalette.color(idx))
                                    .opacity(hovered == nil || hovered == idx ? 1 : 0.3)
                            }
                        }
                        .animation(.easeOut(duration: 0.12), value: hovered)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - One legend row (dot + model + share %) as LabeledContent

private struct CostShareLegendRow: View {
    let name: String
    let share: Double
    let tint: Color

    var body: some View {
        LabeledContent {
            Text("\(Int((share * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
        } label: {
            Label {
                Text(name).foregroundStyle(.secondary)
            } icon: {
                Circle().fill(tint).frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .padding(.horizontal, -8)
    }
}

// MARK: - Daily spend card (bar chart over the window)
//
// An ActivityBarChart keyed on each day's cost, tinted yellow. Trailing badge
// reports the busiest single-day spend in the window.

private struct DailySpendCard: View {
    let stats: UsageStats
    let window: UsageStats.Window

    var body: some View {
        let days = stats.dailyActivity
        let peak = days.map(\.cost).max() ?? 0

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Native header
                HStack {
                    Label("Daily Spend", systemImage: "calendar")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(window.rawValue).font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    if peak > 0 {
                        Text("peak \(Fmt.money(peak))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.yellow)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.yellow.opacity(0.14), in: Capsule())
                    }
                }
                if days.isEmpty || peak <= 0 {
                    CortexEmptyState(icon: "calendar", title: "No spend yet",
                                   message: "Daily costs will chart here as you work.")
                } else {
                    // Per-bar hover: highlights the focused day (dimming the rest) and
                    // floats a "$123.45 on 14 June" caption, reusing ActivityBarChart's
                    // opt-in hoverCaption. The peak pill above is unaffected.
                    ActivityBarChart(days: days, tint: Theme.yellow,
                                     height: 120, metric: { $0.cost },
                                     hoverCaption: { day in
                                         "\(Fmt.money(day.cost)) on \(day.date.formatted(.dateTime.day().month(.wide)))"
                                     })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Per-model breakdown card (native Table: model, tokens, share, cost)
//
// A native macOS Table with sortable-looking columns, plus a totals footer that
// totals the window using LabeledContent-style rows.

private struct ModelBreakdownCard: View {
    let stats: UsageStats

    var body: some View {
        // Drop zero-token noise models (e.g. "<synthetic>") so the breakdown matches the
        // Home donut/table and the Cost by Model list above.
        let models = stats.costByModel.filter { $0.tokens > 0 }
        let totalCost = models.reduce(0) { $0 + $1.cost }
        let totalTokens = models.reduce(0) { $0 + $1.tokens }

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Native header
                Label("Model Breakdown", systemImage: "tablecells")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if models.isEmpty {
                    CortexEmptyState(icon: "tablecells", title: "No spend yet",
                                   message: "Per-model spend will list here.")
                } else {
                    // Native Table of per-model rows
                    Table(models) {
                        TableColumn("Model") { m in
                            Label {
                                Text(m.display).foregroundStyle(.primary)
                            } icon: {
                                Circle().fill(m.tint).frame(width: 8, height: 8)
                            }
                        }
                        TableColumn("Tokens") { m in
                            Text(Fmt.compact(m.tokens))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        TableColumn("Share") { m in
                            Text("\(Int(((totalCost > 0 ? m.cost / totalCost : 0) * 100).rounded()))%")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        TableColumn("Cost") { m in
                            Text(Fmt.money(m.cost))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                    }
                    .frame(height: CGFloat(models.count) * 30 + 36)
                    .scrollDisabled(true)

                    Divider()

                    // Totals footer
                    HStack {
                        Text("Total").fontWeight(.bold).foregroundStyle(.primary)
                        Spacer()
                        Text(Fmt.compact(totalTokens))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(Fmt.money(totalCost))
                            .font(.callout.monospacedDigit().bold())
                            .foregroundStyle(Theme.yellow)
                            .frame(minWidth: 84, alignment: .trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
