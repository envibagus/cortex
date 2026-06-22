import SwiftUI
import AppKit

// MARK: - ReposView
//
// The Workspace > Repos screen, rendered as an IN-PAGE split (no modal sheet) that
// follows a native library browser: a native middle LIST with the system
// selection highlight, and a document-style DETAIL pane (scrolling markdown body
// over a pinned bottom metadata bar). Two tabs live in the list header:
//   - "Local"  : git working trees discovered under the project roots (model.repos.repos)
//   - "GitHub" : the authenticated user's GitHub repositories (model.repos.gitHubRepos)
//
// `selectedID` tracks the active tab's id (RepoInfo.id is its path; GitHubRepo.id
// is its nameWithOwner) so it survives within a tab. All data is read live from
// RepoService via AppModel. The split fills the whole detail pane.

struct ReposView: View {
    @Environment(AppModel.self) private var model

    // Which tab is showing.
    private enum Tab: Hashable { case local, gitHub }
    @State private var tab: Tab = .local

    // Search query, shared shape per tab.
    @State private var query = ""

    // Selection within the active tab. Both id types are String
    // (RepoInfo.id == path, GitHubRepo.id == nameWithOwner).
    @State private var selectedID: String?

    var body: some View {
        // One split per tab: the same listHeader (title + count + segmented + search)
        // drives both, and switching tabs swaps the entire master/detail pair.
        Group {
            switch tab {
            case .local:
                SplitDetailView(
                    items: filteredLocal,
                    selectedID: $selectedID,
                    emptyIcon: "folder",
                    emptyTitle: "No repository selected",
                    emptyMessage: "Pick a local repo to see its branch, status, config, and CLAUDE.md.",
                    listHeader: { listHeader },
                    row: { repo, _ in
                        LocalRepoRow(repo: repo)
                    },
                    detail: { repo in
                        RepoDetailPane(repo: repo)
                    }
                )
            case .gitHub:
                SplitDetailView(
                    items: filteredGitHub,
                    selectedID: $selectedID,
                    emptyIcon: "chevron.left.forwardslash.chevron.right",
                    emptyTitle: "No repository selected",
                    emptyMessage: "Pick a GitHub repository to see its details.",
                    listHeader: { listHeader },
                    row: { repo, _ in
                        GitHubRepoRow(repo: repo)
                    },
                    detail: { repo in
                        GitHubRepoDetailPane(repo: repo)
                    }
                )
            }
        }
        .background(Theme.canvas)
    }

    // MARK: List header (page title + count + tab picker + search)
    //
    // Lives inside the split's left pane so the whole view fills the detail pane.

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title + live count of the active tab's items.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Repos")
                    .font(.cortexTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(activeCount)")
                    .font(.cortexCaption)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
            }

            // Tab picker: Local vs GitHub (Liquid Glass segmented control).
            GlassSegmentedControl(items: [Tab.local, Tab.gitHub], selection: $tab) {
                $0 == .local ? "Local" : "GitHub"
            }
            // Reset selection when switching tabs so the new tab auto-selects its first item.
            .onChange(of: tab) { _, _ in selectedID = nil }

            // Search field, scoped to the active tab.
            ReposSearchField(query: $query, placeholder: searchPlaceholder)
        }
    }

    // MARK: Derived

    private var activeCount: Int {
        tab == .local ? filteredLocal.count : filteredGitHub.count
    }

    private var searchPlaceholder: String {
        tab == .local ? "Search local repos" : "Search GitHub repos"
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var filteredLocal: [RepoInfo] {
        let q = trimmedQuery
        guard !q.isEmpty else { return model.repos.repos }
        return model.repos.repos.filter {
            $0.name.lowercased().contains(q)
                || ($0.currentBranch?.lowercased().contains(q) ?? false)
                || ($0.remoteURL?.lowercased().contains(q) ?? false)
        }
    }

    private var filteredGitHub: [GitHubRepo] {
        let q = trimmedQuery
        guard !q.isEmpty else { return model.repos.gitHubRepos }
        return model.repos.gitHubRepos.filter {
            $0.name.lowercased().contains(q)
                || $0.owner.lowercased().contains(q)
                || ($0.language?.lowercased().contains(q) ?? false)
                || ($0.description?.lowercased().contains(q) ?? false)
        }
    }
}

// MARK: - Search field
//
// A Card-surfaced text field that matches the rest of the design system.

private struct ReposSearchField: View {
    @Environment(AppModel.self) private var model
    @Binding var query: String
    let placeholder: String
    // ⌘F focuses this field (via model.focusSearchToken).
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        )
        .onChange(of: model.focusSearchToken) { _, _ in searchFocused = true }
    }
}

// MARK: - Local repo row
//
// MINIMAL, NATIVE list content (mirrors the ConfigItemRow style): a small
// leading folder/code SF Symbol (caption, secondary), a VStack of the name (lineLimit
// 1) over a single quiet secondary caption that combines branch + a compact status
// summary (e.g. "main - 2 uncommitted - 1 ahead - CLAUDE.md"), a Spacer, then a small
// trailing relative last-commit caption. NO capsule pills, NO vertical text: indicators
// are tiny inline SF Symbols + short text kept on ONE line in secondary color. The
// native List draws the selection highlight, so this view supplies only plain content.

private struct LocalRepoRow: View {
    let repo: RepoInfo

    var body: some View {
        HStack(spacing: 10) {
            // Leading glyph: code mark for GitHub-backed trees, folder otherwise.
            Image(systemName: repo.isGitHub ? "chevron.left.forwardslash.chevron.right" : "folder")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18)

            // Name over a single combined branch + status caption.
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                // One quiet line: branch + the compact status summary, with tiny
                // inline arrows for ahead/behind so the whole row stays single-height.
                HStack(spacing: 5) {
                    if let branch = repo.currentBranch {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9, weight: .semibold))
                        Text(branch)
                            .lineLimit(1)
                    }
                    if let summary = statusSummary {
                        if repo.currentBranch != nil {
                            Text("-")
                        }
                        Text(summary)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            // Trailing: a faint dirty dot, then the relative last-commit time.
            if repo.isDirty {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
            }
            Text(Fmt.relative(repo.lastCommit))
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
    }

    // A compact, hyphen-joined status summary line: uncommitted count, ahead/behind,
    // and a terse "CLAUDE.md" marker. Returns nil when the repo is clean and in sync.
    private var statusSummary: String? {
        var parts: [String] = []
        if repo.uncommittedFiles > 0 { parts.append("\(repo.uncommittedFiles) uncommitted") }
        if repo.ahead > 0 { parts.append("\(repo.ahead) ahead") }
        if repo.behind > 0 { parts.append("\(repo.behind) behind") }
        if repo.commitsToday > 0 { parts.append("\(repo.commitsToday) today") }
        if repo.hasClaudeMd { parts.append("CLAUDE.md") }
        return parts.isEmpty ? nil : parts.joined(separator: " - ")
    }
}

// MARK: - Local repo detail pane
//
// The right pane for a local repo, rebuilt with STOCK native containers: a large
// native title (repo name as .title.bold) and selectable mono path subtitle, then
// native GroupBox sections built from LabeledContent rows for Git (branch, commits,
// status, last commit, remote + "Open remote"), Config (skill/agent counts,
// CLAUDE.md presence), and -- when present -- a "CLAUDE.md" GroupBox rendering the
// file with MarkdownText. Open in Finder lives in the header action row.

private struct RepoDetailPane: View {
    @Environment(AppModel.self) private var model
    let repo: RepoInfo

    // Active detail tab.
    @State private var tab: RepoTab = .overview

    // Lazily-loaded CLAUDE.md contents, keyed on the selected repo.
    @State private var claudeMd: String?
    @State private var claudeMdLineCount: Int = 0
    @State private var claudeMdTruncated = false

    // Render cap so a huge CLAUDE.md does not blow up the view.
    private let renderCap = 40_000

    enum RepoTab: String, CaseIterable, Identifiable {
        case overview, claudeMd, skills, agents
        var id: String { rawValue }
    }

    // This repo's project-level skills / agents (ConfigScanner tags project items
    // with their project directory name).
    private var repoSkills: [ConfigItem] {
        model.config.skills.filter { !$0.isGlobal && $0.projectName == repo.name }
    }
    private var repoAgents: [ConfigItem] {
        model.config.agents.filter { !$0.isGlobal && $0.projectName == repo.name }
    }
    // Only show tabs that have content (Overview is always present).
    private var availableTabs: [RepoTab] {
        var tabs: [RepoTab] = [.overview]
        if repo.hasClaudeMd { tabs.append(.claudeMd) }
        if !repoSkills.isEmpty { tabs.append(.skills) }
        if !repoAgents.isEmpty { tabs.append(.agents) }
        return tabs
    }
    private var effectiveTab: RepoTab { availableTabs.contains(tab) ? tab : .overview }
    private func tabLabel(_ t: RepoTab) -> String {
        switch t {
        case .overview: "Overview"
        case .claudeMd: "CLAUDE.md"
        case .skills: "Skills (\(repoSkills.count))"
        case .agents: "Agents (\(repoAgents.count))"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pinned header + tab switcher.
            VStack(alignment: .leading, spacing: 16) {
                header
                if availableTabs.count > 1 {
                    GlassSegmentedControl(items: availableTabs, selection: $tab) { tabLabel($0) }
                }
            }
            .padding(28)

            Divider().overlay(Theme.stroke)

            // Scrollable content for the active tab, with generous padding.
            ScrollView {
                Group {
                    switch effectiveTab {
                    case .overview:
                        VStack(alignment: .leading, spacing: 20) {
                            gitSection
                            configSection
                        }
                    case .claudeMd:
                        claudeMdBody
                    case .skills:
                        repoItemList(repoSkills, empty: "No project skills.")
                    case .agents:
                        repoItemList(repoAgents, empty: "No project agents.")
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        // Re-read CLAUDE.md and reset the tab whenever the selected repo changes.
        .task(id: repo.id) {
            loadClaudeMd()
            tab = .overview
        }
    }

    // MARK: CLAUDE.md tab (breathable markdown document, no boxed container)

    private var claudeMdBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let body = claudeMd {
                MarkdownText(markdown: body)
                if claudeMdTruncated {
                    Text("Preview truncated to \(Fmt.grouped(renderCap)) characters.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Could not read CLAUDE.md from disk.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Skills / Agents tab list (this repo's project items)

    @ViewBuilder
    private func repoItemList(_ items: [ConfigItem], empty: String) -> some View {
        if items.isEmpty {
            Text(empty).font(.callout).foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 11)
                    if idx < items.count - 1 { Divider() }
                }
            }
        }
    }

    // MARK: Header (large native title + path + actions)

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Repo name as the large native document title.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(repo.name)
                    .font(.title.bold())
                    .foregroundStyle(repo.isDirty ? Theme.warn : .primary)
                if repo.isDirty {
                    // Native badge for the dirty working tree.
                    Text("Uncommitted changes")
                        .font(.caption)
                        .foregroundStyle(Theme.warn)
                }
                Spacer(minLength: 0)
            }

            // Selectable, abbreviated path in monospaced secondary text.
            Text(repo.path.abbreviatedHomePath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)

            // Native action buttons: Finder + (optional) remote.
            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                if let remote = repo.remoteURL, let url = remoteWebURL(from: remote) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open remote", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .controlSize(.regular)
        }
    }

    // MARK: Git section (native GroupBox + LabeledContent rows)

    private var gitSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Branch", value: repo.currentBranch ?? "-")

                LabeledContent("Commits today") {
                    Text("\(repo.commitsToday)")
                        .foregroundStyle(repo.commitsToday > 0 ? Theme.green : .secondary)
                }

                LabeledContent("Uncommitted") {
                    Text("\(repo.uncommittedFiles)")
                        .foregroundStyle(repo.isDirty ? Theme.warn : .secondary)
                }

                LabeledContent("Behind / ahead", value: "\(repo.behind) behind, \(repo.ahead) ahead")

                LabeledContent("Last commit", value: lastCommitValue)

                if let remote = repo.remoteURL {
                    // Remote URL with an inline "Open remote" button when it resolves.
                    LabeledContent("Remote") {
                        HStack(spacing: 8) {
                            Text(remote)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            if let url = remoteWebURL(from: remote) {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                }
                                .buttonStyle(.borderless)
                                .help("Open remote")
                            }
                        }
                    }
                }

                LabeledContent("Hosted on", value: repo.isGitHub ? "GitHub" : "Local / other")
            }
            .padding(.vertical, 4)
        } label: {
            Label("Git", systemImage: "arrow.triangle.branch")
                .font(.headline)
        }
    }

    // MARK: Config section (skills / agents / CLAUDE.md presence)

    private var configSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Skills") {
                    Text("\(repo.skillCount)")
                        .foregroundStyle(repo.skillCount > 0 ? Theme.purple : .secondary)
                }

                LabeledContent("Agents") {
                    Text("\(repo.agentCount)")
                        .foregroundStyle(repo.agentCount > 0 ? Theme.green : .secondary)
                }

                LabeledContent("CLAUDE.md") {
                    if repo.hasClaudeMd {
                        Text("\(repo.claudeMdLines) lines")
                            .foregroundStyle(Theme.claude)
                    } else {
                        // No CLAUDE.md yet: offer to create a starter one, which opens in
                        // Instructions + your editor (see AppModel.createRepoClaudeMd).
                        Button {
                            Task { await model.createRepoClaudeMd(at: repo.path, repoName: repo.name) }
                        } label: {
                            Label("Create", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Config", systemImage: "gearshape")
                .font(.headline)
        }
    }

    // Relative + absolute last-commit time on one line.
    private var lastCommitValue: String {
        guard let last = repo.lastCommit else { return "-" }
        let abs = last.formatted(date: .abbreviated, time: .shortened)
        return "\(Fmt.relative(last))  (\(abs))"
    }

    // MARK: Lazy CLAUDE.md read

    private func loadClaudeMd() {
        // Reset before each read so we never show a stale repo's file.
        claudeMd = nil
        claudeMdLineCount = 0
        claudeMdTruncated = false
        guard repo.hasClaudeMd else { return }

        let mdPath = (repo.path as NSString).appendingPathComponent("CLAUDE.md")
        guard let raw = try? String(contentsOfFile: mdPath, encoding: .utf8) else { return }

        claudeMdLineCount = raw.split(separator: "\n", omittingEmptySubsequences: false).count
        if raw.count > renderCap {
            claudeMd = String(raw.prefix(renderCap))
            claudeMdTruncated = true
        } else {
            claudeMd = raw
        }
    }

    // MARK: Helpers

    // Normalize a git remote (https or scp-style ssh) into an https web URL.
    private func remoteWebURL(from remote: String) -> URL? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        if s.hasPrefix("git@") {
            // git@github.com:owner/repo -> https://github.com/owner/repo
            let stripped = String(s.dropFirst("git@".count)).replacingOccurrences(of: ":", with: "/")
            return URL(string: "https://\(stripped)")
        }
        if s.hasPrefix("ssh://git@") {
            let stripped = String(s.dropFirst("ssh://git@".count))
            return URL(string: "https://\(stripped)")
        }
        return URL(string: s)
    }
}

// MARK: - GitHub repo row
//
// MINIMAL, NATIVE list content matching the local row: a small leading code/lock
// SF Symbol, a VStack of nameWithOwner (lineLimit 1) over a single quiet secondary
// caption that combines language + visibility + a tiny inline star count, a Spacer,
// then a small trailing relative updated-time caption. NO capsule pills, NO vertical
// text. The native List draws the selection highlight.

private struct GitHubRepoRow: View {
    let repo: GitHubRepo

    var body: some View {
        HStack(spacing: 10) {
            // Leading glyph: lock for private repos, code mark otherwise.
            Image(systemName: repo.isPrivate ? "lock" : "chevron.left.forwardslash.chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18)

            // nameWithOwner over a single combined language + visibility + stars caption.
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.nameWithOwner)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                // One quiet line: a tiny language dot, then a hyphen-joined summary
                // (language - Private/Fork - stars), all secondary and single-height.
                HStack(spacing: 5) {
                    if let language = repo.language {
                        Circle()
                            .fill(LanguageColor.tint(for: language))
                            .frame(width: 7, height: 7)
                    }
                    if !subtitleText.isEmpty {
                        Text(subtitleText)
                            .lineLimit(1)
                    }
                    if repo.stars > 0 {
                        if !subtitleText.isEmpty { Text("-") }
                        Image(systemName: "star")
                            .font(.system(size: 9))
                        Text(Fmt.compact(repo.stars))
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            // Trailing: relative updated time.
            Text(Fmt.relative(repo.updatedAt))
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    // A compact, hyphen-joined caption: language, then visibility / fork markers.
    private var subtitleText: String {
        var parts: [String] = []
        if let language = repo.language { parts.append(language) }
        if repo.isPrivate { parts.append("Private") }
        if repo.isFork { parts.append("Fork") }
        return parts.joined(separator: " - ")
    }
}

// MARK: - GitHub repo detail pane
//
// The right pane for a GitHub repo, rebuilt with STOCK native containers: a large
// native title (nameWithOwner as .title.bold) over a selectable URL, then a native
// "Details" GroupBox of LabeledContent rows (owner, visibility, type, stars,
// language, updated), a Description GroupBox when present, and an "Open on GitHub"
// action button in the header.

private struct GitHubRepoDetailPane: View {
    let repo: GitHubRepo

    var body: some View {
        // Native scrolling document: large title, then GroupBox sections.
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header: nameWithOwner as large native title + url + action.
                header

                // Details: all GitHubRepo fields as LabeledContent rows.
                detailsSection

                // Description (only when the repo has one).
                if let description = repo.description, !description.isEmpty {
                    descriptionSection(description)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    // MARK: Header (large native title + url + Open on GitHub)

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // nameWithOwner as the large native document title.
            Text(repo.nameWithOwner)
                .font(.title.bold())
                .foregroundStyle(.primary)

            // Selectable URL in monospaced secondary text.
            Text(repo.url)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)

            // Native action button: open the repo on GitHub.
            if let url = URL(string: repo.url) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open on GitHub", systemImage: "arrow.up.right.square")
                }
                .controlSize(.regular)
            }
        }
    }

    // MARK: Details section (native GroupBox + LabeledContent rows)

    private var detailsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Owner", value: repo.owner)

                LabeledContent("Visibility") {
                    Text(repo.isPrivate ? "Private" : "Public")
                        .foregroundStyle(repo.isPrivate ? Theme.orange : Theme.green)
                }

                LabeledContent("Type", value: repo.isFork ? "Fork" : "Source")

                LabeledContent("Stars") {
                    Text(Fmt.grouped(repo.stars))
                        .foregroundStyle(Theme.yellow)
                }

                if let language = repo.language {
                    LabeledContent("Language") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(LanguageColor.tint(for: language))
                                .frame(width: 8, height: 8)
                            Text(language)
                        }
                    }
                }

                LabeledContent("Updated", value: updatedValue)
            }
            .padding(.vertical, 4)
        } label: {
            Label("Details", systemImage: "info.circle")
                .font(.headline)
        }
    }

    // MARK: Description section (native GroupBox)

    private func descriptionSection(_ description: String) -> some View {
        GroupBox {
            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } label: {
            Label("Description", systemImage: "text.alignleft")
                .font(.headline)
        }
    }

    // Relative + absolute updated time on one line.
    private var updatedValue: String {
        guard let updated = repo.updatedAt else { return "-" }
        let abs = updated.formatted(date: .abbreviated, time: .shortened)
        return "\(Fmt.relative(updated))  (\(abs))"
    }
}

// MARK: - Home-path abbreviation
//
// Replaces the user's home directory with a leading tilde for compact paths, the
// way a document viewer shows a file location.

private extension String {
    var abbreviatedHomePath: String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Language color
//
// A small, stable mapping of common languages to a dot color, falling back to a
// hashed pick from the theme palette so unknown languages still get a stable hue.

private enum LanguageColor {
    static func tint(for language: String) -> Color {
        switch language.lowercased() {
        case "swift": return Theme.orange
        case "typescript", "ts": return Theme.blue
        case "javascript", "js": return Theme.yellow
        case "python": return Theme.green
        case "rust": return Theme.claude
        case "go": return Theme.blue
        case "ruby": return .red
        case "java", "kotlin": return Theme.orange
        case "c", "c++", "cpp", "c#": return Theme.purple
        case "html", "css": return Theme.orange
        case "shell", "bash": return Theme.green
        default:
            // Stable palette pick keyed on the language name.
            let idx = abs(language.hashValue) % Theme.palette.count
            return Theme.palette[idx]
        }
    }
}
