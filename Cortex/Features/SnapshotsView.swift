import SwiftUI
import AppKit

// MARK: - SnapshotsView
//
// The Workspace > Snapshots screen. Claude Code keeps versioned backups of every file it
// edits under ~/.claude/file-history (one folder per session, files named
// `<hash>@v<n>`). On its own that's an opaque pile of hash-named blobs; this screen turns
// it into something usable - and strictly READ-ONLY, so it can never change your files:
//
//   - Real filenames + projects, not hashes (resolved via FileHistoryStore, which hashes
//     each path the session's transcript edited and matches it to the snapshot files).
//   - A per-file version timeline gathered ACROSS every session that touched the file.
//   - A colored diff of any version vs the current on-disk file or vs the previous
//     snapshot, reusing the Diffs page's DiffHunkView.
//   - "Open" a version to view a READ-ONLY copy in your editor, so you can read or copy
//     from it by hand. Cortex never overwrites, copies onto, or deletes your files.
//
// Layout is the shared SplitDetailView: files on the left, the selected file's history +
// diff on the right.

struct SnapshotsView: View {
    @Environment(AppModel.self) private var model

    // The file-history scan (owned by the view; re-scanned when sessions change).
    @State private var store = FileHistoryStore()
    @State private var selectedFileID: SnapshotFile.ID?

    // Left-pane filter bar state (search + project scope + sort), matching the library panes.
    @State private var query = ""
    @State private var scope: String?
    @State private var sort: LibrarySort = .modified

    var body: some View {
        Group {
            if !store.rootExists {
                unavailableState
            } else if !store.didScan {
                loadingState
            } else if store.files.isEmpty {
                emptyState
            } else {
                splitView
            }
        }
        .cortexScrollEdge()
        .cortexPageChrome("Snapshots",
                          subtitle: "Read-only versions of files Claude Code edited",
                          count: store.didScan ? store.snapshotCount : nil)
        // Re-scan on first appear and whenever the session list is refreshed (so newly
        // backed-up files resolve to their real names once sessions finish loading).
        .task(id: model.sessions.lastScan) { await reload() }
    }

    // MARK: - Master / detail

    private var splitView: some View {
        SplitDetailView(
            items: visibleFiles,
            selectedID: $selectedFileID,
            listWidth: 340,
            emptyContent: { AnyView(OverviewPane(store: store)) },
            listHeader: { listHeader },
            row: { file, _ in SnapshotFileRow(file: file) },
            detail: { file in SnapshotFileDetail(file: file) }
        )
    }

    // Left-pane header: title + overview counts + the shared search / scope / sort bar.
    private var listHeader: some View {
        // Title + counts now live in the toolbar band (`.cortexPageChrome`); the left pane
        // keeps just the shared search / scope / sort bar.
        LibraryFilterBar(query: $query, placeholder: "Search files", scope: $scope, scopes: scopes, sort: $sort)
    }

    // MARK: - Derived list

    // Unique project names present, for the scope filter.
    private var scopes: [String] {
        Array(Set(store.files.map(\.projectName))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // The files after search + scope filter + sort.
    private var visibleFiles: [SnapshotFile] {
        var out = store.files
        if let scope { out = out.filter { $0.projectName == scope } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            out = out.filter {
                $0.displayName.lowercased().contains(q) || ($0.path?.lowercased().contains(q) ?? false)
            }
        }
        switch sort {
        case .name: out.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .modified: out.sort { $0.latestModified > $1.latestModified }
        case .size: out.sort { $0.totalVersions > $1.totalVersions }
        }
        return out
    }

    // MARK: - States

    private var unavailableState: some View {
        ContentUnavailableView(
            "No File-History Yet",
            systemImage: "camera",
            description: Text("Claude Code stores versioned snapshots of files it edits under ~/.claude/file-history, one folder per session. That directory does not exist yet, so there is nothing to browse. It will appear after Claude Code edits files in a session.")
        )
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Reading file history\u{2026}").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Snapshots",
            systemImage: "camera",
            description: Text("The file-history directory is present but contains no session snapshots yet.")
        )
    }

    // MARK: - Reload

    private func reload() async {
        let metas = model.sessions.sessions.map {
            SnapshotSessionMeta(id: $0.id, projectName: $0.projectName, displayTitle: $0.displayTitle, transcriptURL: $0.fileURL)
        }
        await store.load(metas: metas)
    }
}

// MARK: - Overview pane (shown when no file is selected)
//
// The right-pane default: a short explainer + the three headline counts, so an empty
// selection still tells you what this screen is and how much it's tracking.

private struct OverviewPane: View {
    let store: FileHistoryStore

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
            VStack(spacing: 6) {
                Text("Claude Code file backups")
                    .font(.cortexHeadline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Every file Claude Code edits is backed up version by version. Pick a file on the left to read an earlier copy. Cortex only reads these backups - it never changes your files.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: 12) {
                StatTile(label: "Files", value: Fmt.grouped(store.files.count), dot: Theme.blue)
                StatTile(label: "Versions", value: Fmt.grouped(store.snapshotCount), dot: Theme.orange)
                StatTile(label: "Sessions", value: Fmt.grouped(store.sessionCount), dot: Theme.blue)
            }
            .frame(maxWidth: 460)
        }
        .padding(40)
    }
}

// MARK: - File row (left list)
//
// One backed-up file: a doc glyph (dimmed + question mark when the path couldn't be
// resolved), its filename over the project it belongs to, the version count, and the
// most-recent backup time. Plain content - SplitDetailView's List draws the selection.

private struct SnapshotFileRow: View {
    let file: SnapshotFile

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: file.resolved ? "doc.text" : "questionmark.square.dashed")
                .font(.callout)
                .foregroundStyle(file.resolved ? Theme.textSecondary : Theme.textTertiary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.projectName)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 3) {
                Pill(text: "\(file.totalVersions)", tint: Theme.blue)
                Text(Fmt.relative(file.latestModified == .distantPast ? nil : file.latestModified))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 5)
    }
}

// MARK: - File detail (right pane)
//
// The selected file's full story: a header (name / path / project / reveal current file), a
// version timeline (every backup across sessions, newest first), and a read-only colored
// diff of the selected version - either against the current on-disk file or the previous
// snapshot. Every action here is READ-ONLY: "Open" shows a read-only copy of a backup in
// your editor; nothing is ever written to, over, or alongside your real files.

private struct SnapshotFileDetail: View {
    let file: SnapshotFile

    // Which version's diff is shown (defaults to the newest backup).
    @State private var selectedVersionID: SnapshotVersion.ID?
    @State private var mode: DiffMode = .vsCurrent
    // The computed diff (nil = still reading/diffing off-main) + an optional note when
    // there's nothing to show (identical, binary, file missing, oldest snapshot).
    @State private var hunks: [DiffHunk]?
    @State private var diffNote: String?

    // What the diff compares the selected version against.
    enum DiffMode: String, CaseIterable, Identifiable, Hashable {
        case vsCurrent = "vs current file"
        case vsPrevious = "vs previous version"
        var id: String { rawValue }
    }

    private var selectedVersion: SnapshotVersion? {
        file.versions.first { $0.id == selectedVersionID } ?? file.versions.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider().overlay(Theme.stroke)
                versionTimeline
                Divider().overlay(Theme.stroke)
                diffSection
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        // Reset the selection + default mode whenever the chosen file changes.
        .onChange(of: file.id) { _, _ in resetForFile() }
        .onAppear { if selectedVersionID == nil { resetForFile() } }
        // Recompute the diff when the version or comparison mode changes.
        .task(id: diffKey) { await computeDiff() }
    }

    // A composite id so the diff recomputes on either file, version, or mode change.
    private var diffKey: String { "\(file.id)|\(selectedVersionID ?? "")|\(mode.rawValue)" }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(file.displayName)
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Pill(text: file.projectName, tint: Theme.blue)
                Spacer(minLength: 8)
                revealCurrentButton
            }

            if let path = file.path {
                Text(path.tildeAbbreviated)
                    .font(.callout.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Text("Path not recognized from the session transcript - read-only.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }

            // A plain, reassuring statement of the read-only contract.
            Label("\(file.totalVersions) backed-up \(file.totalVersions == 1 ? "version" : "versions") \u{00B7} read-only, your files are never changed",
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // Reveal the CURRENT on-disk file in Finder (the live file, not a backup).
    @ViewBuilder
    private var revealCurrentButton: some View {
        if let path = file.path, FileManager.default.fileExists(atPath: path) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Label("Reveal current file", systemImage: "folder").font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.blue)
            .linkCursor()
            .help("Reveal the current on-disk file in Finder")
        }
    }

    // MARK: Version timeline

    private var versionTimeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "clock.arrow.circlepath", title: "Version history",
                          trailing: "\(file.totalVersions)")
            VStack(spacing: 8) {
                ForEach(file.versions) { version in
                    versionRow(version)
                }
            }
        }
    }

    private func versionRow(_ version: SnapshotVersion) -> some View {
        let isSelected = version.id == (selectedVersionID ?? file.versions.first?.id)
        return HStack(spacing: 11) {
            // Selecting a version drives the diff below (taps anywhere on the metadata).
            Button { selectedVersionID = version.id } label: {
                HStack(spacing: 11) {
                    Image(systemName: isSelected ? "smallcircle.filled.circle" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Fmt.relative(version.modified == .distantPast ? nil : version.modified))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(version.sessionLabel) \u{00B7} v\(version.version) \u{00B7} \(byteString(version.size))")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .linkCursor()

            // READ-ONLY: open a read-only copy of this exact version in the user's editor.
            Button { openVersion(version) } label: {
                Label("Open", systemImage: "arrow.up.forward.square")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.blue)
            .linkCursor()
            .help("Open a read-only copy of this version (your file is not changed)")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .fill(isSelected ? Theme.cardRaised : Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .strokeBorder(isSelected ? Theme.strokeStrong : Theme.stroke, lineWidth: 1)
        )
    }

    // MARK: Diff section

    private var diffSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(icon: "plus.forwardslash.minus", title: diffTitle)
                Spacer(minLength: 8)
                // Only resolved files can compare against a live on-disk file.
                if file.resolved {
                    GlassSegmentedControl(items: DiffMode.allCases, selection: $mode) { $0.rawValue }
                }
            }

            if let hunks {
                if hunks.isEmpty {
                    Text(diffNote ?? "No changes to show.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if let diffNote {
                        Text(diffNote).font(.caption).foregroundStyle(.tertiary)
                    }
                    ForEach(hunks) { hunk in
                        DiffHunkView(hunk: hunk)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Building diff\u{2026}").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var diffTitle: String {
        switch mode {
        case .vsCurrent: "Difference from the current file"
        case .vsPrevious: "What this snapshot introduced"
        }
    }

    // MARK: Diff computation (off-main, read-only)

    private func resetForFile() {
        selectedVersionID = file.versions.first?.id
        mode = file.resolved ? .vsCurrent : .vsPrevious
    }

    private func computeDiff() async {
        hunks = nil
        diffNote = nil
        guard let version = selectedVersion else { hunks = []; return }

        let mode = self.mode
        let path = file.path
        // Resolve "previous" off the chronologically-sorted list (next index = older).
        let previousURL: URL? = {
            guard let idx = file.versions.firstIndex(where: { $0.id == version.id }),
                  idx + 1 < file.versions.count else { return nil }
            return file.versions[idx + 1].url
        }()
        let versionURL = version.url

        let result = await Task.detached(priority: .userInitiated) { () -> (hunks: [DiffHunk], note: String?) in
            guard let newText = FileHistoryStore.readText(versionURL) else {
                return ([], "Binary or non-text snapshot - no diff to show.")
            }
            switch mode {
            case .vsCurrent:
                guard let path else {
                    return ([], "Path not recognized - can't compare to the current file.")
                }
                guard let currentText = FileHistoryStore.readText(URL(fileURLWithPath: path)) else {
                    // File missing (or binary): show the whole backup as additions.
                    return (LineDiff.hunks(old: [], new: LineDiff.lines(newText)),
                            "This file isn't on disk right now.")
                }
                if currentText == newText {
                    return ([], "This version matches the current file.")
                }
                // old = what's on disk now, new = this backup.
                return (LineDiff.hunks(old: LineDiff.lines(currentText), new: LineDiff.lines(newText)), nil)

            case .vsPrevious:
                guard let previousURL, let previousText = FileHistoryStore.readText(previousURL) else {
                    return (LineDiff.hunks(old: [], new: LineDiff.lines(newText)),
                            "Oldest snapshot - shown as all-new.")
                }
                if previousText == newText {
                    return ([], "No change from the previous snapshot.")
                }
                return (LineDiff.hunks(old: LineDiff.lines(previousText), new: LineDiff.lines(newText)), nil)
            }
        }.value

        hunks = result.hunks
        diffNote = result.note
    }

    // MARK: Open (read-only preview)

    // Open a READ-ONLY copy of this version in the user's default editor. The copy is
    // written ONLY into a temp folder (never next to or over the real file) and chmod'd
    // read-only, so there is no way to mistake it for - or clobber - the live file. It's
    // named "<stem>.v<n>.<ext>" so the editor applies the right syntax highlighting.
    private func openVersion(_ version: SnapshotVersion) {
        guard let data = try? Data(contentsOf: version.url) else {
            // Unreadable: fall back to revealing the raw backup blob in Finder.
            NSWorkspace.shared.activateFileViewerSelecting([version.url])
            return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cortex-snapshot-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = dir.appendingPathComponent(previewFileName(for: version))
        // Remove any prior copy first (it may be read-only from a previous open).
        try? FileManager.default.removeItem(at: tmp)
        do {
            try data.write(to: tmp)
            try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: tmp.path)
            NSWorkspace.shared.open(tmp)
        } catch {
            NSWorkspace.shared.activateFileViewerSelecting([version.url])
        }
    }

    // "<stem>.v<n>.<ext>" so the original extension drives syntax highlighting.
    private func previewFileName(for version: SnapshotVersion) -> String {
        let ns = file.displayName as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        let safeStem = stem.isEmpty ? "snapshot" : stem
        return ext.isEmpty ? "\(safeStem).v\(version.version)" : "\(safeStem).v\(version.version).\(ext)"
    }
}

// MARK: - Helpers

/// A compact human file size ("3.2 KB"), for the version rows.
private func byteString(_ size: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
}
