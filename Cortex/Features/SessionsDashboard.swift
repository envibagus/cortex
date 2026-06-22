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
                    whenYouWorkCard(stats)
                    tiles(stats)
                    dailyActivityCard(stats)
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

    private func whenYouWorkCard(_ stats: UsageStats) -> some View {
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
                    HourlyBarChart(buckets: stats.hourly, height: 120)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tiles(_ stats: UsageStats) -> some View {
        HStack(spacing: 14) {
            StatTile(label: "Sessions", value: "\(stats.sessions)", dot: Theme.blue, big: true)
            StatTile(label: "Messages", value: Fmt.grouped(stats.messages), dot: Theme.green, big: true)
            StatTile(label: "Tokens", value: Fmt.compact(stats.totalTokens), dot: Theme.yellow, big: true)
        }
    }

    private func dailyActivityCard(_ stats: UsageStats) -> some View {
        let days = Array(stats.dailyActivity.suffix(90))
        return GroupBox {
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
                        days: days, tint: Theme.blue, height: 130,
                        metric: { Double($0.messages) },
                        hoverCaption: { "\(Fmt.grouped($0.messages)) msgs \u{00B7} \($0.date.formatted(date: .abbreviated, time: .omitted))" }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
