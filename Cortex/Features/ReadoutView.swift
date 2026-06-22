import SwiftUI
import Charts

// MARK: - ReadoutView (Reference dashboard #2: the home)
//
// your at-a-glance control center, rebuilt with stock-native macOS containers.
// Top to bottom: a personal greeting + prose summary with tinted key numbers, a
// 4-up KPI row of native GroupBoxes, two rows of paired chart cards (each a
// GroupBox with a native header), and the live hygiene List that deep-links into
// the relevant feature view.

struct ReadoutView: View {
    @Environment(AppModel.self) private var model
    // Flips true once we've been loading for >4s, so a long first parse surfaces a
    // reassuring label centered in the viewport instead of reading as a frozen screen.
    @State private var slowLoad = false

    var body: some View {
        ScrollView {
            ZStack(alignment: .top) {
                // Until the first data load completes, show a skeleton shimmer that mirrors
                // the real Home blocks; once ready, crossfade to the real content. Gated on
                // model.isReady (set in bootstrap right after the first recomputeStats).
                if model.isReady {
                    realContent
                        .transition(.opacity)
                } else {
                    HomeSkeleton()
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.35), value: model.isReady)
        }
        .background(Theme.canvas)
        // Slow-load reassurance: a floating chip centered in the visible page (both
        // axes), shown only when the first load runs past 4s. Hidden the moment data is
        // ready. Sits on the ScrollView so it centers in the viewport, not in the
        // (taller) skeleton content.
        .overlay(alignment: .center) {
            if !model.isReady && slowLoad {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Reading your sessions\u{2026}")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.3), value: slowLoad)
        .task {
            try? await Task.sleep(for: .seconds(4))
            slowLoad = true
        }
    }

    // The real Home dashboard, shown once the first data load is in.
    private var realContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Greeting (leading) + refresh (trailing), on one row so the refresh
            // sits at the right edge, horizontally symmetric with the greeting.
            HStack(alignment: .center) {
                Text("Hey, \(model.userName)")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                Spacer()
                GlassRefreshButton()
            }

            // Prose summary of the workspace state
            SummaryProse()

            // Usage-stats dashboard: the KPI tiles and the AI-stack counts are now
            // folded into this panel's Overview and Stack tabs (no separate rows).
            StatsPanel()

            // Paired chart cards. The Activity + "When You Work" charts moved to
            // the Sessions page; the home keeps Cost-by-Model + Recent Sessions,
            // sized to equal height by the Grid.
            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    CostByModelCard().frame(maxWidth: .infinity, maxHeight: .infinity)
                    RecentSessionsCard().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .groupBoxStyle(CortexGroupBoxStyle(fillHeight: true))

            // Hygiene deep-link list
            HygieneCard()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Home skeleton
//
// First-load placeholder for the Home page. Lays out shimmering blocks that roughly
// match the real blocks' positions + sizes (greeting, prose summary, the segmented
// tab + window controls row, the 7-tile stat grid, the key-details strip, the activity
// heatmap, the paired Cost / Recent cards, and the hygiene card) so the crossfade to
// the real content is not jarring. Uses the same 24pt section spacing + outer padding
// as ReadoutView's realContent.

private struct HomeSkeleton: View {
    // Mirror the Overview tab's 4-column stat grid.
    private let statColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Greeting row: a wide title bar + the round refresh-button placeholder.
            HStack(alignment: .center) {
                SkeletonBlock(width: 220, height: 30, cornerRadius: 8)
                Spacer()
                SkeletonBlock(width: 34, height: 34, cornerRadius: 17)
            }

            // Prose summary: two stacked lines, the second shorter (matches the wrap).
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBlock(height: 13, cornerRadius: 5)
                SkeletonBlock(width: 260, height: 13, cornerRadius: 5)
            }

            // StatsPanel controls row: the 4-tab segmented control (left) + the data
            // window segmented control (right), as two pill placeholders.
            HStack(spacing: 12) {
                SkeletonBlock(width: 280, height: 28, cornerRadius: 14)
                Spacer(minLength: 12)
                SkeletonBlock(width: 150, height: 28, cornerRadius: 14)
            }

            // Stat-tile grid: 7 card placeholders in a 4-up grid (matches StatsStatGrid).
            LazyVGrid(columns: statColumns, spacing: 12) {
                ForEach(0..<7, id: \.self) { _ in
                    SkeletonCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(width: 64, height: 11, cornerRadius: 4)
                            SkeletonBlock(width: 80, height: 20, cornerRadius: 6)
                        }
                    }
                }
            }

            // Key-details strip: a single wide card with four mini-stat columns.
            SkeletonCard {
                HStack(spacing: 28) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(width: 60, height: 11, cornerRadius: 4)
                            SkeletonBlock(width: 48, height: 18, cornerRadius: 6)
                        }
                    }
                    Spacer(minLength: 12)
                }
            }

            // Activity heatmap card: a header bar over a tall grid-ish fill.
            SkeletonCard {
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonBlock(width: 140, height: 14, cornerRadius: 5)
                    SkeletonBlock(height: 110, cornerRadius: 8)
                }
            }

            // Paired cards: Cost by Model + Recent Sessions, side by side.
            HStack(alignment: .top, spacing: 14) {
                SkeletonCard { listCardBody(rows: 4) }
                SkeletonCard { listCardBody(rows: 4) }
            }

            // Hygiene card: a header bar (outside the card) over a rows-with-dividers card.
            VStack(alignment: .leading, spacing: 10) {
                SkeletonBlock(width: 150, height: 14, cornerRadius: 5)
                SkeletonCard {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(0..<3, id: \.self) { _ in
                            HStack(spacing: 10) {
                                SkeletonBlock(width: 18, height: 18, cornerRadius: 5)
                                VStack(alignment: .leading, spacing: 6) {
                                    SkeletonBlock(width: 200, height: 12, cornerRadius: 4)
                                    SkeletonBlock(width: 300, height: 10, cornerRadius: 4)
                                }
                                Spacer(minLength: 8)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // A card body shaped like the Cost / Recent list cards: a header line over a stack
    // of short rows (dot + label + trailing value).
    private func listCardBody(rows: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SkeletonBlock(width: 130, height: 14, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<rows, id: \.self) { _ in
                    HStack(spacing: 10) {
                        SkeletonBlock(width: 8, height: 8, cornerRadius: 4)
                        SkeletonBlock(width: 120, height: 12, cornerRadius: 4)
                        Spacer(minLength: 12)
                        SkeletonBlock(width: 44, height: 12, cornerRadius: 4)
                    }
                }
            }
        }
    }
}

// MARK: - Prose summary line
//
// Reads live RepoService aggregates and inlines the key numbers as tinted, bold
// runs. The richest-config clause is dropped gracefully when nothing qualifies.

private struct SummaryProse: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let repos = model.repos
        let count = repos.repos.count
        let withSkills = repos.reposWithSkills
        let withAgents = repos.reposWithAgents
        let commits = repos.commitsTodayGitHub

        Text(summary(count: count, withSkills: withSkills, withAgents: withAgents,
                     richest: repos.richestConfig?.name, commits: commits))
            .font(.body)
            .foregroundStyle(.secondary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Build an AttributedString so individual numbers can be bold + tinted.
    private func summary(count: Int, withSkills: Int, withAgents: Int,
                         richest: String?, commits: Int) -> AttributedString {
        var out = AttributedString("You have ")
        out += key("\(count)", tint: Theme.blue)
        out += AttributedString(" \(count == 1 ? "repo" : "repos") set up, ")
        out += key("\(withSkills)", tint: Theme.claude)
        out += AttributedString(" with skills and ")
        out += key("\(withAgents)", tint: Theme.purple)
        out += AttributedString(" with agents. ")

        if let richest, !richest.isEmpty {
            out += key(richest, tint: Theme.green)
            out += AttributedString(" has the richest config. ")
        }

        out += AttributedString("You've pushed ")
        out += key("\(commits)", tint: Theme.green)
        out += AttributedString(" \(commits == 1 ? "commit" : "commits") today.")
        return out
    }

    /// A bold, tinted run for a single key value.
    private func key(_ text: String, tint: Color) -> AttributedString {
        var run = AttributedString(text)
        run.font = .body.weight(.bold)
        run.foregroundColor = tint
        return run
    }
}

// MARK: - Cost by Model card (LabeledContent rows of spend per model)

private struct CostByModelCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let stats = model.stats
        let models = stats.costByModel
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                // Section header: outline glyph (grayscale) + primary title
                Label {
                    Text("Cost by Model").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "dollarsign.circle").foregroundStyle(.secondary)
                }
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                if models.isEmpty {
                    CortexEmptyState(icon: "dollarsign.circle", title: "No spend yet",
                                   message: "Model costs will appear here.")
                } else {
                    // Aligned columns: dot | model name | right-aligned cost.
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                        ForEach(models) { m in
                            GridRow {
                                Circle().fill(m.tint).frame(width: 8, height: 8)
                                Text(m.display).foregroundStyle(.primary).lineLimit(1)
                                Text(Fmt.money(m.cost))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        Divider().gridCellColumns(3)
                        GridRow {
                            Color.clear.frame(width: 8, height: 8)
                            Text("Total").fontWeight(.semibold)
                            Text(Fmt.money(stats.totalCost))
                                .font(.callout.monospacedDigit().bold())
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Recent Sessions card (4 most recent transcripts, native rows)

private struct RecentSessionsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recent = Array(model.sessions.sessions.prefix(4))
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                // Section header: outline glyph (grayscale) + primary title
                Label {
                    Text("Recent Sessions").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                }
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                if recent.isEmpty {
                    CortexEmptyState(icon: "bubble.left", title: "No sessions yet",
                                   message: "Start Claude Code to see sessions.")
                } else {
                    // Negative inset cancels each row's own horizontal padding so the
                    // row text lines up with the card header, while the hover wash
                    // still bleeds outward for breathing room.
                    VStack(spacing: 4) {
                        ForEach(recent) { session in
                            RecentSessionRow(session: session)
                        }
                    }
                    .padding(.horizontal, -8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - One recent-session row

private struct RecentSessionRow: View {
    @Environment(AppModel.self) private var model
    let session: ClaudeSession
    @State private var hovering = false

    var body: some View {
        Button {
            model.route = .sessions
        } label: {
            HStack(alignment: .top, spacing: 9) {
                // Claude asterisk glyph
                Image(systemName: "asterisk")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.claude)
                    .frame(width: 14, height: 16)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.lastPrompt ?? "session")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        Text(session.projectName)
                            .font(.caption)
                            .foregroundStyle(Theme.blue)
                            .lineLimit(1)
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                        Text(Fmt.relative(session.endedAt))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovering ? Color.secondary.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Hygiene card (deep-linking issue List)
//
// A native List of issue rows, one per live HygieneEngine issue. A summary row
// is prepended when there are issues; tapping any issue navigates to its route
// when set.

private struct HygieneCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let issues = model.hygiene.issues
        VStack(alignment: .leading, spacing: 10) {
            // Section header: outline glyph (grayscale) + primary title
            Label {
                Text("Workspace Health").foregroundStyle(.primary)
            } icon: {
                Image(systemName: "heart.text.square").foregroundStyle(.secondary)
            }
            .font(.headline)

            if issues.isEmpty {
                GroupBox {
                    CortexEmptyState(icon: "checkmark.seal", title: "All clear",
                                   message: "No hygiene issues need attention.")
                }
            } else {
                // A plain rows-with-dividers card. No List, so it never pads out with
                // empty filler rows; height fits exactly the issues present.
                VStack(spacing: 0) {
                    // Summary row
                    HStack(spacing: 10) {
                        Image(systemName: "list.bullet.rectangle")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text("\(issues.count) hygiene \(issues.count == 1 ? "issue" : "issues") need attention")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        HygieneCounts(issues: issues)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)

                    Divider()

                    ForEach(Array(issues.enumerated()), id: \.element.id) { idx, issue in
                        HygieneRow(issue: issue)
                        if idx < issues.count - 1 { Divider() }
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                )
            }
        }
    }
}

// MARK: - Summary counts (critical / warning badges)

private struct HygieneCounts: View {
    let issues: [HygieneIssue]

    var body: some View {
        let critical = issues.filter { $0.severity == .critical }.count
        let warnings = issues.filter { $0.severity == .warning }.count
        HStack(spacing: 6) {
            if critical > 0 {
                Text("\(critical) critical")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HygieneIssue.Severity.critical.tint)
            }
            if warnings > 0 {
                Text("\(warnings) warning")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HygieneIssue.Severity.warning.tint)
            }
        }
    }
}

// MARK: - One hygiene row (icon + title + secondary detail + trailing badge)

private struct HygieneRow: View {
    @Environment(AppModel.self) private var model
    let issue: HygieneIssue

    var body: some View {
        Button {
            // Tap navigates to the issue's route when present
            if let route = issue.route { model.route = route }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: issue.severity.icon)
                    .foregroundStyle(issue.severity.tint)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(issue.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                // Trailing badge
                if let badge = issue.badge {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(issue.badgeTint ?? .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background((issue.badgeTint ?? Color.secondary).opacity(0.14),
                                    in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 8)
        }
        .buttonStyle(.plain)
    }
}
