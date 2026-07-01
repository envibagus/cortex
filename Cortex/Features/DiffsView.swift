import SwiftUI
import AppKit

// MARK: - DiffsView
//
// The Workspace > Diffs screen. A left-aligned title + glass segmented control sit above
// two tabs:
//   - Working Tree (default): a master/detail browser over every repo with uncommitted
//     changes. The repo list is instant (it reuses the already-scanned RepoInfo counts),
//     sorted by most-recently-updated; a repo's changed files load on selection, and a
//     file's actual diff loads only when its row is expanded - so the page stays fast and
//     nothing heavy runs until you click.
//   - By Session: the same master/detail shape, but the left list is Claude Code sessions
//     that changed files (parsed off-main from each transcript's Edit/Write tool calls),
//     and the detail shows that session's changed files + diffs, with a Replay button.

struct DiffsView: View {
    @State private var mode: Mode = .workingTree

    enum Mode: String, CaseIterable, Identifiable, Hashable {
        case workingTree = "Working Tree"
        case bySession = "By Session"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab switch, pinned (left-aligned) above whichever tab is showing. The title +
            // subtitle now live in the toolbar band (`.cortexPageChrome`), so only the
            // Working Tree / By Session control sits here.
            GlassSegmentedControl(items: Mode.allCases, selection: $mode) { $0.rawValue }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.pageHInset)
                .padding(.top, Theme.pageTopInset)
                .padding(.bottom, 14)

            Divider().overlay(Theme.stroke)

            switch mode {
            case .workingTree: WorkingTreeDiffsTab()
            case .bySession: SessionDiffsTab()
            }
        }
        .background(Theme.canvas)
        .cortexScrollEdge()
        .cortexPageChrome("Diffs", subtitle: mode == .workingTree
                          ? "Uncommitted changes across your repos"
                          : "Files Claude Code changed, grouped by session")
    }
}

// MARK: - By Session tab (master/detail: session -> changed files -> diff)
//
// The left list is sessions that changed files; the detail shows the selected session's
// files (each expandable to its colored diff) plus a Replay button. Diffs are parsed once
// off-main when the page opens (SessionDiffParser), so expanding a file is instant.

private struct SessionDiffsTab: View {
    @Environment(AppModel.self) private var model

    // Parsed sessions that changed files (nil = still scanning), newest-first.
    @State private var changed: [ChangedSession]?
    @State private var selectedID: ChangedSession.ID?
    @State private var replaySession: ClaudeSession?

    // Cap the scan to the most recent sessions so opening Diffs stays responsive.
    private static let scanCap = 150

    var body: some View {
        Group {
            if let changed {
                if changed.isEmpty {
                    CortexEmptyState(icon: "doc.on.doc", title: "No file changes yet",
                                     message: "Run Claude Code and the edits from each session will show up here.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SplitDetailView(
                        items: changed,
                        selectedID: $selectedID,
                        listWidth: 300,
                        autoSelectFirst: true,
                        emptyContent: {
                            AnyView(CortexEmptyState(icon: "doc.on.doc", title: "Pick a session",
                                                     message: "Select a session to see the files it changed."))
                        }
                    ) {
                        HStack {
                            Text("Sessions with changes").font(.cortexTitle).foregroundStyle(.primary)
                            Spacer(minLength: 6)
                            Text("\(changed.count)")
                                .font(.callout.weight(.medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } row: { item, _ in
                        SessionDiffListRow(item: item)
                    } detail: { item in
                        SessionChangesPane(item: item, onReplay: { replaySession = item.session })
                    }
                }
            } else {
                loadingState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        // Full-conversation replay, reusing the standalone (non-embedded) replay view.
        .sheet(item: $replaySession) { session in
            SessionReplayView(session: session)
                .frame(minWidth: 900, minHeight: 600)
        }
        // Re-scan on first appear and after each data refresh (lastScan change).
        .task(id: model.sessions.lastScan) { await rescan() }
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Reading edits from your sessions\u{2026}").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Parse the most recent sessions off-main, keeping only those that changed files.
    private func rescan() async {
        let recent = Array(model.sessions.sessions.prefix(Self.scanCap))
        changed = await Task.detached(priority: .userInitiated) {
            recent.compactMap { session -> ChangedSession? in
                let diff = SessionDiffParser.parse(url: session.fileURL)
                return diff.isEmpty ? nil : ChangedSession(session: session, diff: diff)
            }
        }.value
    }
}

// MARK: - Changed session (a session + the file edits it made)

private struct ChangedSession: Identifiable, Sendable {
    var id: String { session.id }
    let session: ClaudeSession
    let diff: SessionDiff
}

// MARK: - Session row (By Session left list)

private struct SessionDiffListRow: View {
    let item: ChangedSession
    private var session: ClaudeSession { item.session }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .font(.callout)
                .foregroundStyle(Theme.claude)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.lastPrompt ?? "No prompt recorded")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(projectName) \u{00B7} \(Fmt.relative(session.endedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Pill(text: "\(item.diff.fileCount)", tint: Theme.orange)
        }
        .padding(.vertical, 5)
    }

    private var projectName: String { (session.projectPath as NSString).lastPathComponent }
}

// MARK: - Session changes pane (By Session detail)

private struct SessionChangesPane: View {
    let item: ChangedSession
    let onReplay: () -> Void
    private var session: ClaudeSession { item.session }
    private var diff: SessionDiff { item.diff }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                VStack(spacing: 10) {
                    ForEach(diff.files) { SessionFileRow(file: $0) }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(session.lastPrompt ?? "No prompt recorded")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onReplay) {
                    Label("Replay", systemImage: "play.fill").font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.blue)
                .linkCursor()
                .help("Replay this session")
            }
            HStack(spacing: 8) {
                Pill(text: "Claude Code", tint: Theme.claude)
                Pill(text: projectLabel, tint: Theme.blue)
                Text("\(diff.fileCount) \(diff.fileCount == 1 ? "file" : "files")").foregroundStyle(.secondary)
                Text("+\(diff.totalAdded)").foregroundStyle(.green)
                Text("-\(diff.totalRemoved)").foregroundStyle(.red)
                Spacer(minLength: 8)
                Text(Fmt.relative(session.endedAt)).foregroundStyle(.tertiary)
            }
            .font(.caption.monospacedDigit())
        }
    }

    // "app/llm-cheatsheet" style label: the last two path components.
    private var projectLabel: String {
        session.projectPath.split(separator: "/").map(String.init).suffix(2).joined(separator: "/")
    }
}

// MARK: - One session-edited file (collapsible; hunks are pre-parsed so expanding is instant)

private struct SessionFileRow: View {
    let file: FileEdit
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: file.isNewFile ? "doc.badge.plus" : "doc.text")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(file.isNewFile ? Theme.green : Theme.orange)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.fileName)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(file.path.tildeAbbreviated)
                            .font(.system(size: 11).monospaced())
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text("+\(file.added)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.green)
                    Text("-\(file.removed)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.red)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                    } label: {
                        Image(systemName: "square.and.pencil").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.blue).linkCursor()
                    .help("Reveal \(file.fileName) in Finder")
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .linkCursor()

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(file.hunks) { DiffHunkView(hunk: $0) }
                }
                .padding(.top, 10)
            }
        }
        .padding(14)
        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        )
    }
}

// MARK: - Working Tree tab (repo -> changed files -> lazy diff)
//
// Master/detail over the repos that have uncommitted changes, sorted most-recently-
// updated first. The list is instant (it filters the already-scanned RepoInfo); selecting
// a repo loads its changed files, and a file's diff is fetched only when its row expands.

private struct WorkingTreeDiffsTab: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: RepoInfo.ID?

    // Dirty repos, most-recently-updated first (by last commit; undated repos sort last).
    private var dirtyRepos: [RepoInfo] {
        model.repos.repos.filter(\.isDirty)
            .sorted { ($0.lastCommit ?? .distantPast) > ($1.lastCommit ?? .distantPast) }
    }

    var body: some View {
        Group {
            if model.repos.isLoading && model.repos.repos.isEmpty {
                loading
            } else if dirtyRepos.isEmpty {
                CortexEmptyState(icon: "checkmark.seal", title: "Everything's committed",
                                 message: "No repo in your scan roots has uncommitted changes.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SplitDetailView(
                    items: dirtyRepos,
                    selectedID: $selectedID,
                    listWidth: 300,
                    autoSelectFirst: true,
                    emptyContent: {
                        AnyView(CortexEmptyState(icon: "doc.on.doc", title: "Pick a repo",
                                                 message: "Select a repo to see its changed files."))
                    }
                ) {
                    HStack {
                        Text("Repos with changes").font(.cortexTitle).foregroundStyle(.primary)
                        Spacer(minLength: 6)
                        Text("\(dirtyRepos.count)")
                            .font(.callout.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } row: { repo, _ in
                    DirtyRepoRow(repo: repo)
                } detail: { repo in
                    RepoChangesPane(repo: repo)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    private var loading: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Scanning your repos\u{2026}").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Dirty repo row (Working Tree left list)

private struct DirtyRepoRow: View {
    let repo: RepoInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.callout)
                .foregroundStyle(Theme.claude)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let branch = repo.currentBranch, !branch.isEmpty {
                    Text(branch).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Pill(text: "\(repo.uncommittedFiles)", tint: Theme.orange)
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Repo changes pane (Working Tree detail)
//
// Loads the repo's changed files on selection (one git status + numstat, off-main), then
// lists them. Each row expands to its diff, fetched lazily on first expand.

private struct RepoChangesPane: View {
    let repo: RepoInfo
    @State private var files: [GitFileChange]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let files {
                    if files.isEmpty {
                        CortexEmptyState(icon: "checkmark.seal", title: "No changes",
                                         message: "This repo's working tree is clean now.")
                    } else {
                        VStack(spacing: 10) {
                            ForEach(files) { FileChangeRow(repoPath: repo.path, change: $0) }
                        }
                    }
                } else {
                    loading
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        .task(id: repo.id) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(repo.name).font(.largeTitle.bold()).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
                } label: {
                    Label("Open in Finder", systemImage: "folder").font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.blue)
                .linkCursor()
                .help("Reveal the repo in Finder")
            }
            // Branch pill on its own line below the title (mirroring the left list's
            // name-over-branch rows): inline next to the title, a long branch name
            // squeezed the repo name into truncation.
            if let branch = repo.currentBranch, !branch.isEmpty {
                Pill(text: branch, tint: Theme.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(repo.path.tildeAbbreviated)
                .font(.callout.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let files, !files.isEmpty {
                let added = files.reduce(0) { $0 + $1.added }
                let removed = files.reduce(0) { $0 + $1.removed }
                HStack(spacing: 12) {
                    Text("\(files.count) \(files.count == 1 ? "file" : "files")").foregroundStyle(.secondary)
                    Text("+\(added)").foregroundStyle(.green)
                    Text("-\(removed)").foregroundStyle(.red)
                }
                .font(.caption.monospacedDigit())
            }
        }
    }

    private var loading: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Reading changes\u{2026}").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 30)
    }

    private func load() async {
        files = nil
        let path = repo.path
        files = await Task.detached(priority: .userInitiated) {
            GitChanges.changedFiles(repoPath: path)
        }.value
    }
}

// MARK: - One changed file (Working Tree; expandable to its lazy diff)

private struct FileChangeRow: View {
    let repoPath: String
    let change: GitFileChange

    @State private var expanded = false
    @State private var hunks: [DiffHunk]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { toggle() } label: {
                HStack(spacing: 10) {
                    StatusTag(status: change.status)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(change.fileName)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if !change.directory.isEmpty {
                            Text(change.directory)
                                .font(.system(size: 11).monospaced())
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 8)
                    countsView
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .linkCursor()

            if expanded {
                expandedBody.padding(.top, 10)
            }
        }
        .padding(14)
        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        )
    }

    // +/-, "new" for untracked, "binary" for binaries.
    @ViewBuilder
    private var countsView: some View {
        if change.isBinary {
            Text("binary").font(.caption).foregroundStyle(.tertiary)
        } else if change.status == .untracked {
            Text("new").font(.caption.weight(.semibold)).foregroundStyle(.green)
        } else {
            Text("+\(change.added)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.green)
            Text("-\(change.removed)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var expandedBody: some View {
        if let hunks {
            if hunks.isEmpty {
                Text(change.isBinary ? "Binary file - no text diff to show." : "No textual changes to show.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(hunks) { DiffHunkView(hunk: $0) }
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading diff\u{2026}").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        if expanded && hunks == nil { Task { await loadDiff() } }
    }

    private func loadDiff() async {
        let path = repoPath, c = change
        hunks = await Task.detached(priority: .userInitiated) {
            GitChanges.diffHunks(repoPath: path, change: c)
        }.value
    }
}

// MARK: - Status tag (the M / A / D / ? chip)

private struct StatusTag: View {
    let status: GitChangeStatus

    var body: some View {
        Text(status.tag)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(status.tint)
            .frame(width: 18, height: 18)
            .background(status.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .help(status.label)
    }
}

// MARK: - Diff hunk view
//
// A monospaced colored diff: removed lines on a faint red wash, added lines on a faint
// green wash, capped to a preview height with a "Show N more lines" expander. Internal
// (not private) so the Snapshots screen reuses the exact same renderer for its
// version-vs-version / version-vs-current diffs.

struct DiffHunkView: View {
    let hunk: DiffHunk
    @State private var expanded = false

    // Lines shown before the "Show N more" expander kicks in.
    private static let collapsedLines = 12

    private var visibleLines: [DiffLine] {
        expanded ? hunk.lines : Array(hunk.lines.prefix(Self.collapsedLines))
    }
    private var hiddenCount: Int { max(0, hunk.lines.count - Self.collapsedLines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleLines) { line in
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(foreground(line.kind))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(background(line.kind))
            }

            if !expanded && hiddenCount > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded = true }
                } label: {
                    Text("Show \(hiddenCount) more \(hiddenCount == 1 ? "line" : "lines")\u{2026}")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // Diff line colors: literal green/red (the documented palette exception).
    private func foreground(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: Color.green
        case .removed: Color.red
        case .context: Theme.textSecondary
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: Color.green.opacity(0.12)
        case .removed: Color.red.opacity(0.12)
        case .context: Color.clear
        }
    }
}
