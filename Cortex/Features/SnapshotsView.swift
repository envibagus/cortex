import SwiftUI
import AppKit

// MARK: - SnapshotsView
//
// The Workspace > Snapshots screen, rebuilt with STOCK native containers. Claude
// Code keeps versioned file snapshots under ~/.claude/file-history, one
// subdirectory per session, each holding `<hash>@v<n>` snapshot files. This view
// browses that directory with FileManager and lists each entry in a native `List`
// with its snapshot count and most-recent modified date, under a summary GroupBox
// of totals. Tapping a row reveals the folder in Finder.
//
// When ~/.claude/file-history is absent, a native ContentUnavailableView explains
// what file-history snapshots are and where they live. No CLI, no parsing: just an
// honest directory read.

struct SnapshotsView: View {
    @Environment(AppModel.self) private var model

    // The scanned entries, loaded on appear.
    @State private var entries: [SnapshotEntry] = []
    // Whether the file-history directory exists at all.
    @State private var directoryExists = true
    // Whether the initial scan has completed.
    @State private var didScan = false

    // ~/.claude/file-history
    private static var historyPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/file-history").path
    }

    var body: some View {
        Group {
            if !directoryExists {
                // No file-history directory: explain the feature honestly.
                ContentUnavailableView(
                    "No File-History Yet",
                    systemImage: "camera",
                    description: Text("Claude Code stores versioned snapshots of files it edits under ~/.claude/file-history, one folder per session. That directory does not exist yet, so there is nothing to browse. It will appear after Claude Code edits files in a session.")
                )
            } else if entries.isEmpty {
                // Directory exists but holds nothing (or scan not done).
                ContentUnavailableView(
                    didScan ? "No Snapshots" : "Reading File-History",
                    systemImage: "camera",
                    description: Text(didScan
                        ? "The file-history directory is present but contains no session snapshots."
                        : "Scanning ~/.claude/file-history\u{2026}")
                )
            } else {
                // Summary GroupBox + the per-session native List.
                snapshotList
            }
        }
        .navigationTitle("Snapshots")
        .onAppear(perform: scan)
    }

    // MARK: - Snapshot list (summary header + native List)

    private var snapshotList: some View {
        List {
            // Summary section: totals as native LabeledContent rows.
            Section {
                LabeledContent("Sessions tracked", value: "\(entries.count)")
                LabeledContent("Total snapshots", value: "\(totalSnapshots)")
            } header: {
                Text("Overview")
            }

            // Per-session snapshot rows.
            Section {
                ForEach(entries) { entry in
                    SnapshotRow(entry: entry)
                }
            } header: {
                Text("Sessions")
            } footer: {
                Text("One folder per Claude Code session under ~/.claude/file-history. Select a row to reveal it in Finder.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var totalSnapshots: Int { entries.reduce(0) { $0 + $1.snapshotCount } }

    // MARK: Scan
    //
    // Read each subdirectory of file-history, counting its `@v` snapshot files and
    // finding the newest modified date among them. Runs off the main actor.

    private func scan() {
        guard !didScan else { return }
        let path = Self.historyPath
        Task {
            let scanned = await Task.detached(priority: .userInitiated) {
                Self.readEntries(at: path)
            }.value
            directoryExists = scanned.exists
            entries = scanned.entries
            didScan = true
        }
    }

    // Off-actor directory read. Returns whether the root exists and one entry per
    // session subdirectory, sorted newest-modified first.
    nonisolated private static func readEntries(at path: String) -> (exists: Bool, entries: [SnapshotEntry]) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return (false, [])
        }
        guard let sessionDirs = try? fm.contentsOfDirectory(atPath: path) else {
            return (true, [])
        }

        var result: [SnapshotEntry] = []
        for sessionId in sessionDirs where !sessionId.hasPrefix(".") {
            let sessionPath = (path as NSString).appendingPathComponent(sessionId)
            var childIsDir: ObjCBool = false
            guard fm.fileExists(atPath: sessionPath, isDirectory: &childIsDir), childIsDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: sessionPath) else { continue }

            var snapshotCount = 0
            var newest: Date?
            for file in files where !file.hasPrefix(".") {
                snapshotCount += 1
                let filePath = (sessionPath as NSString).appendingPathComponent(file)
                if let attrs = try? fm.attributesOfItem(atPath: filePath),
                   let mod = attrs[.modificationDate] as? Date {
                    if newest == nil || mod > newest! { newest = mod }
                }
            }

            // Fall back to the directory's own modified date if it had no files.
            if newest == nil, let attrs = try? fm.attributesOfItem(atPath: sessionPath) {
                newest = attrs[.modificationDate] as? Date
            }

            result.append(SnapshotEntry(
                id: sessionId,
                path: sessionPath,
                snapshotCount: snapshotCount,
                modified: newest ?? .distantPast
            ))
        }

        return (true, result.sorted { $0.modified > $1.modified })
    }
}

// MARK: - Snapshot entry model
//
// One session's file-history folder: its id (session UUID), path, snapshot file
// count, and newest modified date.

private struct SnapshotEntry: Identifiable {
    let id: String
    let path: String
    let snapshotCount: Int
    let modified: Date
}

// MARK: - Snapshot row
//
// One session folder in the native List: a camera glyph, the (shortened) session
// id over its snapshot count, and the relative modified time. The whole row
// reveals the folder in Finder.

private struct SnapshotRow: View {
    let entry: SnapshotEntry

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "camera")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(shortId)
                        .font(.body.monospaced())
                        .lineLimit(1)
                    Text("\(entry.snapshotCount) snapshot\(entry.snapshotCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(Fmt.relative(entry.modified == .distantPast ? nil : entry.modified))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.path)
    }

    // Show the leading chunk of the session UUID for a compact label.
    private var shortId: String {
        entry.id.count > 13 ? String(entry.id.prefix(13)) + "\u{2026}" : entry.id
    }
}
