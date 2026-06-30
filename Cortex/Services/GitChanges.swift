import SwiftUI
import Foundation

// MARK: - Git working-tree changes
//
// Reads a local repo's UNCOMMITTED changes on demand for the Diffs > Working Tree
// browser. Two cheap passes give the file list (`git status` + `git diff --numstat`);
// the unified diff for a single file is fetched lazily, only when its row is expanded.
// Everything shells out to `git`, so callers must run these off the main actor.

enum GitChanges {
    // MARK: File list

    /// Every uncommitted change in `repoPath` (staged + unstaged + untracked), each with
    /// its status and +added / -removed counts. One `git status` + one `git diff --numstat`.
    nonisolated static func changedFiles(repoPath: String) -> [GitFileChange] {
        guard let status = git(repoPath, ["status", "--porcelain=v1", "--untracked-files=all"])?.stdout,
              !status.isEmpty else { return [] }

        // +/- per tracked file (working tree vs HEAD, including staged), keyed by path.
        var stats: [String: (added: Int, removed: Int, binary: Bool)] = [:]
        if let numstat = git(repoPath, ["diff", "--numstat", "HEAD"])?.stdout {
            for line in numstat.split(separator: "\n") {
                let cols = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard cols.count == 3 else { continue }
                let binary = (cols[0] == "-" && cols[1] == "-")
                stats[cols[2]] = (Int(cols[0]) ?? 0, Int(cols[1]) ?? 0, binary)
            }
        }

        var out: [GitFileChange] = []
        for raw in status.split(separator: "\n", omittingEmptySubsequences: true) {
            let chars = Array(raw)
            guard chars.count >= 4 else { continue }       // "XY path"
            let x = chars[0], y = chars[1]
            var pathField = String(chars[3...])
            var oldPath: String?

            // Renames / copies render as "orig -> new".
            if let r = pathField.range(of: " -> ") {
                oldPath = unquote(String(pathField[..<r.lowerBound]))
                pathField = String(pathField[r.upperBound...])
            }
            let path = unquote(pathField)
            let s = stats[path]
            out.append(GitFileChange(path: path, oldPath: oldPath,
                                     status: GitChangeStatus(x: x, y: y),
                                     added: s?.added ?? 0, removed: s?.removed ?? 0,
                                     isBinary: s?.binary ?? false))
        }
        return out.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    // MARK: Single-file diff (lazy)

    private static let maxLines = 800

    /// The unified diff of one changed file as renderable hunks. Untracked files diff
    /// against /dev/null so they render as all-added; binary files return no hunks.
    nonisolated static func diffHunks(repoPath: String, change: GitFileChange) -> [DiffHunk] {
        if change.isBinary { return [] }
        let patch: String?
        if change.status == .untracked {
            // --no-index exits non-zero when files differ, so read stdout regardless of ok.
            patch = git(repoPath, ["diff", "--no-index", "/dev/null", change.path])?.stdout
        } else {
            patch = git(repoPath, ["diff", "HEAD", "--", change.path])?.stdout
        }
        guard let patch, !patch.isEmpty else { return [] }
        return unifiedDiffToHunks(patch)
    }

    // MARK: Unified-diff parsing

    /// Convert raw `git diff` output into DiffHunks (reusing the Diffs renderer). File
    /// headers and @@ markers are dropped; each @@ block becomes one hunk. Capped so a
    /// huge file can't stall the UI.
    nonisolated static func unifiedDiffToHunks(_ patch: String) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var current: [DiffLine] = []
        var inHunk = false
        var total = 0

        func flush() { if !current.isEmpty { hunks.append(DiffHunk(lines: current)); current = [] } }

        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if total >= maxLines { break }
            let line = String(raw)
            if line.hasPrefix("@@") { flush(); inHunk = true; continue }   // new hunk
            if line.hasPrefix("diff --git") { flush(); inHunk = false; continue } // next file
            guard inHunk else { continue }                                 // skip ---/+++ headers
            if line.hasPrefix("+") {
                current.append(DiffLine(kind: .added, text: String(line.dropFirst()))); total += 1
            } else if line.hasPrefix("-") {
                current.append(DiffLine(kind: .removed, text: String(line.dropFirst()))); total += 1
            } else if line.hasPrefix(" ") {
                current.append(DiffLine(kind: .context, text: String(line.dropFirst()))); total += 1
            } // ignore "\ No newline at end of file" + blank separators
        }
        flush()
        return hunks
    }

    // MARK: Helpers

    private nonisolated static func git(_ repoPath: String, _ args: [String]) -> Shell.Result? {
        Shell.run(tool: "git", ["-C", repoPath] + args)
    }

    // Strip git's C-style double-quoting from a porcelain path (spaces / special chars).
    private nonisolated static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") {
            t = String(t.dropFirst().dropLast())
            t = t.replacingOccurrences(of: "\\\"", with: "\"")
                 .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return t
    }
}

// MARK: - One changed file

struct GitFileChange: Identifiable, Sendable, Hashable {
    var id: String { status.rawValue + ":" + path }
    var path: String          // repo-relative path (the new path for renames)
    var oldPath: String? = nil
    var status: GitChangeStatus
    var added: Int = 0
    var removed: Int = 0
    var isBinary: Bool = false

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
}

// MARK: - Change status (derived from porcelain's XY columns)

enum GitChangeStatus: String, Sendable, Hashable {
    case modified, added, deleted, renamed, copied, typeChanged, untracked, unmerged, unknown

    init(x: Character, y: Character) {
        if x == "?" || y == "?" { self = .untracked; return }
        if x == "U" || y == "U" { self = .unmerged; return }
        // Prefer the meaningful (non-space) code; the index column wins when both are set.
        let c = x != " " ? x : y
        switch c {
        case "M": self = .modified
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type changed"
        case .untracked: "Untracked"
        case .unmerged: "Conflicted"
        case .unknown: "Changed"
        }
    }

    // A single-letter tag for the compact status chip.
    var tag: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .untracked: "?"
        case .unmerged: "!"
        case .unknown: "\u{2022}"
        }
    }

    var tint: Color {
        switch self {
        case .added, .untracked: Theme.green
        case .modified, .typeChanged: Theme.orange
        case .deleted: .red
        case .renamed, .copied: Theme.blue
        case .unmerged: Theme.purple
        case .unknown: Theme.textSecondary
        }
    }
}
