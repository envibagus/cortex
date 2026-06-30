import Foundation
import CryptoKit

// MARK: - FileHistoryStore
//
// Backing store for the Workspace > Snapshots screen. Claude Code keeps versioned
// backups of every file it edits under ~/.claude/file-history, one folder per session,
// each holding `<hash>@v<n>` files whose contents are the file's raw bytes at that
// version. The hash is `sha256(absolute_file_path)[:16]` - so the snapshot filenames
// carry NO readable path on their own.
//
// This store reverses that: for each session it parses the transcript (reusing
// SessionDiffParser) to learn which absolute paths the session edited, hashes each one
// the same way, and matches it to the snapshot files. The result is a path-centric view
// where every backed-up version of a file - ACROSS every session that touched it - is
// gathered into one timeline you can diff and restore from. Hashes that can't be mapped
// (the transcript was pruned, or the edit came from a tool we don't track) still appear
// as "unrecognized" entries: browsable and diffable, but not restorable (we don't know
// where they'd go).
//
// Everything heavy (directory walk, transcript parse, hashing) runs off the main actor.

@MainActor
@Observable
final class FileHistoryStore {

    // Whether ~/.claude/file-history exists at all (drives the unavailable state).
    private(set) var rootExists = true
    // Whether the first scan has finished (drives the loading vs empty state).
    private(set) var didScan = false
    // The aggregated, path-centric files, newest-modified first.
    private(set) var files: [SnapshotFile] = []
    // Totals for the overview: distinct session folders + total snapshot files seen.
    private(set) var sessionCount = 0
    private(set) var snapshotCount = 0

    /// ~/.claude/file-history
    nonisolated static var historyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/file-history")
    }

    /// Re-scan file-history off-main using the caller's session metadata (used to resolve
    /// each session folder's hashes back to real paths + a human project / title label).
    func load(metas: [SnapshotSessionMeta]) async {
        let result = await Task.detached(priority: .userInitiated) {
            Self.scan(metas: metas)
        }.value
        rootExists = result.exists
        files = result.files
        sessionCount = result.sessionCount
        snapshotCount = result.snapshotCount
        didScan = true
    }

    // MARK: - Scan
    //
    // Walk every session folder under file-history, resolve its hashes to real paths via
    // the session transcript, and group versions by resolved path (across sessions).

    nonisolated static func scan(metas: [SnapshotSessionMeta]) -> ScanResult {
        let fm = FileManager.default
        let root = historyURL.path

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return ScanResult(exists: false, files: [], sessionCount: 0, snapshotCount: 0)
        }
        guard let sessionDirs = try? fm.contentsOfDirectory(atPath: root) else {
            return ScanResult(exists: true, files: [], sessionCount: 0, snapshotCount: 0)
        }

        // Session metadata keyed by session id, so each folder can find its project + title.
        let metaById = Dictionary(metas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Resolved files keyed by absolute path; unrecognized hashes keyed by session|hash.
        var resolved: [String: SnapshotFile] = [:]
        var unresolved: [String: SnapshotFile] = [:]
        var sessionCount = 0
        var snapshotCount = 0

        for sessionId in sessionDirs where !sessionId.hasPrefix(".") {
            let dir = (root as NSString).appendingPathComponent(sessionId)
            var childIsDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &childIsDir), childIsDir.boolValue else { continue }
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }

            let snapNames = names.filter { !$0.hasPrefix(".") && $0.contains("@v") }
            guard !snapNames.isEmpty else { continue }
            sessionCount += 1

            let meta = metaById[sessionId]
            let projectName = meta?.projectName ?? "Unknown project"
            let sessionLabel = meta?.displayTitle ?? String(sessionId.prefix(8))

            // Build hash -> real path from the transcript's Edit / Write / MultiEdit calls.
            var hashToPath: [String: String] = [:]
            if let url = meta?.transcriptURL {
                let diff = SessionDiffParser.parse(url: url)
                for file in diff.files { hashToPath[pathHash(file.path)] = file.path }
            }

            for name in snapNames {
                // name == "<hash>@v<n>"
                guard let at = name.range(of: "@v") else { continue }
                let hash = String(name[name.startIndex..<at.lowerBound])
                let version = Int(name[at.upperBound...]) ?? 0

                let filePath = (dir as NSString).appendingPathComponent(name)
                let attrs = try? fm.attributesOfItem(atPath: filePath)
                let modified = (attrs?[.modificationDate] as? Date) ?? .distantPast
                let size = (attrs?[.size] as? Int) ?? 0
                snapshotCount += 1

                let ver = SnapshotVersion(
                    url: URL(fileURLWithPath: filePath),
                    version: version,
                    sessionId: sessionId,
                    sessionLabel: sessionLabel,
                    projectName: projectName,
                    modified: modified,
                    size: size
                )

                if let path = hashToPath[hash] {
                    if resolved[path] == nil {
                        resolved[path] = SnapshotFile(
                            id: path,
                            path: path,
                            displayName: (path as NSString).lastPathComponent,
                            projectName: projectName,
                            versions: []
                        )
                    }
                    resolved[path]?.versions.append(ver)
                } else {
                    let key = "\(sessionId)|\(hash)"
                    if unresolved[key] == nil {
                        unresolved[key] = SnapshotFile(
                            id: "unrecognized:\(key)",
                            path: nil,
                            displayName: String(hash.prefix(10)) + "\u{2026}",
                            projectName: projectName,
                            versions: []
                        )
                    }
                    unresolved[key]?.versions.append(ver)
                }
            }
        }

        // Newest version first within each file; files ordered by their latest backup.
        func finalize(_ dict: [String: SnapshotFile]) -> [SnapshotFile] {
            dict.values.map { file in
                var copy = file
                copy.versions.sort { $0.modified > $1.modified }
                return copy
            }
        }
        var all = finalize(resolved) + finalize(unresolved)
        all.sort { $0.latestModified > $1.latestModified }

        return ScanResult(exists: true, files: all, sessionCount: sessionCount, snapshotCount: snapshotCount)
    }

    /// The snapshot filename hash: the first 16 hex chars of sha256(absolute path), the
    /// exact scheme Claude Code uses to name files under file-history.
    nonisolated static func pathHash(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Read a snapshot (or on-disk) file as UTF-8 text. nil means it's missing or binary -
    /// the caller treats nil as "no text diff to show".
    nonisolated static func readText(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - Scan result + session metadata

struct ScanResult: Sendable {
    var exists: Bool
    var files: [SnapshotFile]
    var sessionCount: Int
    var snapshotCount: Int
}

/// The minimum a session contributes to the scan: its id (matches the file-history
/// folder name), a project name + human title for labelling, and the transcript URL the
/// hash->path resolution reads. transcriptURL is nil for folders with no known session.
struct SnapshotSessionMeta: Sendable {
    var id: String
    var projectName: String
    var displayTitle: String
    var transcriptURL: URL?
}

// MARK: - Snapshot models

/// One file (identified by its resolved absolute path) and every backed-up version of it
/// across all sessions, newest first. `path` is nil for unrecognized hashes.
struct SnapshotFile: Identifiable, Sendable, Hashable {
    var id: String
    var path: String?
    var displayName: String
    var projectName: String
    var versions: [SnapshotVersion]

    var resolved: Bool { path != nil }
    var totalVersions: Int { versions.count }
    var latestModified: Date { versions.first?.modified ?? .distantPast }
}

/// One backed-up version: the on-disk snapshot file plus where + when it came from.
struct SnapshotVersion: Identifiable, Sendable, Hashable {
    var id: String { url.path }
    var url: URL
    var version: Int
    var sessionId: String
    var sessionLabel: String
    var projectName: String
    var modified: Date
    var size: Int
}

// MARK: - LineDiff
//
// A native line-level diff between two text blobs, built on Swift's CollectionDifference
// (no shell out). It reconstructs an ordered context/added/removed line list, then trims
// long unchanged runs to `context` lines around each change and splits the result into
// hunks - the same shape (DiffHunk / DiffLine) the Diffs page already renders, so the
// Snapshots diff reuses DiffHunkView verbatim. Capped so a huge file stays responsive.

enum LineDiff {

    /// Split a string into lines, dropping one trailing empty line so a blob ending in
    /// "\n" doesn't report a phantom final line (mirrors SessionDiffParser.lines).
    static func lines(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        var parts = s.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// Hunks describing how `old` becomes `new`. Empty when the two are identical.
    static func hunks(old: [String], new: [String], context: Int = 3, maxLines: Int = 1400) -> [DiffHunk] {
        if old.isEmpty && new.isEmpty { return [] }
        let diff = new.difference(from: old)
        if diff.isEmpty { return [] }

        // Index the changes by their offset in old (removals) and new (insertions).
        var removedOld = Set<Int>()
        var insertedNew: [Int: String] = [:]
        for change in diff {
            switch change {
            case let .remove(offset, _, _): removedOld.insert(offset)
            case let .insert(offset, element, _): insertedNew[offset] = element
            }
        }

        // Walk both sequences into one ordered context/removed/added line list.
        var merged: [DiffLine] = []
        var oi = 0, ni = 0
        while oi < old.count || ni < new.count {
            if oi < old.count, removedOld.contains(oi) {
                merged.append(DiffLine(kind: .removed, text: old[oi])); oi += 1
            } else if ni < new.count, let inserted = insertedNew[ni] {
                merged.append(DiffLine(kind: .added, text: inserted)); ni += 1
            } else if oi < old.count, ni < new.count {
                merged.append(DiffLine(kind: .context, text: old[oi])); oi += 1; ni += 1
            } else if oi < old.count {
                merged.append(DiffLine(kind: .removed, text: old[oi])); oi += 1
            } else {
                merged.append(DiffLine(kind: .added, text: insertedNew[ni] ?? new[ni])); ni += 1
            }
        }

        // Keep `context` lines around each change; collapse the rest into hunk gaps.
        let changed = merged.indices.filter { merged[$0].kind != .context }
        guard !changed.isEmpty else { return [] }

        var ranges: [(lo: Int, hi: Int)] = []
        for i in changed {
            let lo = Swift.max(0, i - context)
            let hi = Swift.min(merged.count - 1, i + context)
            if var last = ranges.last, lo <= last.hi + 1 {
                last.hi = Swift.max(last.hi, hi)
                ranges[ranges.count - 1] = last
            } else {
                ranges.append((lo, hi))
            }
        }

        var hunks: [DiffHunk] = []
        var budget = maxLines
        for range in ranges {
            guard budget > 0 else { break }
            var lineSlice: [DiffLine] = []
            var j = range.lo
            while j <= range.hi && budget > 0 {
                lineSlice.append(merged[j]); budget -= 1; j += 1
            }
            if !lineSlice.isEmpty { hunks.append(DiffHunk(lines: lineSlice)) }
        }
        return hunks
    }
}
