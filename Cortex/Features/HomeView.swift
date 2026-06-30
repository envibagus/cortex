import SwiftUI
import Charts

// MARK: - HomeView (the home dashboard)
//
// your at-a-glance control center, rebuilt with stock-native macOS containers.
// Top to bottom: a personal greeting + prose summary with tinted key numbers, a
// 4-up KPI row of native GroupBoxes, two rows of paired chart cards (each a
// GroupBox with a native header), and the live hygiene List that deep-links into
// the relevant feature view.

struct HomeView: View {
    @Environment(AppModel.self) private var model
    // Flips true once we've been loading for >4s, so a long first parse surfaces a
    // reassuring label centered in the viewport instead of reading as a frozen screen.
    @State private var slowLoad = false
    // The fun-fact line under the greeting. Rotated each time Home is opened (a page
    // switch), NOT on a plain refresh, and crossfaded via the `messageIndex` id. The
    // index is persisted so a different fact shows on each visit (and across launches).
    @State private var welcomeMessage = AttributedString("")
    @AppStorage("homeMessageIndex") private var messageIndex = 0
    // The Stats panel's active tab, owned here so the sections below the panel (AI Stack
    // + Workspace Health) only show on Overview - drilling into Models/Library/Stack
    // hides them so the page focuses on the selected tab.
    @State private var statsTab: StatsPanel.Tab = .overview

    // The greeting is a contextual, time-of-day phrase derived live, so it turns over
    // only as the time period (and day) changes - far less often than the message.
    private var greeting: String { WelcomeText.greeting(name: model.userName, date: Date()) }

    /// Advance to the next fun-fact, so a different one shows than the last visit.
    private func rerollMessage() {
        let pool = WelcomeText.messagePool(model: model)
        guard !pool.isEmpty else { return }
        messageIndex &+= 1
        welcomeMessage = pool[abs(messageIndex) % pool.count]
    }

    /// Rebuild the CURRENT fun-fact with the latest data WITHOUT advancing the index.
    /// Called when the repo / GitHub data lands, so a message computed before the scan
    /// finished (e.g. "0 repos, 0 contributions") is replaced with the real numbers
    /// instead of staying stale until the next visit.
    private func rebuildMessage() {
        let pool = WelcomeText.messagePool(model: model)
        guard !pool.isEmpty else { return }
        welcomeMessage = pool[abs(messageIndex) % pool.count]
    }

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
            .padding(.top, 0)
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
        // Rotate the fun-fact only when Home opens (a page switch), not on refresh.
        .onAppear { rerollMessage() }
        // Rebuild the current fun-fact (without rotating) as data lands, so the line
        // never sticks on pre-load zeros: local repos (repos.count), the GitHub
        // contribution calendar (commitsByDay), and the config scan (items) each arrive
        // asynchronously after first paint.
        .onChange(of: model.repos.repos.count) { _, _ in rebuildMessage() }
        .onChange(of: model.repos.commitsByDay.count) { _, _ in rebuildMessage() }
        .onChange(of: model.config.items.count) { _, _ in rebuildMessage() }
    }

    // The real Home dashboard, shown once the first data load is in.
    private var realContent: some View {
        // Observation dependency + the all-time stats that feed the activity charts.
        let _ = model.sessions.lastScan
        let stats = model.sessions.stats(window: .all)
        return VStack(alignment: .leading, spacing: 24) {
            // Greeting + its one-line fun-fact, kept tight together (small inner gap) so
            // the header reads as one block before the 24pt gap to the sections below.
            VStack(alignment: .leading, spacing: 6) {
                // Contextual greeting (leading) + refresh (trailing). Smaller than a hero
                // title; crossfades only when the time-of-day phrase turns over.
                HStack(alignment: .center) {
                    Text(greeting)
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                        .id(greeting)
                        .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                    Spacer()
                    GlassRefreshButton()
                }

                // One-line fun-fact about the workspace, rotated on each open with a crossfade.
                Text(welcomeMessage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(messageIndex)
                    .transition(.opacity.animation(.easeInOut(duration: 0.35)))
            }

            // Sessions active in the last 6 hours, as a single line of pills (hidden
            // entirely when nothing has been active recently).
            RecentlyActiveStrip()

            // Usage-stats dashboard: the KPI tiles and the AI-stack counts are folded
            // into this panel's Overview / Library / Stack tabs (no separate rows).
            StatsPanel(tab: $statsTab)

            // The sections below the panel show only on the Overview tab; drilling into
            // Models / Library / Stack hides them to keep the focus on that tab.
            if statsTab == .overview {
                // Activity charts (also on the Sessions overview), surfaced here above
                // the AI stack as one row: when you work + your day-by-day activity.
                HStack(alignment: .top, spacing: 16) {
                    WhenYouWorkCard(stats: stats)
                    DailyActivityCard(stats: stats)
                }

                // The AI-stack overview: four deep-linking cards (Skills / Agents /
                // Memory / Repos) over a counts footer (plugins / MCP servers / hooks).
                AIStackCards()

                // Hygiene deep-link list (compact summary; the full list lives on Health)
                HygieneCard()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Home skeleton
//
// First-load placeholder for the Home page, kept in lockstep with realContent's
// Overview layout so the crossfade to the real content is not jarring. Top to bottom:
// the greeting + one-line fun-fact, then the StatsPanel block (tab + window controls,
// the usage-limits bar, the 4 KPI tiles, the activity heatmap), the two paired activity
// charts (When You Work + Daily Activity), the AI Stack header + four cards + counts
// footer, and the Workspace Health header + combined score/issues card. Uses the same
// 24pt section spacing + outer padding as HomeView's realContent.

private struct HomeSkeleton: View {
    // Mirror the Overview tab's 4-column grids (KPI tiles + AI-stack cards).
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Greeting + one-line fun-fact, grouped tight like realContent's header.
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    SkeletonBlock(width: 220, height: 30, cornerRadius: 8)
                    Spacer()
                    SkeletonBlock(width: 34, height: 34, cornerRadius: 17)
                }
                SkeletonBlock(height: 13, cornerRadius: 5)
                SkeletonBlock(width: 280, height: 13, cornerRadius: 5)
            }

            // StatsPanel block: controls row, the usage-limits bar, the 4 KPI tiles, then
            // the activity heatmap (20pt internal spacing, matching StatsPanel).
            VStack(alignment: .leading, spacing: 20) {
                // Tab segmented control (left) + data-window segmented control (right).
                HStack(spacing: 12) {
                    SkeletonBlock(width: 300, height: 28, cornerRadius: 14)
                    Spacer(minLength: 12)
                    SkeletonBlock(width: 200, height: 28, cornerRadius: 14)
                }

                // Usage-limits bar (session + weekly): a card with two labelled bars.
                SkeletonCard {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(0..<2, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    SkeletonBlock(width: 90, height: 11, cornerRadius: 4)
                                    Spacer()
                                    SkeletonBlock(width: 60, height: 11, cornerRadius: 4)
                                }
                                SkeletonBlock(height: 8, cornerRadius: 4)
                            }
                        }
                    }
                }

                // Four headline KPI tiles in a 4-up grid (Commits / Cost / Sessions / Tokens).
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        SkeletonCard(padding: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                SkeletonBlock(width: 64, height: 11, cornerRadius: 4)
                                SkeletonBlock(width: 80, height: 20, cornerRadius: 6)
                            }
                        }
                    }
                }

                // Activity heatmap card: header over a tall grid-ish fill.
                SkeletonCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonBlock(width: 140, height: 14, cornerRadius: 5)
                        SkeletonBlock(height: 104, cornerRadius: 8)
                    }
                }
            }

            // Two activity charts side by side: When You Work + Daily Activity.
            HStack(alignment: .top, spacing: 16) {
                SkeletonCard { chartCardBody() }
                SkeletonCard { chartCardBody() }
            }

            // AI Stack: section header, four stack cards (4-up), then a counts footer.
            VStack(alignment: .leading, spacing: 10) {
                SkeletonBlock(width: 150, height: 16, cornerRadius: 5)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        SkeletonCard { stackCardBody() }
                    }
                }
                SkeletonBlock(width: 240, height: 12, cornerRadius: 4)
            }

            // Workspace Health: section header over the combined score + issues card.
            VStack(alignment: .leading, spacing: 10) {
                SkeletonBlock(width: 170, height: 16, cornerRadius: 5)
                SkeletonCard {
                    VStack(alignment: .leading, spacing: 14) {
                        // Compact score strip (Health · Security).
                        HStack(spacing: 12) {
                            SkeletonBlock(width: 130, height: 14, cornerRadius: 5)
                            SkeletonBlock(width: 130, height: 14, cornerRadius: 5)
                            Spacer(minLength: 8)
                        }
                        Divider()
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

    // A chart card body: a header line over a chart-shaped block.
    private func chartCardBody() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBlock(width: 120, height: 14, cornerRadius: 5)
            SkeletonBlock(height: 130, cornerRadius: 8)
        }
    }

    // An AI-stack card body: a title + chevron row over three item rows (glyph + label).
    private func stackCardBody() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SkeletonBlock(width: 54, height: 12, cornerRadius: 4)
                Spacer()
                SkeletonBlock(width: 10, height: 10, cornerRadius: 3)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 7) {
                        SkeletonBlock(width: 11, height: 11, cornerRadius: 3)
                        SkeletonBlock(height: 11, cornerRadius: 4)
                    }
                }
            }
        }
    }
}

// MARK: - Welcome content (contextual greeting + rotating fun-fact)
//
// The greeting is a time-of-day phrase, stable within a period on a given day (seeded
// by day-of-year + period) so it switches rarely. The message pool is built from live
// data and rotated by the view on each Home open; the repos summary is always present
// so the pool is never empty. Key numbers are inlined as bold, tinted runs.

private enum WelcomeText {
    /// A contextual greeting derived from the time of day, e.g. "Good morning, NV" or
    /// "The quiet hours, NV". Seeded by day-of-year + period so it stays put within a
    /// period and only varies as the clock (and day) turns over.
    static func greeting(name: String, date: Date) -> String {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let day = cal.ordinality(of: .day, in: .year, for: date) ?? 0
        let period: Int
        let phrases: [String]
        switch hour {
        case 5..<8:   period = 0; phrases = ["Early start", "Up with the sun", "Rise and shine"]
        case 8..<12:  period = 1; phrases = ["Good morning", "Morning", "Fresh start"]
        case 12..<14: period = 2; phrases = ["Midday check-in", "Good afternoon", "Lunch-hour look"]
        case 14..<18: period = 3; phrases = ["Good afternoon", "Afternoon", "Back at it"]
        case 18..<22: period = 4; phrases = ["Good evening", "Evening", "Winding down"]
        default:      period = 5; phrases = ["The quiet hours", "It's late-night", "Burning the midnight oil"]
        }
        let phrase = phrases[(day + period) % phrases.count]
        return "\(phrase), \(name)"
    }

    /// The fun-fact pool, built from live data. Always includes the repos summary so it
    /// is never empty. The view picks one by a rotating index.
    @MainActor
    static func messagePool(model: AppModel) -> [AttributedString] {
        let repos = model.repos
        let stats = model.stats
        let config = model.config
        var pool: [AttributedString] = [reposSummary(repos: repos)]

        // Stack breadth.
        if config.skills.count + config.agents.count > 0 {
            var s = AttributedString("Your stack carries ")
            s += key("\(config.skills.count)", tint: Theme.claude)
            s += AttributedString(" skills, ")
            s += key("\(config.agents.count)", tint: Theme.purple)
            s += AttributedString(" agents, and ")
            s += key("\(config.mcpServers.count)", tint: Theme.blue)
            s += AttributedString(" MCP servers.")
            pool.append(s)
        }

        // Sessions across active days.
        if stats.sessions > 0 {
            var s = AttributedString("You've logged ")
            s += key("\(stats.sessions)", tint: Theme.blue)
            s += AttributedString(" \(stats.sessions == 1 ? "session" : "sessions") across ")
            s += key("\(stats.activeDays)", tint: Theme.green)
            s += AttributedString(" active \(stats.activeDays == 1 ? "day" : "days").")
            pool.append(s)
        }

        // Spend, and the model doing the heavy lifting.
        if stats.totalCost > 0 {
            var s = AttributedString("You've run up ")
            s += key(Fmt.money(stats.totalCost), tint: Theme.orange)
            s += AttributedString(" in API-equivalent spend")
            if let fav = stats.favoriteModel {
                s += AttributedString(", mostly on ")
                s += key(fav, tint: Theme.green)
            }
            s += AttributedString(".")
            pool.append(s)
        }

        // Memory notes.
        if config.memories.count > 0 {
            var s = AttributedString("You keep ")
            s += key("\(config.memories.count)", tint: Theme.blue)
            s += AttributedString(" memory \(config.memories.count == 1 ? "note" : "notes") briefing Claude across projects.")
            pool.append(s)
        }

        // Contributions today (matches the GitHub profile graph + the stats tile).
        if repos.contributionsToday > 0 {
            var s = AttributedString("You've made ")
            s += key("\(repos.contributionsToday)", tint: Theme.green)
            s += AttributedString(" GitHub \(repos.contributionsToday == 1 ? "contribution" : "contributions") today. Keep it up.")
            pool.append(s)
        }

        return pool
    }

    /// The original repos one-liner, always valid so the pool is never empty.
    @MainActor
    private static func reposSummary(repos: RepoService) -> AttributedString {
        let count = repos.repos.count
        var out = AttributedString("You have ")
        out += key("\(count)", tint: Theme.blue)
        out += AttributedString(" \(count == 1 ? "repo" : "repos") set up, ")
        out += key("\(repos.reposWithSkills)", tint: Theme.claude)
        out += AttributedString(" with skills and ")
        out += key("\(repos.reposWithAgents)", tint: Theme.purple)
        out += AttributedString(" with agents. ")
        if let richest = repos.richestConfig?.name, !richest.isEmpty {
            out += key(richest, tint: Theme.green)
            out += AttributedString(" has the richest config. ")
        }
        out += AttributedString("You've made ")
        out += key("\(repos.contributionsToday)", tint: Theme.green)
        out += AttributedString(" GitHub \(repos.contributionsToday == 1 ? "contribution" : "contributions") today.")
        return out
    }

    /// A bold, tinted run for a single key value.
    private static func key(_ text: String, tint: Color) -> AttributedString {
        var run = AttributedString(text)
        run.font = .body.weight(.bold)
        run.foregroundColor = tint
        return run
    }
}

// MARK: - Recently Active strip (sessions active in the last 6 hours)
//
// A single line of pills, one per project with a Claude Code session whose last
// activity is within the past 6 hours (most recent first). Each pill deep-links to
// the Sessions page. Hidden entirely when nothing has been active recently. Cortex
// only sees Claude Code transcripts, so "active session" means a Claude session.

private struct RecentlyActiveStrip: View {
    @Environment(AppModel.self) private var model

    // One project active within the last 6h, with its most recent activity time.
    private struct RecentEntry: Identifiable {
        var id: String { project }
        let project: String
        let when: Date
    }

    // Most-recent session per project within the last 6h, newest first, capped to
    // keep the row to a single line. The remainder is summarized as "+N more".
    private var entries: [RecentEntry] {
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        var latest: [String: Date] = [:]
        for s in model.sessions.sessions where s.endedAt >= cutoff {
            if let existing = latest[s.projectName], existing >= s.endedAt { continue }
            latest[s.projectName] = s.endedAt
        }
        return latest.map { RecentEntry(project: $0.key, when: $0.value) }
            .sorted { $0.when > $1.when }
    }

    var body: some View {
        let all = entries
        if !all.isEmpty {
            let shown = Array(all.prefix(5))
            let overflow = all.count - shown.count
            VStack(alignment: .leading, spacing: 8) {
                Text("Recently Active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(shown) { entry in
                        RecentlyActivePill(project: entry.project)
                    }
                    if overflow > 0 {
                        Text("+\(overflow) more")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - One Recently Active pill (green dot + project + relative time)

private struct RecentlyActivePill: View {
    @Environment(AppModel.self) private var model
    let project: String
    @State private var hovering = false

    var body: some View {
        Button {
            model.route = .sessions
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Theme.green).frame(width: 7, height: 7)
                Text(project)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(hovering ? Color.secondary.opacity(0.16) : Theme.cardRaised,
                        in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .onHover { hovering = $0 }
        .help("Open Sessions")
    }
}

// MARK: - AI stack cards (Skills / Agents / Memory / Repos + counts footer)
//
// Four deep-linking cards summarizing the AI stack: each shows its top 3 items and
// a "+N more" line, the whole card a button into its library page. Below sits a
// footer of secondary counts (plugins / MCP servers / hooks) as tappable segments.

private struct AIStackCards: View {
    @Environment(AppModel.self) private var model
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        let config = model.config

        // Skills + agents: top 3 by name (A-Z), no trailing metric.
        let skills = config.skills
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(3).map { StackRow(name: $0.name, trailing: nil) }
        let agents = config.agents
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(3).map { StackRow(name: $0.name, trailing: nil) }
        // Memory: largest first, trailing compact byte size.
        let memory = config.memories
            .sorted { $0.sizeBytes > $1.sizeBytes }
            .prefix(3).map { StackRow(name: $0.name, trailing: Self.bytes($0.sizeBytes)) }
        // Repos: most skills first, trailing "N skills".
        let repos = model.repos.repos
            .sorted { $0.skillCount > $1.skillCount }
            .prefix(3).map { StackRow(name: $0.name, trailing: "\($0.skillCount) \($0.skillCount == 1 ? "skill" : "skills")") }

        VStack(alignment: .leading, spacing: 10) {
            // Section header: outline glyph (grayscale) + primary title
            Label {
                Text("Your AI Stack").foregroundStyle(.primary)
            } icon: {
                Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
            }
            .font(.headline)

            LazyVGrid(columns: columns, spacing: 12) {
                StackCard(title: "Skills", icon: "bolt.fill", iconTint: Theme.claude,
                          route: .skills, total: config.skills.count, rows: skills)
                StackCard(title: "Agents", icon: "person.fill", iconTint: Theme.purple,
                          route: .agents, total: config.agents.count, rows: agents)
                StackCard(title: "Memory", icon: "brain", iconTint: Theme.blue,
                          route: .memory, total: config.memories.count, rows: memory)
                StackCard(title: "Repos", icon: "circle.fill", iconTint: Theme.green,
                          route: .repos, total: model.repos.repos.count, rows: repos)
            }
            .groupBoxStyle(CortexGroupBoxStyle(fillHeight: true))

            // Secondary counts footer.
            StackCountsFooter()
        }
    }

    // "2.1 KB" / "640 B" - a small, local byte formatter for the memory trailing metric.
    private static func bytes(_ n: Int) -> String {
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        if n >= 1_024 { return String(format: "%.0f KB", Double(n) / 1_024) }
        return "\(n) B"
    }
}

// One row inside a stack card: an item name with an optional trailing metric.
private struct StackRow: Identifiable {
    let id = UUID()
    let name: String
    let trailing: String?
}

// MARK: - One AI-stack card (title + chevron, top-3 rows, "+N more")

private struct StackCard: View {
    @Environment(AppModel.self) private var model
    let title: String
    let icon: String
    let iconTint: Color
    let route: Route
    let total: Int
    let rows: [StackRow]
    @State private var hovering = false

    var body: some View {
        Button {
            model.route = route
        } label: {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    // Header: title + count, trailing chevron.
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }

                    if rows.isEmpty {
                        Text("None yet")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(rows) { row in
                                HStack(spacing: 7) {
                                    Image(systemName: icon)
                                        .font(.system(size: 9))
                                        .foregroundStyle(iconTint)
                                        .frame(width: 11)
                                    Text(row.name)
                                        .font(.caption)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer(minLength: 4)
                                    if let trailing = row.trailing {
                                        Text(trailing)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        if total > rows.count {
                            Text("+\(total - rows.count) more")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help("Open \(title)")
    }
}

// MARK: - AI-stack counts footer (plugins / MCP servers / hooks)
//
// Secondary, lower-signal counts that don't warrant their own card. Each segment is
// a tappable deep link into its library page.

private struct StackCountsFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let config = model.config
        HStack(spacing: 6) {
            Image(systemName: "gearshape.2")
                .font(.caption)
                .foregroundStyle(.tertiary)
            footerSegment(count: config.plugins.count, noun: "plugin", route: .plugins)
            Text("·").foregroundStyle(.tertiary)
            footerSegment(count: config.mcpServers.count, noun: "MCP server", route: .tools)
            Text("·").foregroundStyle(.tertiary)
            footerSegment(count: config.hooks.count, noun: "hook", route: .hooks)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func footerSegment(count: Int, noun: String, route: Route) -> some View {
        Button {
            model.route = route
        } label: {
            Text("\(count) \(count == 1 ? noun : noun + "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help("Open \(noun.capitalized)s")
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
        let scanner = model.hygieneScanner
        // Prefer the unified Hygiene scan (the same findings the Health > Hygiene tab
        // lists) so this count matches that page; fall back to the lightweight
        // HygieneEngine only for the brief window before the scan has run.
        let useScan = scanner.lastScan != nil
        let total = useScan ? scanner.totalCount : model.hygiene.issues.count
        let critical = useScan ? scanner.criticalCount
                               : model.hygiene.issues.filter { $0.severity == .critical }.count
        let warnings = useScan ? scanner.warningCount
                               : model.hygiene.issues.filter { $0.severity == .warning }.count
        // Top items, most severe first, for the inline preview (the full list is on Health).
        let scanTop = Array(scanner.sections.flatMap(\.findings)
            .sorted { $0.severity > $1.severity }.prefix(3))
        let engineTop = Array(model.hygiene.issues.sorted { $0.severity > $1.severity }.prefix(3))
        let shownCount = useScan ? scanTop.count : engineTop.count

        VStack(alignment: .leading, spacing: 10) {
            // Section header: outline glyph (grayscale) + primary title
            Label {
                Text("Workspace Health").foregroundStyle(.primary)
            } icon: {
                Image(systemName: "heart.text.square").foregroundStyle(.secondary)
            }
            .font(.headline)

            // One combined card (Health + Security scores are the same idea as hygiene, so
            // they live together here on the Home page only): the compact score strip on
            // top, then the live hygiene findings (or an all-clear line) below.
            VStack(spacing: 0) {
                CompactHealthCards()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                Divider()

                if total == 0 {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal")
                            .foregroundStyle(Theme.blue)
                            .frame(width: 18)
                        Text("No hygiene issues need attention.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                } else {
                    // Summary row
                    HStack(spacing: 10) {
                        Image(systemName: "list.bullet.rectangle")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text("\(total) hygiene \(total == 1 ? "issue" : "issues") need attention")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        HygieneCounts(critical: critical, warnings: warnings)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)

                    Divider()

                    // Home shows only the top few (most severe first); the full, actionable
                    // list lives on the Health page.
                    if useScan {
                        ForEach(Array(scanTop.enumerated()), id: \.element.id) { idx, finding in
                            HomeFindingRow(finding: finding)
                            if idx < scanTop.count - 1 { Divider() }
                        }
                    } else {
                        ForEach(Array(engineTop.enumerated()), id: \.element.id) { idx, issue in
                            HygieneRow(issue: issue)
                            if idx < engineTop.count - 1 { Divider() }
                        }
                    }
                    if total > shownCount {
                        Divider()
                        ViewAllHealthRow(remaining: total - shownCount)
                    }
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

// MARK: - Summary counts (critical / warning badges)

private struct HygieneCounts: View {
    let critical: Int
    let warnings: Int

    var body: some View {
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

// MARK: - One Home hygiene-finding row (read-only preview -> Health)
//
// A compact, read-only row for a HygieneScanner finding shown in the Home card. The
// actionable controls live on the Health > Hygiene tab, so tapping here just opens it.

private struct HomeFindingRow: View {
    @Environment(AppModel.self) private var model
    let finding: HygieneFinding

    var body: some View {
        Button {
            model.route = .health
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: finding.severity.icon)
                    .foregroundStyle(finding.severity.tint)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let detail = finding.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
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

// MARK: - "View all in Health" row
//
// Closes the compact Home hygiene list with a link to the full suggestions list on
// the Health page (which lists every issue with richer detail).

private struct ViewAllHealthRow: View {
    @Environment(AppModel.self) private var model
    let remaining: Int

    var body: some View {
        Button {
            model.route = .health
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("View all \(remaining) more in Health")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
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
