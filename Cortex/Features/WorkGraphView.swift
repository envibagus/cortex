import SwiftUI
import Charts

// MARK: - WorkGraphView
//
// "A chart of everything inside the app." A single analytics-overview screen that
// visualizes the whole stack at once: daily message activity over all time, a
// GitHub-style contribution heatmap, sessions split by project, the busiest repos,
// token share by model, and a counts row spanning every config surface. Every
// series is read live from AppModel / the services. No mock data.
//
// Native rebuild: every analytic lives in its own native `GroupBox` with a
// `Label`/`Text(.headline)` header. The counts row is a grid of small GroupBoxes
// (LabeledContent-style key/value cells). Typography uses system text styles and
// semantic foreground styles throughout.

struct WorkGraphView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let stats = model.stats
        let hasAny = !stats.dailyActivity.isEmpty
            || !model.sessions.sessions.isEmpty
            || !model.repos.repos.isEmpty

        PageScaffold(
            title: "Work Graph",
            subtitle: "Everything in your stack, charted on one page.",
            toolbar: AnyView(GlassRefreshButton())
        ) {
            if !hasAny {
                CortexEmptyState(
                    icon: "chart.bar",
                    title: "No data yet",
                    message: "As you run sessions and set up repos, the graphs fill in here."
                )
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    // Counts across every config surface
                    CountsRow()

                    // Tall full-width all-time activity chart
                    AllTimeActivityCard()

                    // Year of contributions
                    HeatmapCard()

                    // Sessions by project + token share by model
                    HStack(alignment: .top, spacing: 14) {
                        SessionsByProjectCard()
                        TokensByModelCard()
                    }

                    // Busiest repos (commits today, then config richness)
                    BusiestReposCard()
                }
            }
        }
    }
}

// MARK: - Counts row
//
// A grid of small native GroupBoxes, one per config surface: repos, skills,
// agents, MCP servers, hooks, memory files, and listening ports. Each cell is a
// labeled count (color dot + caption label + large rounded number). All live.

private struct CountsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let config = model.config
        let counts: [CountTile] = [
            CountTile(label: "Repos", value: model.repos.repos.count, dot: .secondary),
            CountTile(label: "Skills", value: config.skills.count, dot: .secondary),
            CountTile(label: "Agents", value: config.agents.count, dot: .secondary),
            CountTile(label: "MCP", value: config.mcpServers.count, dot: .secondary),
            CountTile(label: "Hooks", value: config.hooks.count, dot: .secondary),
            CountTile(label: "Memory", value: config.memories.count, dot: .secondary),
            CountTile(label: "Ports", value: model.ports.ports.count, dot: .secondary),
        ]

        FlowGrid(data: counts, minWidth: 118) { tile in
            CountCell(tile: tile)
        }
    }
}

/// One count cell descriptor for the FlowGrid above.
private struct CountTile: Identifiable {
    let id = UUID()
    let label: String
    let value: Int
    let dot: Color
}

// MARK: - One count cell (native GroupBox key/value)

private struct CountCell: View {
    let tile: CountTile

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                // Tinted dot + label
                HStack(spacing: 6) {
                    Circle().fill(tile.dot).frame(width: 7, height: 7)
                    Text(tile.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(tile.value)")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - All-time activity card
//
// A tall vertical-bar chart of daily message volume across the whole history,
// inside a native GroupBox with a Label header.

private struct AllTimeActivityCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let days = model.stats.dailyActivity
        let totalMessages = days.reduce(0) { $0 + $1.messages }
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Native header row
                HStack {
                    Label("Daily Activity", systemImage: "chart.bar")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("all time")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if days.isEmpty {
                    CortexEmptyState(
                        icon: "chart.bar",
                        title: "No activity yet",
                        message: "Daily message volume will chart here."
                    )
                } else {
                    ActivityBarChart(
                        days: days,
                        tint: Theme.blue,
                        height: 180,
                        metric: { Double($0.messages) },
                        // Hovering a bar floats the day's message count + date.
                        hoverCaption: { day in
                            "\(Fmt.grouped(day.messages)) messages \u{00B7} \(day.date.formatted(date: .abbreviated, time: .omitted))"
                        }
                    )
                    // Footnote: total messages across the whole window
                    Text("\(Fmt.grouped(totalMessages)) messages across \(days.count) \(days.count == 1 ? "day" : "days")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Heatmap card
//
// The GitHub-style contribution grid, horizontally scrollable for narrow widths,
// inside a native GroupBox with a Label header.

private struct HeatmapCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Same session + GitHub-contribution grid as the Home heatmap (shared builder),
        // so a day lights up for sessions OR commits, with matching intensities.
        let cells = HeatmapBuilder.combined(model.stats.heatmap, with: model.repos.commitsByDay)
        let activeDays = cells.filter { $0.count > 0 || $0.commits > 0 }.count
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Native header row
                HStack {
                    // Same title as the Home heatmap (was "Contributions"), so the two
                    // pages read consistently.
                    Label("Activity heatmap", systemImage: "square.grid.3x3")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("Recent activity")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if cells.isEmpty {
                    CortexEmptyState(
                        icon: "square.grid.3x3",
                        title: "No history yet",
                        message: "Your activity calendar will appear here."
                    )
                } else {
                    ContributionHeatmap(cells: cells)
                        .padding(.vertical, 2)
                    HStack(spacing: 8) {
                        Text("\(activeDays) active \(activeDays == 1 ? "day" : "days")")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        HeatmapLegend()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Heatmap legend (Less -> More intensity ramp)

private struct HeatmapLegend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Less").font(.caption).foregroundStyle(.tertiary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.heatColor(level))
                    .frame(width: 10, height: 10)
            }
            Text("More").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Sessions by project card
//
// Groups every session by projectName, keeps the top 8 by session count, folds
// the remainder into "Other", and renders a donut plus a small legend table,
// inside a native GroupBox with a Label header.

private struct SessionsByProjectCard: View {
    @Environment(AppModel.self) private var model

    /// One project slice: name, session count, assigned palette color.
    private struct ProjectSlice: Identifiable {
        let id = UUID()
        let name: String
        let count: Int
        let tint: Color
    }

    /// Top-8 projects by session count, with the rest folded into "Other".
    private var slices: [ProjectSlice] {
        let grouped = Dictionary(grouping: model.sessions.sessions, by: \.projectName)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
        guard !grouped.isEmpty else { return [] }

        let top = grouped.prefix(8)
        var result: [ProjectSlice] = top.enumerated().map { idx, entry in
            ProjectSlice(name: entry.name, count: entry.count,
                         tint: Theme.palette[idx % Theme.palette.count])
        }
        let otherCount = grouped.dropFirst(8).reduce(0) { $0 + $1.count }
        if otherCount > 0 {
            result.append(ProjectSlice(name: "Other", count: otherCount,
                                       tint: Theme.textTertiary))
        }
        return result
    }

    // Mirrors the donut's hovered slice so the legend on the right can highlight the
    // matching row and dim the others (the donut already dims its own non-hovered arcs).
    @State private var hovered: Int?

    var body: some View {
        let slices = slices
        let totalSessions = slices.reduce(0) { $0 + $1.count }
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Native header row
                Label("Sessions by Project", systemImage: "folder")
                    .font(.headline)
                    .foregroundStyle(.primary)
                if slices.isEmpty {
                    CortexEmptyState(
                        icon: "folder",
                        title: "No sessions yet",
                        message: "Project breakdown will appear here."
                    )
                } else {
                    HStack(alignment: .center, spacing: 16) {
                        // Donut with a centered session total. The hover index is bound up
                        // so the legend can react to the hovered slice.
                        ZStack {
                            DonutChart(
                                slices: slices.map { DonutSlice(label: $0.name, value: Double($0.count), tint: $0.tint) },
                                selection: $hovered
                            )
                            VStack(spacing: 1) {
                                Text("\(totalSessions)")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.primary)
                                Text("sessions")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        // Legend table: the hovered slice's row stays full opacity, the
                        // rest dim, matching the donut highlight.
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(slices.enumerated()), id: \.element.id) { idx, slice in
                                ProjectLegendRow(name: slice.name, count: slice.count, tint: slice.tint)
                                    .opacity(hovered == nil || hovered == idx ? 1 : 0.3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeOut(duration: 0.12), value: hovered)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - One project legend row (color dot + name + count)

private struct ProjectLegendRow: View {
    let name: String
    let count: Int
    let tint: Color

    var body: some View {
        LabeledContent {
            Text("\(count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
        } label: {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

// MARK: - Tokens by model card
//
// Horizontal bars of token share by model, ranked by token volume, inside a
// native GroupBox with a Label header. Values come straight from
// stats.costByModel (which carries token totals + tints).

private struct TokensByModelCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Drop zero-token noise models (e.g. "<synthetic>") so this matches the Home
        // donut/table, which already filter `tokens > 0`.
        let models = model.stats.costByModel.filter { $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }
        let rows = models.map { m in
            HBarRow(id: m.modelKey, label: m.display, value: Double(m.tokens),
                    valueText: Fmt.compact(m.tokens), tint: m.tint)
        }
        let totalTokens = models.reduce(0) { $0 + $1.tokens }
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Native header row
                Label("Token Share by Model", systemImage: "cpu")
                    .font(.headline)
                    .foregroundStyle(.primary)
                if rows.isEmpty {
                    CortexEmptyState(
                        icon: "cpu",
                        title: "No tokens yet",
                        message: "Per-model usage will appear here."
                    )
                } else {
                    HorizontalBars(rows: rows)
                    // Total tokens footer
                    HStack {
                        Spacer()
                        Text("Total: \(Fmt.compact(totalTokens)) tokens")
                            .font(.callout.weight(.bold))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Busiest repos card
//
// Horizontal bars of the top repos, inside a native GroupBox with a Label header.
// Prefers commits-today as the metric; when no repo has commits today it falls
// back to config richness (skills + agents).

private struct BusiestReposCard: View {
    @Environment(AppModel.self) private var model

    /// True when at least one repo has commits today.
    private var hasCommitsToday: Bool {
        model.repos.repos.contains { $0.commitsToday > 0 }
    }

    var body: some View {
        let repos = model.repos.repos
        let byCommits = hasCommitsToday
        let ranked = repos
            .sorted { lhs, rhs in
                byCommits
                    ? lhs.commitsToday > rhs.commitsToday
                    : (lhs.skillCount + lhs.agentCount) > (rhs.skillCount + rhs.agentCount)
            }
            .prefix(8)

        let rows = ranked.map { repo -> HBarRow in
            if byCommits {
                return HBarRow(id: repo.path, label: repo.name, value: Double(repo.commitsToday),
                               valueText: "\(repo.commitsToday)", tint: Theme.green)
            } else {
                let configCount = repo.skillCount + repo.agentCount
                return HBarRow(id: repo.path, label: repo.name, value: Double(configCount),
                               valueText: "\(configCount)", tint: Theme.claude)
            }
        }
        // Only chart repos that actually contribute to the chosen metric.
        let nonZero = rows.filter { $0.value > 0 }

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Native header row
                HStack {
                    Label(byCommits ? "Busiest Repos Today" : "Richest Repo Config",
                          systemImage: "flame")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(byCommits ? "commits today" : "skills + agents")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if nonZero.isEmpty {
                    CortexEmptyState(
                        icon: "folder",
                        title: "Nothing to rank",
                        message: byCommits
                            ? "No commits today across your repos."
                            : "No skills or agents configured in your repos yet."
                    )
                } else {
                    HorizontalBars(rows: nonZero)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
