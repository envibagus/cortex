import SwiftUI

// MARK: - CommandPaletteView (⌘K)
//
// A Spotlight-style overlay that indexes the whole live stack and lets the user
// jump anywhere with the keyboard. Beyond Route.allCases it indexes repos, skills,
// agents, MCP servers, and ports, fuzzy-matches the query against their names and
// keywords, and groups the ranked results by category with leading icons.
//
// Selecting a Route sets `model.route` directly; selecting an entity navigates to
// the entity's parent route (.repos / .skills / .agents / .tools / .ports) and
// dismisses. Enter activates the first (highlighted) result, the up/down arrows
// move the selection, and Escape or a background tap dismisses the palette.

struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model

    // Query + focus + keyboard selection cursor.
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // Dimmed scrim: tapping anywhere off the panel dismisses.
            Color.adaptive(light: .black.opacity(0.25), dark: .black.opacity(0.45))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            palettePanel
                .padding(.top, 110)
        }
        .onExitCommand { dismiss() }
        .onAppear {
            // Defer focus until after the present transition: setting @FocusState
            // synchronously in onAppear is dropped before the field joins the
            // responder chain, so the input would open unfocused.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { focused = true }
        }
        // Reset the cursor whenever the result set changes shape.
        .onChange(of: query) { _, _ in selection = 0 }
    }

    // MARK: - Panel
    //
    // The floating search card: query field, hairline divider, then the grouped
    // result list. A flat array of matches drives both rendering and Enter/arrow
    // selection so the highlighted row and the activated row always agree.

    private var palettePanel: some View {
        let groups = groupedMatches
        let flat = groups.flatMap(\.matches)

        return VStack(spacing: 0) {
            queryField(resultCount: flat.count)
            Divider().overlay(Theme.stroke)

            if flat.isEmpty {
                emptyResults
            } else {
                resultList(groups: groups, flat: flat)
            }
        }
        .frame(width: 560)
        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1)
        )
        .shadow(color: Color.adaptive(light: .black.opacity(0.18), dark: .black.opacity(0.5)), radius: 36, y: 18)
    }

    // MARK: - Query field

    private func queryField(resultCount: Int) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            TextField("Jump to anything…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onSubmit { activateSelection() }
                .onKeyPress(.upArrow) { moveSelection(-1, in: resultCount); return .handled }
                .onKeyPress(.downArrow) { moveSelection(1, in: resultCount); return .handled }

            // Count chip while filtering, hotkey hint while idle.
            if query.isEmpty {
                Text("⌘K")
                    .font(.cortexCaption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if resultCount > 0 {
                Text("\(resultCount)")
                    .font(.cortexCaption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Result list

    private func resultList(groups: [PaletteGroup], flat: [PaletteMatch]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    ForEach(groups) { group in
                        // Category label.
                        Text(group.category.title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 4)

                        ForEach(group.matches) { match in
                            let index = flat.firstIndex(of: match) ?? 0
                            PaletteRow(match: match, selected: index == selection) {
                                activate(match)
                            }
                            .id(index)
                            .onHover { if $0 { selection = index } }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 420)
            // Keep the highlighted row in view as the keyboard cursor moves.
            .onChange(of: selection) { _, new in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    // MARK: - Empty state

    private var emptyResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
            Text("No matches for \u{201C}\(query)\u{201D}")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: - Index (real data only)
    //
    // Build the full searchable index from the live model on every render. Routes
    // come first, then repos / skills / agents / MCP / ports, each carrying the
    // tokens used for fuzzy matching and the destination route it navigates to.

    private var index: [PaletteMatch] {
        var out: [PaletteMatch] = []

        // Navigate: every sidebar destination.
        for route in Route.allCases {
            out.append(PaletteMatch(
                id: "route:\(route.rawValue)",
                category: .navigate,
                icon: route.icon,
                tint: Theme.textSecondary,
                title: route.title,
                subtitle: "Go to \(route.title)",
                keywords: "\(route.title) \(route.searchKeywords)",
                destination: route
            ))
        }

        // Repos.
        for repo in model.repos.repos {
            let branch = repo.currentBranch.map { " · \($0)" } ?? ""
            out.append(PaletteMatch(
                id: "repo:\(repo.path)",
                category: .repos,
                icon: repo.isGitHub ? "chevron.left.forwardslash.chevron.right" : "folder.fill",
                tint: Theme.blue,
                title: repo.name,
                subtitle: "Repo\(branch)",
                keywords: "\(repo.name) \(repo.currentBranch ?? "") git github repo project",
                destination: .repos
            ))
        }

        // Skills.
        for skill in model.config.skills {
            out.append(PaletteMatch(
                id: "skill:\(skill.id)",
                category: .skills,
                icon: ConfigKind.skill.icon,
                tint: Theme.yellow,
                title: skill.name,
                subtitle: skill.detail,
                keywords: "\(skill.name) \(skill.detail) skill",
                destination: .skills
            ))
        }

        // Agents.
        for agent in model.config.agents {
            out.append(PaletteMatch(
                id: "agent:\(agent.id)",
                category: .agents,
                icon: ConfigKind.agent.icon,
                tint: Theme.green,
                title: agent.name,
                subtitle: agent.detail,
                keywords: "\(agent.name) \(agent.detail) agent subagent",
                destination: .agents
            ))
        }

        // MCP servers (parent route is Tools).
        for server in model.config.mcpServers {
            out.append(PaletteMatch(
                id: "mcp:\(server.id)",
                category: .mcp,
                icon: ConfigKind.mcp.icon,
                tint: Theme.purple,
                title: server.name,
                subtitle: "\(server.transport.uppercased()) · \(server.scope)",
                keywords: "\(server.name) \(server.transport) mcp server tool integration",
                destination: .tools
            ))
        }

        // Ports.
        for port in model.ports.ports {
            let project = port.project.map { " · \($0)" } ?? ""
            out.append(PaletteMatch(
                id: "port:\(port.id)",
                category: .ports,
                icon: "point.3.connected.trianglepath.dotted",
                tint: Theme.orange,
                title: ":\(port.port)",
                subtitle: "\(port.processName)\(project)",
                keywords: "\(port.port) \(port.processName) \(port.command) \(port.project ?? "") port localhost server",
                destination: .ports
            ))
        }

        return out
    }

    // MARK: - Matching + grouping
    //
    // Fuzzy-rank the index against the query, then split the ranked results back
    // into category groups in a fixed display order. An empty query shows the full
    // index (Navigate first) so the palette doubles as a launcher.

    private var groupedMatches: [PaletteGroup] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let all = index

        let ranked: [PaletteMatch]
        if q.isEmpty {
            ranked = all
        } else {
            ranked = all
                .compactMap { match -> (PaletteMatch, Int)? in
                    let titleScore = FuzzyMatch.score(query: q, in: match.title)
                    // Keyword hits count, but discounted so titles win ties. Guard
                    // the discount: FuzzyMatch returns Int.min for "no match", and
                    // Int.min - 40 traps as an arithmetic overflow (it crashed the
                    // palette on nearly every keystroke), so only discount real hits.
                    let keywordRaw = FuzzyMatch.score(query: q, in: match.keywords)
                    let keywordScore = keywordRaw == Int.min ? Int.min : keywordRaw - 40
                    let score = max(titleScore, keywordScore)
                    return score > Int.min ? (match, score) : nil
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }

        // Re-group while preserving rank order within each category.
        return PaletteCategory.allCases.compactMap { category in
            let matches = ranked.filter { $0.category == category }
            return matches.isEmpty ? nil : PaletteGroup(category: category, matches: matches)
        }
    }

    // MARK: - Actions

    private func activateSelection() {
        let flat = groupedMatches.flatMap(\.matches)
        guard !flat.isEmpty else { return }
        activate(flat[min(selection, flat.count - 1)])
    }

    private func activate(_ match: PaletteMatch) {
        model.route = match.destination
        dismiss()
    }

    private func moveSelection(_ delta: Int, in count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func dismiss() {
        model.showCommandPalette = false
        query = ""
        selection = 0
    }
}

// MARK: - Palette row
//
// A single result line: leading tinted icon, title, dim subtitle, trailing
// category chip, and a Return hint on the highlighted row.

private struct PaletteRow: View {
    let match: PaletteMatch
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Leading icon in a tinted rounded tile.
                Image(systemName: match.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(match.tint)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(match.tint.opacity(0.16))
                    )

                // Title + subtitle.
                VStack(alignment: .leading, spacing: 1) {
                    Text(match.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if !match.subtitle.isEmpty {
                        Text(match.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                // Return hint on the active row, category chip otherwise.
                if selected {
                    Image(systemName: "return")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text(match.category.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Theme.card : .clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Result model

/// A category of indexed result, in fixed display order with a leading title.
private enum PaletteCategory: String, CaseIterable {
    case navigate, repos, skills, agents, mcp, ports

    var title: String {
        switch self {
        case .navigate: "Navigate"
        case .repos: "Repos"
        case .skills: "Skills"
        case .agents: "Agents"
        case .mcp: "MCP"
        case .ports: "Ports"
        }
    }
}

/// One searchable entry. `destination` is the route activation navigates to.
private struct PaletteMatch: Identifiable, Equatable {
    let id: String
    let category: PaletteCategory
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let keywords: String
    let destination: Route

    static func == (lhs: PaletteMatch, rhs: PaletteMatch) -> Bool { lhs.id == rhs.id }
}

/// A category plus its ranked matches, for sectioned rendering.
private struct PaletteGroup: Identifiable {
    var id: String { category.rawValue }
    let category: PaletteCategory
    let matches: [PaletteMatch]
}

// MARK: - Fuzzy matcher
//
// A compact subsequence scorer (fuzzy-finder style): every query character
// must appear in order. Consecutive runs, word-start hits, and a prefix match are
// rewarded; gaps between matched characters are penalized. Returns Int.min when
// the query is not a subsequence so non-matches drop out entirely.

private enum FuzzyMatch {
    static func score(query: String, in candidate: String) -> Int {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return 0 }
        let c = Array(candidate.lowercased())
        guard !c.isEmpty else { return Int.min }

        var qi = 0
        var score = 0
        var lastMatch = -1
        var ci = 0

        while ci < c.count && qi < q.count {
            if c[ci] == q[qi] {
                // Base reward for a matched character.
                score += 10

                // Reward adjacency (a contiguous run of matches).
                if lastMatch == ci - 1 { score += 12 }

                // Reward matches at a word boundary (start, or after a separator).
                if ci == 0 {
                    score += 18
                } else {
                    let prev = c[ci - 1]
                    if prev == " " || prev == "-" || prev == "_" || prev == "/" || prev == "." || prev == ":" {
                        score += 12
                    }
                }

                // Penalize the gap skipped since the previous matched character.
                if lastMatch >= 0 {
                    score -= min(8, (ci - lastMatch - 1))
                }

                lastMatch = ci
                qi += 1
            }
            ci += 1
        }

        // The whole query must be consumed to count as a match.
        guard qi == q.count else { return Int.min }

        // Bonus for matching at the very front of the candidate.
        if c.starts(with: q) { score += 25 }
        // Slight preference for shorter, tighter candidates.
        score -= max(0, c.count - q.count) / 6

        return score
    }
}
