import SwiftUI

// MARK: - Session sort
//
// The sort order applied to the Sessions list pane. Unlike LibrarySort (name/modified/
// size) these are session-specific counts: recency, cost, total tokens, message count.
// Conforms to FilterSortOption so it reuses the shared glass sort pill (SortFilterButton)
// and the rawValue is what AppModel persists app-wide. Default is .recent (newest-first).

enum SessionSort: String, CaseIterable, Identifiable, FilterSortOption {
    case recent
    case cost
    case tokens
    case messages

    var id: String { rawValue }

    /// The menu display title for each order.
    var title: String {
        switch self {
        case .recent: "Recent"
        case .cost: "Cost"
        case .tokens: "Tokens"
        case .messages: "Messages"
        }
    }

    /// An SF Symbol matching each order (shown on the compact sort button + menu rows).
    var icon: String {
        switch self {
        case .recent: "clock"
        case .cost: "dollarsign.circle"
        case .tokens: "number"
        case .messages: "bubble.left.and.bubble.right"
        }
    }
}

// MARK: - SessionsView
//
// A native master/detail browser over every Claude Code session. The left pane is
// a searchable, newest-first, paginated session list; the right pane is the
// selected session's native detail (GroupBox / LabeledContent). The usage-stats
// dashboard ("What's up next") now lives on the Readout home, not here.

struct SessionsView: View {
    @Environment(AppModel.self) private var model

    @State private var query: String = ""
    // Scope filter (nil = all projects): a distinct projectName value.
    @State private var scope: String?
    @State private var visibleCount: Int = SessionsView.pageSize
    @State private var selectedID: ClaudeSession.ID?

    // Render this many rows at a time, growing by a page on demand.
    private static let pageSize = 20

    // Distinct project names for the scope popover, sorted A-Z. The scope pill only
    // appears once there's more than one project to pick from.
    private var scopes: [String] {
        Set(model.sessions.sessions.map(\.projectName))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // Two-way binding to the persisted session sort (on the model), passed into the
    // filter bar's sort button so changing it reorders the list and survives relaunch.
    private var sortBinding: Binding<SessionSort> {
        Binding(get: { model.sessionSort }, set: { model.sessionSort = $0 })
    }

    // Sessions filtered by the live query (project name / last prompt) AND the selected
    // scope (projectName == scope when set), then ordered by the chosen SessionSort.
    private var filtered: [ClaudeSession] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = model.sessions.sessions.filter { session in
            (scope == nil || session.projectName == scope)
                && (q.isEmpty
                    || session.projectName.lowercased().contains(q)
                    || (session.lastPrompt?.lowercased().contains(q) ?? false))
        }
        return sorted(matches, by: model.sessionSort)
    }

    // Apply the chosen sort order. Recent is endedAt-descending (the default newest-first
    // order); the rest are descending by their respective count so the "biggest" leads.
    private func sorted(_ sessions: [ClaudeSession], by sort: SessionSort) -> [ClaudeSession] {
        switch sort {
        case .recent: return sessions.sorted { $0.endedAt > $1.endedAt }
        case .cost: return sessions.sorted { $0.cost > $1.cost }
        case .tokens: return sessions.sorted { $0.usage.total > $1.usage.total }
        case .messages: return sessions.sorted { $0.messageCount > $1.messageCount }
        }
    }

    private var visible: [ClaudeSession] { Array(filtered.prefix(visibleCount)) }

    var body: some View {
        SplitDetailView(
            items: visible,
            selectedID: $selectedID,
            listWidth: 360,
            // No auto-select: the default detail is the aggregate dashboard; clicking a
            // session drills into it. The "Overview" button in the detail clears the
            // selection to return here.
            autoSelectFirst: false,
            emptyContent: { AnyView(SessionsDashboard()) }
        ) {
            SessionListHeader(
                matchCount: filtered.count,
                query: $query,
                scope: $scope,
                scopes: scopes,
                sort: sortBinding
            )
        } row: { session, _ in
            SessionRowContent(session: session)
                // Scroll loading: when the last loaded row scrolls into view, grow the
                // window by one page. Replaces the manual "Show more" button.
                .onAppear { loadMoreIfNeeded(at: session) }
        } detail: { session in
            SessionDetail(session: session, onBack: { selectedID = nil })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas)
        .onChange(of: query) { _, _ in visibleCount = Self.pageSize }
        // Reset the window when the scope changes so the new project's rows page fresh.
        .onChange(of: scope) { _, _ in
            visibleCount = Self.pageSize
            // When the scope filter hides the current selection, fall back to the first
            // remaining row (or nothing) so the detail pane never shows a stale item.
            if let id = selectedID, !filtered.contains(where: { $0.id == id }) {
                selectedID = filtered.first?.id
            }
        }
        // Apply any search / scope an assistant CTA deep-linked here with (e.g. "show
        // sessions in llm-cheatsheet"), consumed once so it doesn't re-fire on return.
        .onAppear {
            let pending = model.consumePending(for: .sessions)
            if let s = pending.search { query = s }
            if let sc = pending.scope {
                // Resolve tolerantly against real project names (case/slug mismatch from
                // the assistant shouldn't silently filter to zero rows).
                scope = scopes.first { $0.localizedCaseInsensitiveCompare(sc) == .orderedSame }
                    ?? scopes.first { $0.localizedCaseInsensitiveContains(sc) }
                    ?? sc
            }
        }
    }

    // Grow the visible window when the bottom-most loaded session appears, until the
    // full filtered set is shown (infinite scroll).
    private func loadMoreIfNeeded(at session: ClaudeSession) {
        guard session.id == visible.last?.id, visibleCount < filtered.count else { return }
        visibleCount = min(visibleCount + Self.pageSize, filtered.count)
    }
}

// MARK: - Session list header
//
// The split's left-pane header: a title with the live match count over the shared
// LibraryFilterBar (search + a project scope pill + the glass sort button). Rows load
// as you scroll (see loadMoreIfNeeded), so there is no "Show more" control here.

private struct SessionListHeader: View {
    let matchCount: Int
    @Binding var query: String
    @Binding var scope: String?
    let scopes: [String]
    @Binding var sort: SessionSort

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Standard big title + a plain gray count (no leading glyph).
            HStack(spacing: 8) {
                Text("Sessions")
                    .font(.cortexTitle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 6)
                Text("\(matchCount)")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Search + project scope filter + sort (matches the library list panes).
            LibraryFilterBar(
                query: $query,
                placeholder: "Search project or prompt",
                scope: $scope,
                scopes: scopes,
                sort: $sort
            )
        }
    }
}

// MARK: - Session row content
//
// Plain content for a native-List row (no selection chrome): a leading asterisk
// glyph, the project name over the truncated last prompt, and a trailing column
// with the session cost and a relative end time.

private struct SessionRowContent: View {
    let session: ClaudeSession

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "asterisk")
                .font(.callout.bold())
                .foregroundStyle(Theme.claude)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.projectName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(session.lastPrompt ?? "No prompt recorded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.money(session.cost))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.yellow)
                    .lineLimit(1)
                Text(Fmt.relative(session.endedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Session detail
//
// The split's right pane: the selected session in native containers - a large
// title header, then GroupBox sections of LabeledContent rows (message split,
// token breakdown, summary), the models used, and the last prompt.

private struct SessionDetail: View {
    @Environment(AppModel.self) private var model
    let session: ClaudeSession
    let onBack: () -> Void
    @State private var mode: Mode = .summary

    enum Mode: String, CaseIterable, Identifiable, Hashable {
        case summary = "Summary"
        case replay = "Replay"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pinned header + Summary / Replay switch.
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(session: session, onBack: onBack)
                GlassSegmentedControl(items: Mode.allCases, selection: $mode) { $0.rawValue }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Divider().overlay(Theme.stroke)

            switch mode {
            case .replay:
                // Self-contained replay; embedded (no sheet header / close button).
                SessionReplayView(session: session, embedded: true)
            case .summary:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // On-device AI summary of what the session was about.
                        sessionSummaryCard

                        // Compact stat cards, stacked full-width so large token numbers
                        // never wrap (no per-row dividers, tight spacing).
                        GroupBox { messagesTable }
                        GroupBox { tokenTable }

                        // Context the last turn carried (honest token count, no %).
                        if session.lastContextTokens > 0 {
                            GroupBox { contextCard }
                        }

                        // Compact metadata table.
                        GroupBox { metaTable }

                        if !session.models.isEmpty {
                            ModelsCard(models: session.models)
                        }
                        if let prompt = session.lastPrompt, !prompt.isEmpty {
                            LastPromptCard(prompt: prompt)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Kick off the on-device summary for THIS session only (lazy, cached).
                .task(id: session.id) { model.summaries.ensureSessionSummary(for: session) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    private var durationText: String {
        let total = Int(session.duration)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    // MARK: Summary subviews

    // AI summary (Claude Haiku / Apple Intelligence per Settings). Shows the result, a
    // "Summarizing…" placeholder ONLY while a generation is actually in flight, or
    // nothing (when the backend is off/unavailable, or a generation finished empty).
    // Keying the spinner on the in-flight set rather than mere availability means a
    // failed/empty backend run stops spinning instead of hanging forever.
    @ViewBuilder
    private var sessionSummaryCard: some View {
        if let ai = model.summaries.sessionSummary(for: session) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    cardTitle("Summary", icon: "sparkles")
                    Text(ai)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        } else if model.summaries.isSummarizing(session) {
            GroupBox {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Summarizing session\u{2026}").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var messagesTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle("Messages", icon: "bubble.left.and.bubble.right")
            VStack(spacing: 5) {
                compactRow("Total", Fmt.grouped(session.messageCount))
                compactRow("User", Fmt.grouped(session.userMessageCount))
                compactRow("Assistant", Fmt.grouped(session.assistantMessageCount))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Context card: the honest absolute token count the last turn carried. No "% of
    // window" - Claude Code doesn't record whether the session ran the 200K or 1M window
    // (Opus ships in both), so a percentage can't be derived accurately.
    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle("Context (last turn)", icon: "gauge.with.dots.needle.33percent")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.grouped(session.lastContextTokens))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text("tokens")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Tokens the most recent turn sent (input + cache), read from the transcript. Not shown as a percent: the 200K vs 1M window size isn't recorded, and Opus runs as either.")
                .font(.cortexCaption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tokenTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle("Token usage", icon: "number")
            VStack(spacing: 5) {
                compactRow("Input", Fmt.grouped(session.usage.input))
                compactRow("Output", Fmt.grouped(session.usage.output))
                compactRow("Cache read", Fmt.grouped(session.usage.cacheRead))
                compactRow("Cache write", Fmt.grouped(session.usage.cacheWrite))
                compactRow("Total", Fmt.grouped(session.usage.total), valueColor: Theme.purple, bold: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metaTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle("Details", icon: "info.circle")
            VStack(spacing: 5) {
                compactRow("Cost", Fmt.money(session.cost), valueColor: Theme.yellow, bold: true)
                compactRow("Duration", durationText)
                compactRow("Started", session.startedAt.formatted(date: .abbreviated, time: .shortened))
                compactRow("Ended", session.endedAt.formatted(date: .abbreviated, time: .shortened))
                if let primary = session.primaryModel {
                    compactRow("Primary model", CostService.displayName(primary))
                }
                if let branch = session.gitBranch, !branch.isEmpty {
                    compactRow("Branch", branch, valueColor: Theme.green)
                }
                HStack {
                    Text("Path").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(session.projectPath)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // A compact card heading (smaller than the old .headline so cards stay tight).
    private func cardTitle(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    // One dense key/value line (no divider) for the compact tables.
    private func compactRow(_ label: String, _ value: String,
                            valueColor: Color = .primary, bold: Bool = false) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.callout.monospacedDigit())
                .fontWeight(bold ? .semibold : .regular)
                .foregroundStyle(valueColor)
        }
    }
}

// MARK: - Detail header

private struct DetailHeader: View {
    let session: ClaudeSession
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Back to the aggregate dashboard (clears the selection).
            Button(action: onBack) {
                Label("Overview", systemImage: "chevron.left")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Back to the sessions overview")

            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.projectName)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text("ended \(Fmt.relative(session.endedAt))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Models card

private struct ModelsCard: View {
    let models: [String]

    // Drop the "<synthetic>" pseudo-model (Claude Code's id for locally-generated
    // assistant turns) - it's not a real model, and we filter it everywhere else.
    private var realModels: [String] {
        models.filter { $0 != "<synthetic>" && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Models used", systemImage: "cpu")
                    .font(.headline).foregroundStyle(.primary)
                // Left-packed pills (a trailing Spacer keeps them flush-left and tidy
                // instead of spread across equal-width grid cells).
                HStack(spacing: 8) {
                    ForEach(realModels, id: \.self) { name in
                        Pill(text: CostService.displayName(name), tint: tint(for: name))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tint(for model: String) -> Color {
        let key = CostService.staticNormalizeKey(model)
        if key.hasPrefix("opus") { return Theme.yellow }
        if key.hasPrefix("sonnet") { return Theme.green }
        if key.hasPrefix("haiku") { return Theme.blue }
        return Theme.purple
    }
}

// MARK: - Last prompt card

private struct LastPromptCard: View {
    let prompt: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Last prompt", systemImage: "text.quote")
                    .font(.headline).foregroundStyle(.primary)
                Text(prompt)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
