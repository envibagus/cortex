import SwiftUI
import Charts

// MARK: - Activity bar chart (thin vertical bars, e.g. 30d activity)

struct ActivityBarChart: View {
    var days: [DayActivity]
    var tint: Color = Theme.blue
    var height: CGFloat = 86
    var metric: (DayActivity) -> Double = { Double($0.messages) }
    // When set, hovering a bar floats a small caption with this text. Opt-in so the
    // chart's other call sites (Costs / WorkGraph / entity dashboards) are unchanged.
    var hoverCaption: ((DayActivity) -> String)? = nil
    @State private var hovered: DayActivity?

    var body: some View {
        Chart(days) { day in
            BarMark(
                x: .value("Day", day.date, unit: .day),
                y: .value("Activity", metric(day))
            )
            .foregroundStyle(barTint(day))
            .cornerRadius(1.5)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
        .chartOverlay { proxy in
            if hoverCaption != nil {
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                if let anchor = proxy.plotFrame {
                                    let originX = geo[anchor].origin.x
                                    let date: Date? = proxy.value(atX: point.x - originX)
                                    hovered = date.flatMap(nearest)
                                }
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
        }
        .overlay(alignment: .top) {
            if let hovered, let hoverCaption {
                ChartHoverLabel(text: hoverCaption(hovered))
            }
        }
    }

    // Dim the non-hovered bars so the focused day stands out.
    private func barTint(_ day: DayActivity) -> Color {
        guard hovered != nil else { return tint }
        return hovered?.id == day.id ? tint : tint.opacity(0.4)
    }

    private func nearest(_ date: Date) -> DayActivity? {
        days.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
}

// MARK: - Hourly "When You Work" chart (colored by time-of-day band)

struct HourlyBarChart: View {
    var buckets: [HourBucket]
    var height: CGFloat = 86
    @State private var hovered: HourBucket?

    var body: some View {
        Chart(buckets) { b in
            BarMark(
                x: .value("Hour", b.hour),
                y: .value("Weight", b.weight)
            )
            .foregroundStyle(barTint(b))
            .cornerRadius(2)
        }
        .chartXScale(domain: 0...23)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { value in
                AxisValueLabel {
                    if let h = value.as(Int.self) {
                        Text(shortHour(h)).font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .frame(height: height)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            if let anchor = proxy.plotFrame {
                                let originX = geo[anchor].origin.x
                                let hour: Int? = proxy.value(atX: point.x - originX)
                                hovered = hour.flatMap { h in
                                    buckets.min { abs($0.hour - h) < abs($1.hour - h) }
                                }
                            }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .overlay(alignment: .top) {
            if let hovered {
                ChartHoverLabel(text: "\(Fmt.grouped(hovered.messages)) msgs \u{00B7} \(Fmt.hourLabel(hovered.hour))")
            }
        }
    }

    private func barTint(_ b: HourBucket) -> Color {
        let base = Theme.hourColor(b.hour)
        guard hovered != nil else { return base }
        return hovered?.id == b.hour ? base : base.opacity(0.4)
    }

    private func shortHour(_ h: Int) -> String {
        switch h { case 0: "12a"; case 12: "12p"; case 6: "6a"; case 18: "6p"; default: "\(h)" }
    }
}

// MARK: - Chart hover label (floating, no layout shift)
//
// A small material capsule that floats over the top of a chart on hover. Used by the
// bar charts to surface the focused bar's value without reserving a caption row.

private struct ChartHoverLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 0.5))
            .padding(.top, 2)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

// MARK: - Horizontal bar chart (e.g. Cost by Model)

struct HBarRow: Identifiable {
    var id: String
    var label: String
    var value: Double
    var valueText: String
    var tint: Color
}

struct HorizontalBars: View {
    var rows: [HBarRow]
    private var maxValue: Double { max(rows.map(\.value).max() ?? 1, 0.0001) }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Text(row.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 78, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            // Track background (faint inset fill, adapts to scheme)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.hairFill)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(row.tint)
                                .frame(width: max(6, geo.size.width * (row.value / maxValue)))
                        }
                    }
                    .frame(height: 14)
                    Text(row.valueText)
                        .font(.cortexMono)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 64, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Heatmap builder (shared session + contribution intensity)
//
// Folds GitHub per-day contribution counts into the session cells, recomputing the
// GREEN intensity off the COMBINED value (sessions + contributions) so a day with
// contributions but no sessions still lights up, GitHub-style. The Home heatmap and
// the Work Graph heatmap BOTH route through this, so they show the exact same grid.
// Both sides key on start-of-day Dates (the heatmap builds cells via
// Calendar.startOfDay; RepoService buckets contributions the same way), so the lookup
// lines up without re-normalizing.

enum HeatmapBuilder {
    static func combined(_ cells: [HeatCell], with byDay: [Date: Int]) -> [HeatCell] {
        guard !byDay.isEmpty else { return cells }
        let combined = cells.map { $0.count + (byDay[$0.date] ?? 0) }
        let nonzero = combined.filter { $0 > 0 }.sorted()
        func q(_ p: Double) -> Int {
            nonzero.isEmpty ? 0 : nonzero[min(nonzero.count - 1, Int(Double(nonzero.count) * p))]
        }
        let t1 = q(0.25), t2 = q(0.5), t3 = q(0.8)
        return cells.map { cell in
            let commits = byDay[cell.date] ?? 0
            let value = cell.count + commits
            var c = cell
            c.commits = commits
            c.level = value == 0 ? 0 : (value <= t1 ? 1 : (value <= t2 ? 2 : (value <= t3 ? 3 : 4)))
            return c
        }
    }
}

// MARK: - Contribution heatmap (GitHub-style grid, Image #1)

struct ContributionHeatmap: View {
    var cells: [HeatCell]
    var cellSize: CGFloat = 13
    var gap: CGFloat = 3

    // Cell currently under the pointer, drives the caption + highlight stroke.
    @State private var hovered: HeatCell?

    /// Lay cells out into a fixed 7-row (weekday) x N-column (week) grid, GitHub
    /// style. Each column is one week, Sunday (row 0) to Saturday (row 6). The first
    /// week is padded at the TOP with `nil` slots for the weekdays before the range
    /// starts, and the last week padded at the BOTTOM, so every column has exactly 7
    /// rows and the same weekday lines up across every column. Without this padding
    /// partial weeks render top-aligned and the whole grid skews into jagged gaps.
    private var weeks: [[HeatCell?]] {
        guard !cells.isEmpty else { return [] }
        let cal = Calendar.current
        let sorted = cells.sorted { $0.date < $1.date }

        var weeks: [[HeatCell?]] = []
        // Lead the first column with empty slots up to the first date's weekday.
        let leading = cal.component(.weekday, from: sorted[0].date) - 1 // 0 == Sunday
        var current: [HeatCell?] = Array(repeating: nil, count: leading)

        for cell in sorted {
            current.append(cell)
            if current.count == 7 {
                weeks.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            current.append(contentsOf: Array(repeating: nil, count: 7 - current.count))
            weeks.append(current)
        }
        return weeks
    }

    var body: some View {
        let allWeeks = weeks
        return VStack(alignment: .leading, spacing: 8) {
            // Hover caption: reflects the cell under the pointer, else a non-breaking
            // space so the heatmap grid never shifts when nothing is hovered.
            Text(hoverCaption)
                .font(.cortexCaption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

            // Responsive 7-row grid that fills the card width: show as many of the
            // most-recent week columns as fit, with today's column pinned to the RIGHT
            // edge. This keeps the latest activity flush-right and leaves no bare card
            // showing beside the grid at any window size (the days before the user's
            // first activity are gray grid cells, not empty space). Each column draws
            // all 7 weekday slots (empty padding slots are transparent spacers) so
            // weekdays line up. Cells read their fill from the current data, so the
            // async parse repaints them when the parent re-renders.
            GeometryReader { geo in
                let fit = max(1, Int((geo.size.width + gap) / (cellSize + gap)))
                grid(Array(allWeeks.suffix(fit)))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: gridHeight)
        }
    }

    /// The week-column grid for the given (already weekday-aligned) weeks.
    private func grid(_ weeks: [[HeatCell?]]) -> some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: gap) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                        cellView(cell)
                    }
                }
            }
        }
    }

    /// Pixel height of the fixed 7-row grid (7 cells + 6 gaps).
    private var gridHeight: CGFloat { cellSize * 7 + gap * 6 }

    /// One grid slot: a colored tile for a real day, or a transparent spacer for the
    /// padding days that keep the weekday rows aligned.
    @ViewBuilder
    private func cellView(_ cell: HeatCell?) -> some View {
        if let cell {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.heatColor(cell.level))
                .frame(width: cellSize, height: cellSize)
                .overlay {
                    if hovered?.id == cell.id {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Theme.textPrimary, lineWidth: 1.5)
                    }
                }
                .help(Self.tooltip(for: cell, dateStyle: .abbreviated))
                .onHover { inside in
                    if inside {
                        hovered = cell
                    } else if hovered?.id == cell.id {
                        hovered = nil
                    }
                }
        } else {
            Color.clear.frame(width: cellSize, height: cellSize)
        }
    }

    /// Caption shown above the grid for the hovered day, or a non-breaking space.
    private var hoverCaption: String {
        guard let cell = hovered else { return "\u{00A0}" }
        return Self.tooltip(for: cell, dateStyle: .long)
    }

    /// Tooltip / caption text for one day: sessions plus (when nonzero) GitHub
    /// contributions, e.g. "13 sessions, 4 contributions on 15 June 2026". The
    /// contributions clause is omitted when the day has zero so quiet days stay
    /// readable. Both nouns pluralize to match the existing sessions wording.
    /// `dateStyle` lets the floating caption use the long date while the .help()
    /// tooltip uses the abbreviated one.
    static func tooltip(for cell: HeatCell, dateStyle: Date.FormatStyle.DateStyle) -> String {
        let date = cell.date.formatted(date: dateStyle, time: .omitted)
        let sessions = cell.count == 1 ? "1 session" : "\(cell.count) sessions"
        guard cell.commits > 0 else {
            return cell.count == 0 ? "No sessions on \(date)" : "\(sessions) on \(date)"
        }
        let contributions = cell.commits == 1 ? "1 contribution" : "\(cell.commits) contributions"
        let lead = cell.count == 0 ? "No sessions" : sessions
        return "\(lead), \(contributions) on \(date)"
    }
}

// MARK: - Sparkline (compact trend line for entity dashboards)

struct Sparkline: View {
    var values: [Double]
    var tint: Color = Theme.blue
    var height: CGFloat = 36

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { idx, v in
            LineMark(x: .value("i", idx), y: .value("v", v))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
            AreaMark(x: .value("i", idx), y: .value("v", v))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.linearGradient(
                    colors: [tint.opacity(0.25), tint.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom
                ))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
    }
}

// MARK: - Donut (categorical share, per-slice hover)
//
// One slice of a token-share donut. `tint` is the arc color and MUST be reused as the
// legend dot so the chart and its legend share a single source of truth.
struct DonutSlice: Identifiable, Equatable {
    var id: String { label }
    var label: String
    var value: Double
    var tint: Color
}

// A fixed, ordered palette for categorical donut slices. These are DIRECT Color values
// (not the orange/blue-remapped Theme tokens) so adjacent slices are always distinct -
// charts are explicitly exempt from the app's two-accent rule (see Theme.swift).
enum DonutPalette {
    static let colors: [Color] = [
        .orange, .blue, .green, .purple, .pink, .teal, .indigo, .yellow, .red, .cyan, .mint, .brown,
    ]
    /// The color for slice index `i`, cycling if there are more slices than colors.
    static func color(_ i: Int) -> Color { colors[i % colors.count] }
}

// A Canvas-drawn donut with precise per-slice hover. We draw the arcs ourselves (rather
// than Swift Charts' SectorMark) so the cursor angle can be hit-tested back to an exact
// slice: SectorMark's chartAngleSelection is awkward to map to a slice and can't enlarge
// a single arc. The hovered slice stays full opacity and grows slightly outward; the
// rest dim. The donut ALWAYS highlights on hover via its own internal `hovered` state, so
// every call site gets the effect for free; when an external `selection` binding is passed
// (e.g. TokenShareDonut) the hovered index is mirrored up so the caller can drive a center
// label / legend from the same hit-test.
struct DonutChart: View {
    var slices: [DonutSlice]
    var size: CGFloat = 120
    // Two-way: the hovered slice index (nil = idle). Bound so the enclosing card can show
    // that slice's detail in the donut hole without re-deriving the hit-test. Optional;
    // when absent the donut still highlights via its own internal state below.
    @Binding var selection: Int?
    // The donut's own hover state. This is the single source of truth for the highlight so
    // it works even when no external binding is supplied; `selection` just mirrors it up.
    @State private var hovered: Int?

    init(slices: [DonutSlice], size: CGFloat = 120, selection: Binding<Int?> = .constant(nil)) {
        self.slices = slices
        self.size = size
        self._selection = selection
    }

    private var total: Double { slices.reduce(0) { $0 + $1.value } }

    // Cumulative [start, end] angle (in radians, clockwise from 12 o'clock) per slice.
    private var ranges: [(start: Double, end: Double)] {
        guard total > 0 else { return [] }
        var acc = 0.0
        return slices.map { slice in
            let sweep = slice.value / total * (.pi * 2)
            let range = (start: acc, end: acc + sweep)
            acc += sweep
            return range
        }
    }

    var body: some View {
        Canvas { ctx, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outer = min(rect.width, rect.height) / 2
            let baseOuter = outer - 2          // leave room for the hovered slice to grow
            let inner = baseOuter * 0.62
            let gap = 0.018                    // angular inset between slices (radians)

            for (i, range) in ranges.enumerated() {
                let isHover = hovered == i
                let r = isHover ? outer : baseOuter
                // Draw clockwise from 12 o'clock: convert to the Canvas angle space
                // (0 rad = 3 o'clock, growing clockwise because y points down).
                let a0 = range.start - .pi / 2 + gap / 2
                let a1 = range.end - .pi / 2 - gap / 2
                guard a1 > a0 else { continue }

                var path = Path()
                path.addArc(center: center, radius: r,
                            startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
                path.addArc(center: center, radius: inner,
                            startAngle: .radians(a1), endAngle: .radians(a0), clockwise: true)
                path.closeSubpath()

                let opacity = (hovered == nil || isHover) ? 1.0 : 0.28
                ctx.fill(path, with: .color(slices[i].tint.opacity(opacity)))
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let idx = sliceIndex(at: point)
                // Drive both the internal highlight and (if bound) the caller's label.
                if hovered != idx {
                    hovered = idx
                    selection = idx
                }
            case .ended:
                hovered = nil
                selection = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    // Map a cursor point to the slice whose angular range contains it (nil if the cursor
    // is outside the donut ring or there is no data).
    private func sliceIndex(at point: CGPoint) -> Int? {
        guard total > 0 else { return nil }
        let center = CGPoint(x: size / 2, y: size / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let dist = (dx * dx + dy * dy).squareRoot()
        let outer = size / 2
        let inner = (outer - 2) * 0.62
        guard dist >= inner - 4, dist <= outer + 2 else { return nil }

        // atan2 angle, rotated so 0 = 12 o'clock and increasing clockwise, into [0, 2pi).
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += .pi * 2 }
        return ranges.firstIndex { angle >= $0.start && angle < $0.end }
    }
}
