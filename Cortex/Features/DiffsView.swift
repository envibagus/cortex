import SwiftUI
import AppKit

// MARK: - DiffsView
//
// The Workspace > Diffs screen, a "what would I commit" panel, rebuilt with STOCK
// native containers. The left column is a native selectable `List` (via the shared
// `SplitDetailView`) of every dirty repository (uncommittedFiles > 0) from
// model.repos.repos. Selecting one runs
//   git -C <path> status --short
//   git -C <path> diff --stat
// via the Shell helper and shows the combined output under a large native title,
// each block in its own GroupBox of monospaced text. When nothing is dirty, a
// native ContentUnavailableView says so. All data is read live.

struct DiffsView: View {
    @Environment(AppModel.self) private var model

    // The dirty repo currently inspected (by id == path).
    @State private var selectedID: RepoInfo.ID?
    // The captured git output for the selection.
    @State private var diff: DiffResult?
    // Whether a git run is in flight.
    @State private var isRunning = false

    var body: some View {
        Group {
            if dirtyRepos.isEmpty {
                // Either still scanning, or everything is clean.
                emptyState
            } else {
                // In-page native master/detail (shared SplitDetailView).
                SplitDetailView(
                    items: dirtyRepos,
                    selectedID: $selectedID,
                    listWidth: 280,
                    emptyIcon: "doc.on.doc",
                    emptyTitle: "Select a repo",
                    emptyMessage: "Choose a dirty repository to preview what you would commit.",
                    listHeader: { listHeader },
                    row: { repo, _ in
                        DirtyRepoRow(repo: repo)
                    },
                    detail: { repo in
                        DiffPanel(repo: repo, diff: diff, isRunning: isRunning)
                    }
                )
                // Run git whenever the native List selection changes.
                .onChange(of: selectedID) { _, _ in runForSelection() }
            }
        }
        .background(Theme.canvas)
        // Run git for the auto-selected first dirty repo.
        .onAppear { runForSelection() }
    }

    // MARK: List header (large native title)

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Standard big title to match the other library/list headers.
            Text("Diffs")
                .font(.cortexTitle)
                .foregroundStyle(.primary)
            Text("What you would commit, across your dirty repos")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Empty state (scanning or clean)

    @ViewBuilder
    private var emptyState: some View {
        if model.repos.isLoading {
            ContentUnavailableView(
                "Checking Working Trees",
                systemImage: "doc.on.doc",
                description: Text("Scanning your repos for uncommitted changes\u{2026}")
            )
        } else {
            ContentUnavailableView(
                "Nothing to Commit",
                systemImage: "checkmark.seal",
                description: Text("Every repository under your project roots has a clean working tree.")
            )
        }
    }

    // MARK: Dirty repos
    //
    // Most-changed first so the biggest diff is one click away.

    private var dirtyRepos: [RepoInfo] {
        model.repos.repos
            .filter(\.isDirty)
            .sorted { $0.uncommittedFiles > $1.uncommittedFiles }
    }

    // The selected repo resolved from its id.
    private var selected: RepoInfo? {
        dirtyRepos.first { $0.id == selectedID }
    }

    // MARK: Selection
    //
    // Run git for the current selection off the main thread, publishing back.

    private func runForSelection() {
        guard let repo = selected else { return }
        diff = nil
        isRunning = true
        let path = repo.path
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DiffResult.run(path: path)
            }.value
            // Only apply if the selection has not changed underneath us.
            if selected?.path == path {
                diff = result
                isRunning = false
            }
        }
    }
}

// MARK: - Diff result
//
// The captured output of `git status --short` and `git diff --stat` for one repo.

private struct DiffResult {
    var status: String
    var stat: String
    var gitMissing: Bool

    // Run both git commands against `path` off the main actor.
    nonisolated static func run(path: String) -> DiffResult {
        guard Shell.which("git") != nil else {
            return DiffResult(status: "", stat: "", gitMissing: true)
        }
        let cwd = URL(fileURLWithPath: path)
        let status = Shell.run(tool: "git", ["-C", path, "status", "--short"], cwd: cwd)?
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stat = Shell.run(tool: "git", ["-C", path, "diff", "--stat"], cwd: cwd)?
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DiffResult(status: status, stat: stat, gitMissing: false)
    }
}

// MARK: - Dirty repo row
//
// Plain native List content: name over a quiet branch caption, a trailing
// uncommitted-file count badge. The List supplies the selection highlight.

private struct DirtyRepoRow: View {
    let repo: RepoInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.circle")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(.body)
                    .lineLimit(1)
                if let branch = repo.currentBranch {
                    Text(branch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            // Uncommitted file count as a tinted native count indicator.
            Text("\(repo.uncommittedFiles)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Theme.warn)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Theme.warn.opacity(0.15), in: Capsule())
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Diff panel
//
// The right-hand "what would I commit" panel for the selected repo, rebuilt with
// native containers: a large native title with an "Open in Finder" action, then
// the porcelain status block and the diff --stat block, each in its own GroupBox
// of monospaced, selectable text.

private struct DiffPanel: View {
    let repo: RepoInfo
    let diff: DiffResult?
    let isRunning: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header: large native title + branch + Finder action.
                header(for: repo)

                if isRunning {
                    loading
                } else if let diff {
                    content(diff)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    // MARK: Header (large native title + branch + Finder)

    private func header(for repo: RepoInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(repo.name)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                if let branch = repo.currentBranch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
            } label: {
                Label("Open in Finder", systemImage: "folder")
            }
        }
    }

    // MARK: Loading

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Running git status and diff\u{2026}")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ diff: DiffResult) -> some View {
        if diff.gitMissing {
            ContentUnavailableView(
                "git Not Found",
                systemImage: "exclamationmark.triangle",
                description: Text("Cortex could not locate the git binary, so it cannot read this diff.")
            )
            .frame(maxWidth: .infinity)
        } else if diff.status.isEmpty && diff.stat.isEmpty {
            ContentUnavailableView(
                "Clean Now",
                systemImage: "checkmark.seal",
                description: Text("This working tree reports no changes anymore.")
            )
            .frame(maxWidth: .infinity)
        } else {
            // Status (porcelain short) block.
            DiffBlock(
                title: "Status",
                icon: "list.bullet",
                text: diff.status.isEmpty ? "No tracked changes." : diff.status,
                maxHeight: 240
            )
            // Diff --stat block.
            DiffBlock(
                title: "Changes",
                icon: "plusminus",
                text: diff.stat.isEmpty ? "No staged or unstaged diffs to summarize." : diff.stat,
                maxHeight: 360
            )
        }
    }
}

// MARK: - Diff block
//
// A native GroupBox holding a scrollable monospaced, selectable text region used
// for the git status + stat output.

private struct DiffBlock: View {
    let title: String
    let icon: String
    let text: String
    var maxHeight: CGFloat = 240

    var body: some View {
        GroupBox {
            ScrollView {
                Text(text)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .frame(maxHeight: maxHeight)
        } label: {
            Label(title, systemImage: icon)
                .font(.headline)
        }
    }
}
