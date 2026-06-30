import SwiftUI

// MARK: - SessionsDashboard
//
// The aggregate overview shown in the Sessions detail pane when no session is
// selected (the default landing). A prose summary, the "When You Work" hour-of-day
// chart, three headline tiles (Sessions / Messages / Tokens), and the "Daily Activity"
// chart. This is the new home for the Activity + When-You-Work charts that used to sit
// on the home page; both charts surface their values on hover.

struct SessionsDashboard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Observation dependency: re-render when the async parse finishes.
        let _ = model.sessions.lastScan
        let stats = model.sessions.stats(window: .all)
        let projectCount = Set(model.sessions.sessions.map(\.projectPath)).count

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Sessions")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)

                if model.sessions.isLoading && model.sessions.lastScan == nil {
                    loadingState
                } else if stats.sessions == 0 {
                    CortexEmptyState(icon: "clock", title: "No sessions yet",
                                     message: "Run Claude Code and your sessions will appear here.")
                } else {
                    SessionsSummaryProse(sessions: stats.sessions, messages: stats.messages,
                                         primaryModel: stats.favoriteModel, projects: projectCount)
                    WhenYouWorkCard(stats: stats)
                    tiles(stats)
                    DailyActivityCard(stats: stats)
                    // Where sessions run + which skills / MCP tools / subagents drove them.
                    entryPointsCard
                    SkillsToolsCard(attribution: model.sessions.attribution(window: .all))
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Reading your sessions\u{2026}")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 60)
    }

    private func tiles(_ stats: UsageStats) -> some View {
        HStack(spacing: 14) {
            StatTile(label: "Sessions", value: "\(stats.sessions)", dot: Theme.blue, big: true)
            StatTile(label: "Messages", value: Fmt.grouped(stats.messages), dot: Theme.green, big: true)
            StatTile(label: "Tokens", value: Fmt.compact(stats.totalTokens), dot: Theme.yellow, big: true)
        }
    }

    // Sessions grouped by where they ran (cli / desktop / sdk), as labeled pills. Only
    // shown once at least one session recorded an entrypoint (older transcripts may not).
    @ViewBuilder
    private var entryPointsCard: some View {
        let counts = Dictionary(grouping: model.sessions.sessions.compactMap(\.entrypoint), by: { $0 })
            .map { (label: ClaudeSession.entrypointLabel($0.key), count: $0.value.count) }
            .sorted { $0.count > $1.count }
        if !counts.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        Text("Where You Run").foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                    }
                    .font(.headline)
                    // Wrapping pills: "Terminal (CLI) 320", etc. FlowLayout drops to a new
                    // row when the next pill would overflow, so they never crowd one line.
                    FlowLayout(spacing: 8) {
                        ForEach(counts, id: \.label) { item in
                            Pill(text: "\(item.label)  \(item.count)", tint: Theme.blue)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Reusable activity chart cards
//
// "When You Work" (hour-of-day) and "Daily Activity" (per-day) are shown on BOTH the
// Sessions overview and the Home page, so they live as standalone views fed a
// UsageStats. Both surface their values on hover via the underlying charts.

struct WhenYouWorkCard: View {
    @Environment(AppModel.self) private var model
    let stats: UsageStats

    var body: some View {
        // The whole card taps through to the Sessions page; the chart still shows its
        // per-bar caption on hover (a hover, not a tap, so the two do not conflict).
        Button { model.route = .sessions } label: {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        Text("When You Work").foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                    }
                    .font(.headline)
                    if stats.hourly.isEmpty {
                        CortexEmptyState(icon: "clock", title: "No data yet",
                                         message: "Your working hours will show here.")
                    } else {
                        // Matches DailyActivityCard's chart height so the two cards line up.
                        HourlyBarChart(buckets: stats.hourly, height: 96)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help("Open Sessions")
    }
}

struct DailyActivityCard: View {
    @Environment(AppModel.self) private var model
    let stats: UsageStats
    var maxDays: Int = 90

    var body: some View {
        let days = Array(stats.dailyActivity.suffix(maxDays))
        // Whole card taps through to Sessions; bars still surface their caption on hover.
        Button { model.route = .sessions } label: {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label {
                            Text("Daily Activity").foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "chart.bar").foregroundStyle(.secondary)
                        }
                        .font(.headline)
                        Spacer()
                        Text("\(days.count)d").font(.caption).foregroundStyle(.tertiary)
                    }
                    if days.isEmpty {
                        CortexEmptyState(icon: "chart.bar", title: "No activity yet",
                                         message: "Sessions will appear here as you work.")
                    } else {
                        ActivityBarChart(
                            days: days, tint: Theme.blue, height: 96,
                            metric: { Double($0.messages) },
                            hoverCaption: { "\(Fmt.grouped($0.messages)) msgs \u{00B7} \($0.date.formatted(date: .abbreviated, time: .omitted))" }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help("Open Sessions")
    }
}

// MARK: - Summary prose ("N sessions, M messages total. Primary model: X. Active across K projects.")

private struct SessionsSummaryProse: View {
    let sessions: Int
    let messages: Int
    let primaryModel: String?
    let projects: Int

    var body: some View {
        Text(prose)
            .font(.body)
            .foregroundStyle(.secondary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var prose: AttributedString {
        var out = key("\(sessions)", Theme.blue)
        out += AttributedString(" sessions, ")
        out += key(Fmt.grouped(messages), Theme.green)
        out += AttributedString(" messages total. ")
        if let model = primaryModel {
            out += AttributedString("Primary model: ")
            out += key(model, Theme.claude)
            out += AttributedString(". ")
        }
        out += AttributedString("Active across ")
        out += key("\(projects)", Theme.purple)
        out += AttributedString(" \(projects == 1 ? "project" : "projects").")
        return out
    }

    private func key(_ text: String, _ tint: Color) -> AttributedString {
        var run = AttributedString(text)
        run.font = .body.weight(.bold)
        run.foregroundColor = tint
        return run
    }
}

// MARK: - Skills & Tools card (ranked attribution by kind)
//
// A segmented control over the attribution kinds that actually have data (Skills /
// MCP Tools / MCP Servers / Plugins / Subagents), with the top entries of the selected
// kind as ranked proportional bars. This is the panel that turns Claude Code's
// per-message attribution into a "what tooling drove your work" view.

struct SkillsToolsCard: View {
    let attribution: [AttributionKind: [AttributionStat]]
    @State private var kind: AttributionKind = .skill

    // Only offer kinds that recorded at least one attributed message.
    private var availableKinds: [AttributionKind] {
        AttributionKind.allCases.filter { !(attribution[$0]?.isEmpty ?? true) }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Skills & Tools").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary)
                }
                .font(.headline)

                if availableKinds.isEmpty {
                    CortexEmptyState(icon: "wrench.and.screwdriver", title: "No tool usage yet",
                                     message: "Skills, MCP tools, plugins, and subagents you use will be ranked here.")
                } else {
                    GlassSegmentedControl(items: availableKinds, selection: $kind) { $0.title }

                    let resolved = availableKinds.contains(kind) ? kind : (availableKinds.first ?? .skill)
                    let stats = Array((attribution[resolved] ?? []).prefix(8))
                    let maxCount = stats.map(\.count).max() ?? 1
                    VStack(spacing: 8) {
                        ForEach(stats) { AttributionRow(stat: $0, maxCount: maxCount) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Fall back to the first available kind if the default has no data this load.
        .onAppear { if !availableKinds.contains(kind), let first = availableKinds.first { kind = first } }
    }
}

// MARK: - One ranked attribution row (name + count over a proportional bar)

private struct AttributionRow: View {
    let stat: AttributionStat
    let maxCount: Int
    // Drives the proportional bar to grow from 0 to its value when the row appears.
    @State private var filled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(stat.name)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Fmt.grouped(stat.count))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // Proportional bar: fraction of the most-used entry of this kind.
            GeometryReader { geo in
                Capsule()
                    .fill(stat.kind.tint.opacity(0.16))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(stat.kind.tint)
                            .frame(width: filled ? max(4, geo.size.width * CGFloat(stat.count) / CGFloat(max(maxCount, 1))) : 0)
                    }
            }
            .frame(height: 5)
        }
        .padding(.vertical, 2)
        .onAppear { withAnimation(.easeOut(duration: 0.6).delay(0.3)) { filled = true } }
    }
}
