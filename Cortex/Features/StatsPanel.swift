import SwiftUI

// MARK: - StatsPanel ("What's up next, <name>?")
//
// The usage-stats dashboard (reference Image #1): an 8-tile overview, the
// contribution heatmap, a Models tab, and an All / 30d / 7d window. Self-contained
// (owns its own window + tab state) so it can be dropped onto the Readout home.
// Built entirely from native GroupBox / Picker / LabeledContent.

struct StatsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var window: UsageStats.Window = .today
    // The active tab is owned by the host (Home) so it can hide the sections below the
    // panel on non-Overview tabs.
    @Binding var tab: Tab

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case models = "Models"
        case library = "Library"
        case stack = "Stack"
        var id: String { rawValue }
    }

    var body: some View {
        // Establish an explicit observation dependency on the session store so this
        // panel re-renders when the (async) transcript parse finishes. Without this,
        // the stats are reached only through a method call and the dependency is not
        // tracked, leaving the heatmap and tiles stuck on the pre-load empty result.
        let _ = model.sessions.lastScan
        let stats = model.sessions.stats(window: window)
        // The panel is NOT a card itself: it's a plain section. Wrapping it in a
        // GroupBox made SwiftUI render the nested cards (usage, stat tiles, heatmap,
        // tables) with the tight DEFAULT group-box style instead of the app's 20pt
        // CortexGroupBoxStyle, so their padding looked wrong. As a plain VStack, those
        // inner GroupBoxes inherit the app style and sit at the standard 20pt, lined
        // up with the standalone cards below.
        VStack(alignment: .leading, spacing: 20) {
            // Controls row: tabs (left) + data window (right). No greeting here -
            // the Home page already greets at the top ("Hey, <name>").
                HStack(alignment: .center, spacing: 12) {
                    GlassSegmentedControl(items: Tab.allCases, selection: $tab) { $0.rawValue }
                    // While the first transcript parse runs (~no data yet), show a
                    // quiet indicator so the empty tiles + gray heatmap read as
                    // "loading" rather than "nothing here".
                    if model.sessions.isLoading && model.sessions.lastScan == nil {
                        StatsLoadingChip()
                    }
                    Spacer(minLength: 12)
                    // The window only filters the usage-data tabs; Library and Stack
                    // are static (config counts / detected tech), so hide it there.
                    if tab == .overview || tab == .models {
                        GlassSegmentedControl(items: UsageStats.Window.allCases, selection: $window) { $0.rawValue }
                    }
                }

            switch tab {
            case .overview: StatsOverviewTab(stats: stats, window: window)
            case .models: StatsModelsTab(stats: stats)
            case .library: StatsLibraryTab()
            case .stack: StatsTechStackTab()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Loading chip
//
// A quiet "reading sessions" indicator shown in the panel header during the first
// (slow) transcript parse, so the empty stats do not look broken.

private struct StatsLoadingChip: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Reading sessions\u{2026}")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.hairFill, in: Capsule())
        .transition(.opacity)
    }
}

// MARK: - Overview tab (8 stat boxes + heatmap + token footnote)

private struct StatsOverviewTab: View {
    let stats: UsageStats
    let window: UsageStats.Window

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Live Claude usage limits (session + weekly), above the heatmap.
            UsageBar()
            StatsStatGrid(stats: stats, window: window)
            StatsHeatmapSection(cells: stats.heatmap)
        }
    }
}

private struct StatsStatGrid: View {
    @Environment(AppModel.self) private var model
    let stats: UsageStats
    let window: UsageStats.Window
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    // GitHub contributions (commits + PRs + issues + reviews) summed over the active
    // window, so the tile tracks the same Today / 7d / 30d / All filter as the other
    // stats. This is GitHub's contribution number, NOT raw commits - labeled
    // accordingly below. Mirrors SessionStore.stats(window:)'s cutoff logic.
    private var windowedContributions: Int {
        let byDay = model.repos.commitsByDay
        let cal = Calendar.current
        let cutoff: Date?
        switch window {
        case .all: cutoff = nil
        case .today: cutoff = cal.startOfDay(for: Date())
        default: cutoff = window.days.map { cal.date(byAdding: .day, value: -$0, to: Date()) ?? Date() }
        }
        return byDay.filter { cutoff == nil || $0.key >= cutoff! }.values.reduce(0, +)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            // Four headline KPIs (one row): the rest live in the Library/Models tabs.
            StatsStatBox(label: window == .today ? "Contributions Today" : "Contributions",
                         value: "\(windowedContributions)", dot: Theme.blue,
                         info: "Commits + PRs + issues + reviews, from your GitHub contribution graph. Not raw commits.")
            StatsStatBox(label: "Est. Cost", value: Fmt.money(stats.totalCost), dot: Theme.orange,
                         info: "Estimated locally from your Claude Code session transcripts (~/.claude). For each model, the input, output, and cache read/write token counts are multiplied by that model's published price per million tokens (Opus, Sonnet, and Haiku rates - override them in ~/.claude/readout-pricing.json) and summed.\n\nThis is the API-equivalent cost. On a Max or Pro subscription you aren't billed per token, so your actual bill may differ.")
            StatsStatBox(label: "Sessions", value: "\(stats.sessions)", dot: .secondary)
            StatsStatBox(label: "Total tokens", value: Fmt.compact(stats.totalTokens), dot: .secondary)
        }
    }
}

// MARK: - Library tab (the "Your AI stack" counts, reusing the StatsStatBox tile)
//
// Folded in from the old Home AI-stack card (renamed from "Stack"). Same tile
// component as the Overview grid, each tile a deep link to its library page.

private struct StatsLibraryTab: View {
    @Environment(AppModel.self) private var model
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    private var entries: [(label: String, count: Int, route: Route)] {
        let c = model.config
        return [
            ("Skills", c.skills.count, .skills),
            ("Agents", c.agents.count, .agents),
            ("Commands", c.commands.count, .commands),
            ("MCP Servers", c.mcpServers.count, .tools),
            ("Hooks", c.hooks.count, .hooks),
            ("Memory", c.memories.count, .memory),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(entries, id: \.label) { entry in
                    Button {
                        model.route = entry.route
                    } label: {
                        StatsStatBox(label: entry.label, value: "\(entry.count)", dot: .secondary)
                    }
                    .buttonStyle(.plain)
                    .linkCursor()
                    .help("Open \(entry.label)")
                }
            }

            // Ranked attribution: which skills / MCP tools / servers / plugins / subagents
            // you actually use (sits above the per-project repo table).
            SkillsToolsCard(attribution: model.sessions.attribution(window: .all))

            // Per-project breakdown: which library items each project carries.
            ProjectLibraryTable()
        }
    }
}

// MARK: - Per-project library table (Library tab)
//
// Searchable + sortable (Name / Last updated / Most used) via the shared
// LibraryFilterBar, and each row deep-links to that repo's detail page on Repos.

private struct ProjectLibraryTable: View {
    @Environment(AppModel.self) private var model
    @State private var sort: ProjectSort = .mostUsed
    // One multi-select facet per category: the picked item names to filter projects by.
    @State private var selSkills: Set<String> = []
    @State private var selAgents: Set<String> = []
    @State private var selCommands: Set<String> = []
    @State private var selMCP: Set<String> = []
    @State private var selMemory: Set<String> = []

    private static let columns: [InsightColumn] = [
        InsightColumn(title: "Project", width: nil, alignment: .leading),
        InsightColumn(title: "Skills", width: 56),
        InsightColumn(title: "Agents", width: 56),
        InsightColumn(title: "Commands", width: 72),
        InsightColumn(title: "MCP", width: 48),
        InsightColumn(title: "Memory", width: 60),
    ]

    var body: some View {
        let all = ProjectInsights.libraryRollups(config: model.config)
        let rows = sorted(all.filter(matches))
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("By project").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                }
                .font(.headline)

                // Category dropdowns on the left (wrapping), sort floated to the right.
                if !all.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        FlowLayout(spacing: 8) {
                            MultiSelectFilterButton(title: "Skills", options: opts(all, \.skillNames), selected: $selSkills)
                            MultiSelectFilterButton(title: "Agents", options: opts(all, \.agentNames), selected: $selAgents)
                            MultiSelectFilterButton(title: "Commands", options: opts(all, \.commandNames), selected: $selCommands)
                            MultiSelectFilterButton(title: "MCP", options: opts(all, \.mcpNames), selected: $selMCP)
                            MultiSelectFilterButton(title: "Memory", options: opts(all, \.memoryNames), selected: $selMemory)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        SortFilterButton(sort: $sort)
                    }
                }

                if all.isEmpty {
                    CortexEmptyState(icon: "folder", title: "No project config yet",
                                     message: "Projects with their own skills, agents, MCP servers, or memory will appear here.")
                } else if rows.isEmpty {
                    Text("No projects match the selected filters.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                } else {
                    InsightTable(columns: Self.columns, rows: rows, onRowTap: openRepo) { row, col in
                        switch col {
                        case 0: Text(row.projectName).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                        case 1: countCell(row.skills)
                        case 2: countCell(row.agents)
                        case 3: countCell(row.commands)
                        case 4: countCell(row.mcp)
                        default: countCell(row.memory)
                        }
                    }
                    .animation(.easeInOut(duration: 0.22), value: rows)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Distinct, sorted values for a category across all projects (the dropdown options).
    private func opts(_ rows: [ProjectLibraryRollup], _ key: KeyPath<ProjectLibraryRollup, [String]>) -> [String] {
        Set(rows.flatMap { $0[keyPath: key] }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // A project matches when, for every active facet, it has at least one selected item.
    private func matches(_ r: ProjectLibraryRollup) -> Bool {
        func ok(_ sel: Set<String>, _ names: [String]) -> Bool {
            sel.isEmpty || !sel.isDisjoint(with: Set(names))
        }
        return ok(selSkills, r.skillNames) && ok(selAgents, r.agentNames)
            && ok(selCommands, r.commandNames) && ok(selMCP, r.mcpNames) && ok(selMemory, r.memoryNames)
    }

    // Apply the chosen sort. Most used = richest config first (then name); Name = A-Z;
    // Last updated = newest config/memory edit first.
    private func sorted(_ rows: [ProjectLibraryRollup]) -> [ProjectLibraryRollup] {
        switch sort {
        case .mostUsed:
            return rows.sorted { ($0.total, $1.projectName.lowercased()) > ($1.total, $0.projectName.lowercased()) }
        case .name:
            return rows.sorted { $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending }
        case .lastUpdated:
            return rows.sorted { $0.lastUpdated > $1.lastUpdated }
        }
    }

    // Deep-link a row to its repo (matched by name) on the Repos page.
    private func openRepo(_ row: ProjectLibraryRollup) {
        if let repo = model.repos.repos.first(where: { $0.name == row.projectName }) {
            model.repoSelectionHint = repo.id
        }
        model.route = .repos
    }

    // Zero reads as a quiet dash so the populated counts stand out.
    @ViewBuilder
    private func countCell(_ n: Int) -> some View {
        Text(n == 0 ? "-" : "\(n)")
            .font(.cortexMono)
            .foregroundStyle(n == 0 ? Color.secondary.opacity(0.5) : .secondary)
    }
}

// MARK: - Stack tab (the REAL tech stack across the selected folders)
//
// Languages (by file-extension counts) and frameworks/libraries (parsed from the
// repos' manifests), detected by ConfigScanner across the configured scan roots.

private struct StatsTechStackTab: View {
    @Environment(AppModel.self) private var model
    private let langColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        let stack = model.config.techStack
        VStack(alignment: .leading, spacing: 20) {
            if stack.languages.isEmpty && stack.frameworks.isEmpty {
                CortexEmptyState(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: "No stack detected yet",
                    message: "Add scan-root folders in Settings; Cortex reads the languages and frameworks used across your repos."
                )
            }
                // Languages: a tile per detected language with its file count.
                if !stack.languages.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            Text("Languages").foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.secondary)
                        }
                        .font(.headline)
                        LazyVGrid(columns: langColumns, spacing: 12) {
                            ForEach(stack.languages) { lang in
                                GroupBox {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 7) {
                                            // Real language logo from thesvg, glyph fallback.
                                            BrandIcon(slug: BrandSlug.slug(lang.name),
                                                      fallbackSymbol: "chevron.left.forwardslash.chevron.right",
                                                      size: 16)
                                            Text(lang.name)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Text("\(lang.percent)%")
                                            .font(.title3.bold())
                                            .foregroundStyle(.primary)
                                        // Files plus how many of the scanned projects use this language.
                                        Text(filesLine(lang))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }

                // Frameworks / libraries: wrapping pills grouped by what they are.
                if !stack.frameworks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            Text("Frameworks & libraries").foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "shippingbox").foregroundStyle(.secondary)
                        }
                        .font(.headline)
                        FlowGrid(data: stack.frameworks, minWidth: 150, spacing: 8) { fw in
                            HStack(spacing: 7) {
                                // Real brand logo from thesvg, SF Symbol fallback.
                                BrandIcon(slug: BrandSlug.slug(fw.name), fallbackSymbol: fw.icon, size: 16)
                                Text(fw.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(fw.repoCount)")
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                                    .fill(Theme.cardRaised)
                            )
                        }
                    }
                }

            // Per-project breakdown: the languages + frameworks detected in each project.
            ProjectTechTable()
        }
    }

    // "1.1K files in 5 projects" - drops the project clause when none is known.
    private func filesLine(_ lang: LanguageUsage) -> String {
        let files = "\(Fmt.compact(lang.fileCount)) files"
        guard lang.projectCount > 0 else { return files }
        let noun = lang.projectCount == 1 ? "project" : "projects"
        return "\(files) in \(lang.projectCount) \(noun)"
    }
}

// MARK: - Per-project tech table (Stack tab)
//
// Re-walks each repo off the main actor (the global TechStack has no per-project
// split) and lists the languages + frameworks detected in each project.

private struct ProjectTechTable: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [ProjectTechRollup] = []
    @State private var scanning = true
    @State private var sort: ProjectSort = .name
    // Multi-select facets: the picked languages / frameworks to filter projects by.
    @State private var selLanguages: Set<String> = []
    @State private var selFrameworks: Set<String> = []

    private static let columns: [InsightColumn] = [
        InsightColumn(title: "Project", width: nil, alignment: .leading),
        InsightColumn(title: "Languages", width: 220, alignment: .leading),
        InsightColumn(title: "Frameworks", width: 200, alignment: .leading),
    ]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("By project").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                }
                .font(.headline)

                // Language + framework dropdowns on the left, sort floated right.
                if !scanning && !rows.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        FlowLayout(spacing: 8) {
                            MultiSelectFilterButton(title: "Languages", options: opts(\.languages), selected: $selLanguages)
                            MultiSelectFilterButton(title: "Frameworks", options: opts(\.frameworks), selected: $selFrameworks)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        SortFilterButton(sort: $sort)
                    }
                }

                if scanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Scanning projects\u{2026}").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                } else if rows.isEmpty {
                    CortexEmptyState(icon: "folder", title: "No project tech detected",
                                     message: "Languages and frameworks per project appear here once your repos are scanned.")
                } else {
                    let shown = sorted(rows.filter(matches))
                    if shown.isEmpty {
                        Text("No projects match the selected filters.")
                            .font(.caption).foregroundStyle(.tertiary).padding(.vertical, 8)
                    } else {
                        InsightTable(columns: Self.columns, rows: shown, onRowTap: openRepo) { row, col in
                            switch col {
                            case 0: Text(row.projectName).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                            case 1: InsightListCell(items: row.languages, maxShown: 3)
                            default: InsightListCell(items: row.frameworks, maxShown: 3)
                            }
                        }
                        .animation(.easeInOut(duration: 0.22), value: shown)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Re-derive when the set of discovered repos changes.
        .task(id: model.repos.repos.map(\.path)) {
            scanning = true
            rows = await ProjectInsights.techRollups(repos: model.repos.repos)
            scanning = false
        }
    }

    // Distinct, sorted values for a facet across all projects (the dropdown options).
    private func opts(_ key: KeyPath<ProjectTechRollup, [String]>) -> [String] {
        Set(rows.flatMap { $0[keyPath: key] }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // A project matches when, for every active facet, it has at least one selected value.
    private func matches(_ r: ProjectTechRollup) -> Bool {
        func ok(_ sel: Set<String>, _ values: [String]) -> Bool {
            sel.isEmpty || !sel.isDisjoint(with: Set(values))
        }
        return ok(selLanguages, r.languages) && ok(selFrameworks, r.frameworks)
    }

    // Apply the chosen sort. Most used = most languages + frameworks; Name = A-Z;
    // Last updated = newest repo commit first.
    private func sorted(_ rows: [ProjectTechRollup]) -> [ProjectTechRollup] {
        switch sort {
        case .mostUsed:
            return rows.sorted { ($0.languages.count + $0.frameworks.count) > ($1.languages.count + $1.frameworks.count) }
        case .name:
            return rows.sorted { $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending }
        case .lastUpdated:
            return rows.sorted { ($0.lastUpdated ?? .distantPast) > ($1.lastUpdated ?? .distantPast) }
        }
    }

    // Deep-link a row to its repo (its path == RepoInfo.id) on the Repos page.
    private func openRepo(_ row: ProjectTechRollup) {
        model.repoSelectionHint = row.projectPath
        model.route = .repos
    }
}

private struct StatsStatBox: View {
    let label: String
    let value: String
    var dot: Color? = nil
    // When set, a clickable info glyph appears beside the label and opens a popover
    // explaining how the value is produced (used by the Est. Cost tile).
    var info: String? = nil
    @State private var showInfo = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    if let info {
                        Spacer(minLength: 4)
                        Button { showInfo.toggle() } label: {
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .linkCursor()
                        .help("How this is calculated")
                        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                            Text(info)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .frame(width: 300, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(14)
                        }
                    }
                }
                Text(value)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StatsHeatmapSection: View {
    @Environment(AppModel.self) private var model
    let cells: [HeatCell]

    // Session + GitHub-contribution intensity, via the shared builder so the Work
    // Graph heatmap renders the identical grid.
    private var cellsWithCommits: [HeatCell] {
        HeatmapBuilder.combined(cells, with: model.repos.commitsByDay)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // Section header: outline glyph (grayscale) + primary title
                Label {
                    Text("Activity heatmap").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
                }
                .font(.headline)
                // The heatmap fills the card width itself (newest week flush-right),
                // so no horizontal scroll wrapper - that left a bare gap beside it.
                ContributionHeatmap(cells: cellsWithCommits)
                    .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Models tab (donut + per-model table)

private struct StatsModelsTab: View {
    let stats: UsageStats

    // Drop zero-token models (they clutter the legend and add invisible seams), then
    // assign each surviving slice a distinct color from the fixed donut palette by index
    // so no two adjacent slices share a color. The arc color IS the legend dot color.
    private var slices: [DonutSlice] {
        stats.costByModel
            .filter { $0.tokens > 0 }
            .enumerated()
            .map { idx, m in
                DonutSlice(label: m.display, value: Double(m.tokens), tint: DonutPalette.color(idx))
            }
    }

    // Model display name -> donut arc color, so the side table's dots match the donut.
    private var colorByModel: [String: Color] {
        Dictionary(slices.map { ($0.label, $0.tint) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        if stats.costByModel.isEmpty {
            CortexEmptyState(icon: "chart.pie", title: "No model usage yet",
                           message: "Once you run sessions in this window, model token share appears here.")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                // Equal-height cards so the donut card matches the taller table card; the
                // donut fills its card's height (centered) and reveals a legend on hover.
                HStack(alignment: .top, spacing: 14) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            // Section header: outline glyph (grayscale) + primary title
                            Label {
                                Text("Token share").foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "chart.pie").foregroundStyle(.secondary)
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            TokenShareDonut(slices: slices)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    // Same zero-token filter as the donut, so noise models like
                    // "<synthetic>" (0 tokens) don't show in the table either.
                    GroupBox { StatsModelTable(rows: stats.costByModel.filter { $0.tokens > 0 }, colorByModel: colorByModel) }
                        .frame(maxWidth: .infinity)
                }
                .groupBoxStyle(CortexGroupBoxStyle(fillHeight: true))

                // Per-project breakdown: which model(s) each project uses.
                ProjectModelsTable()
            }
        }
    }
}

// MARK: - Per-project models table (Models tab)

private struct ProjectModelsTable: View {
    @Environment(AppModel.self) private var model

    private static let columns: [InsightColumn] = [
        InsightColumn(title: "Project", width: nil, alignment: .leading),
        InsightColumn(title: "Model", width: 150, alignment: .leading),
        InsightColumn(title: "Sessions", width: 64),
        InsightColumn(title: "Tokens", width: 64),
        InsightColumn(title: "Cost", width: 64),
        InsightColumn(title: "Last", width: 56),
    ]

    var body: some View {
        let rows = ProjectInsights.sessionRollups(model.sessions.sessions)
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("By project").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                }
                .font(.headline)
                if rows.isEmpty {
                    CortexEmptyState(icon: "folder", title: "No projects yet",
                                     message: "Sessions grouped by project will appear here.")
                } else {
                    InsightTable(columns: Self.columns, rows: Array(rows.prefix(50))) { row, col in
                        modelCell(row, col)
                    }
                    if rows.count > 50 {
                        Text("Showing 50 of \(rows.count) projects")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func modelCell(_ row: ProjectSessionRollup, _ col: Int) -> some View {
        switch col {
        case 0:
            Text(row.projectName).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
        case 1:
            HStack(spacing: 5) {
                if let dominant = row.dominantModel {
                    Pill(text: dominant, tint: ProjectModelsTable.tint(dominant))
                }
                if !row.otherModels.isEmpty {
                    Text("+\(row.otherModels.count)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        case 2:
            Text("\(row.sessions)").font(.cortexMono).foregroundStyle(.secondary)
        case 3:
            Text(Fmt.compact(row.tokens)).font(.cortexMono).foregroundStyle(.secondary)
        case 4:
            Text(Fmt.money(row.cost)).font(.cortexMono).foregroundStyle(.secondary)
        default:
            Text(Fmt.relative(row.lastActive)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    static func tint(_ display: String) -> Color {
        let key = CostService.staticNormalizeKey(display)
        if key.hasPrefix("opus") { return Theme.yellow }
        if key.hasPrefix("sonnet") { return Theme.green }
        if key.hasPrefix("haiku") { return Theme.blue }
        return Theme.purple
    }
}

// MARK: - Token-share donut (fills its card, per-slice hover)
//
// Idle: a donut with the total token count in the hole. Hovering a specific arc
// highlights it (full opacity + grown outward, others dim) and swaps the center label
// for that slice's model name, share %, and token count. Moving off the donut restores
// the total. The donut arc color and that model's detail share one DonutSlice source.

private struct TokenShareDonut: View {
    let slices: [DonutSlice]
    @State private var selection: Int?

    private var total: Double { slices.reduce(0) { $0 + $1.value } }

    var body: some View {
        DonutChart(slices: slices, size: 150, selection: $selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { centerLabel }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.12), value: selection)
    }

    // Center of the donut hole: the hovered slice's detail, else the running total.
    @ViewBuilder
    private var centerLabel: some View {
        if let i = selection, slices.indices.contains(i) {
            let slice = slices[i]
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(slice.tint).frame(width: 7, height: 7)
                    Text(slice.label)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(.primary).lineLimit(1)
                }
                Text(total > 0 ? "\(Int((slice.value / total * 100).rounded()))%" : "0%")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                Text("\(Fmt.compact(Int(slice.value))) tokens")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: 130)
        } else {
            VStack(spacing: 1) {
                Text(Fmt.compact(Int(total)))
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                Text("tokens").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct StatsModelTable: View {
    let rows: [ModelCost]
    // Donut arc colors keyed by model display name, so the table dots match the donut.
    // Models absent from the donut (zero tokens) fall back to their own family tint.
    var colorByModel: [String: Color] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                Text("Tokens").frame(width: 72, alignment: .trailing)
                Text("Cost").frame(width: 72, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)

            ForEach(rows) { row in
                HStack {
                    HStack(spacing: 8) {
                        Circle().fill(colorByModel[row.display] ?? row.tint).frame(width: 8, height: 8)
                        Text(row.display).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Fmt.compact(row.tokens)).font(.cortexMono).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                    Text(Fmt.money(row.cost)).font(.cortexMono).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                }
                .padding(.vertical, 9)
                if row.id != rows.last?.id { Divider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
