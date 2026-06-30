import SwiftUI

// MARK: - RepoPulseView
//
// The Workspace > Repo Pulse screen. A compact, at-a-glance health pulse for every
// local repository discovered by RepoService. Repos are ranked by today's activity
// (commits today, then uncommitted files) so the busiest working trees float to the
// top. Each repo is a small Card showing its name, branch, an inline Sparkline of
// [commitsToday, uncommittedFiles, behind, ahead], and colored status badges.
//
// All data is read live from model.repos.repos.

struct RepoPulseView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PageScaffold(
            title: "Repo Pulse",
            subtitle: "Per-repo health, ranked by today's activity"
        ) {
            // Live summary header across all repos.
            PulseSummary(repos: model.repos.repos)

            // The ranked grid of repo pulse cards (or empty / loading states).
            PulseGrid(repos: sortedRepos, isLoading: model.repos.isLoading)
        }
    }

    // MARK: Ranking
    //
    // Most active first: commits today descending, then uncommitted files descending,
    // then most recently touched.

    private var sortedRepos: [RepoInfo] {
        model.repos.repos.sorted { lhs, rhs in
            if lhs.commitsToday != rhs.commitsToday { return lhs.commitsToday > rhs.commitsToday }
            if lhs.uncommittedFiles != rhs.uncommittedFiles { return lhs.uncommittedFiles > rhs.uncommittedFiles }
            return (lhs.lastCommit ?? .distantPast) > (rhs.lastCommit ?? .distantPast)
        }
    }
}

// MARK: - Pulse summary
//
// Three big StatTiles aggregating the whole workspace: total repos, total commits
// pushed today, and the total number of dirty (uncommitted) files outstanding.

private struct PulseSummary: View {
    let repos: [RepoInfo]

    private var totalRepos: Int { repos.count }
    private var totalCommitsToday: Int { repos.reduce(0) { $0 + $1.commitsToday } }
    private var totalDirty: Int { repos.reduce(0) { $0 + $1.uncommittedFiles } }
    private var dirtyRepoCount: Int { repos.filter(\.isDirty).count }

    private var tiles: [EntityStat] {
        [
            EntityStat(label: "Repos", value: "\(totalRepos)", tint: Theme.blue),
            EntityStat(label: "Commits Today", value: "\(totalCommitsToday)", tint: Theme.green),
            EntityStat(label: "Uncommitted Files", value: "\(totalDirty)",
                       tint: totalDirty > 0 ? Theme.warn : Theme.textSecondary),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowGrid(data: tiles, minWidth: 150) { tile in
                StatTile(label: tile.label, value: tile.value, dot: tile.tint, big: true)
            }
            // A short prose pulse line under the tiles.
            if totalRepos > 0 {
                Text(summaryLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // A one-line honest summary of the current workspace state.
    private var summaryLine: String {
        if totalCommitsToday == 0 && totalDirty == 0 {
            return "All clean, nothing committed yet today across \(totalRepos) repos."
        }
        let commitClause = "\(totalCommitsToday) commit\(totalCommitsToday == 1 ? "" : "s") today"
        if totalDirty == 0 {
            return "\(commitClause), no uncommitted changes."
        }
        return "\(commitClause), \(totalDirty) uncommitted file\(totalDirty == 1 ? "" : "s") across \(dirtyRepoCount) repo\(dirtyRepoCount == 1 ? "" : "s")."
    }
}

// MARK: - Pulse grid
//
// A responsive grid of PulseCards, with inline empty + loading states that match the
// rest of the app.

private struct PulseGrid: View {
    let repos: [RepoInfo]
    let isLoading: Bool

    var body: some View {
        if repos.isEmpty {
            Card {
                if isLoading {
                    CortexEmptyState(
                        icon: "waveform.path",
                        title: "Reading repository pulse",
                        message: "Scanning your project roots and querying git status…"
                    )
                } else {
                    CortexEmptyState(
                        icon: "folder.badge.questionmark",
                        title: "No repositories",
                        message: "No git working trees were discovered under your project roots."
                    )
                }
            }
        } else {
            FlowGrid(data: repos, minWidth: 260, spacing: 12) { repo in
                PulseCard(repo: repo)
            }
        }
    }
}

// MARK: - Pulse card
//
// One compact repo health card: name + branch on top, a tiny inline Sparkline of the
// four live signals, then a wrapping row of colored status badges.

private struct PulseCard: View {
    let repo: RepoInfo

    // The four signals that make up this repo's pulse, in fixed order.
    private var pulseValues: [Double] {
        [Double(repo.commitsToday), Double(repo.uncommittedFiles),
         Double(repo.behind), Double(repo.ahead)]
    }

    // The card's leading tint: warm when dirty, green when freshly committed, blue otherwise.
    private var accent: Color {
        if repo.isDirty { return Theme.warn }
        if repo.commitsToday > 0 { return Theme.green }
        return Theme.blue
    }

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                // Title line: name + branch + dirty / GitHub markers.
                titleRow

                // Inline pulse Sparkline of the four signals.
                pulseChart

                // Wrapping colored status badges.
                PulseBadgeRow(repo: repo)
            }
        }
    }

    // MARK: Title row

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Pulse dot keyed to the repo's state.
            Circle().fill(accent).frame(width: 8, height: 8)

            Text(repo.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let branch = repo.currentBranch {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .semibold))
                    Text(branch).lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: Pulse chart
    //
    // A Sparkline when there is any signal to plot; otherwise a quiet "quiet" label so
    // an empty card never renders an empty chart frame.

    @ViewBuilder
    private var pulseChart: some View {
        if pulseValues.contains(where: { $0 > 0 }) {
            Sparkline(values: pulseValues, tint: accent, height: 30)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text("Quiet, in sync")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Theme.textTertiary)
            .frame(height: 30, alignment: .leading)
        }
    }
}

// MARK: - Pulse badge row
//
// The wrapping set of colored badges under a repo's Sparkline: commits today,
// uncommitted files, behind / ahead remote, and CLAUDE.md presence. Only non-zero
// signals render so a healthy repo stays uncluttered.

private struct PulseBadgeRow: View {
    let repo: RepoInfo

    var body: some View {
        HStack(spacing: 6) {
            if repo.commitsToday > 0 {
                badge(icon: "checkmark.seal.fill", text: "\(repo.commitsToday)", tint: Theme.green)
            }
            if repo.uncommittedFiles > 0 {
                badge(icon: "pencil.circle.fill", text: "\(repo.uncommittedFiles)", tint: Theme.warn)
            }
            if repo.behind > 0 {
                badge(icon: "arrow.down", text: "\(repo.behind)", tint: Theme.orange)
            }
            if repo.ahead > 0 {
                badge(icon: "arrow.up", text: "\(repo.ahead)", tint: Theme.blue)
            }
            if repo.hasClaudeMd {
                badge(icon: "doc.text.fill", text: "CLAUDE.md", tint: Theme.claude)
            }
            Spacer(minLength: 0)
        }
    }

    // A compact icon + value badge.
    private func badge(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
    }
}
