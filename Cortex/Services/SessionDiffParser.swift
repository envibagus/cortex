import Foundation

// MARK: - SessionDiffParser
//
// Reads a Claude Code JSONL transcript and extracts the file edits it performed:
// every Edit / MultiEdit / Write tool_use block, grouped by file, with the actual
// old/new text preserved so the Diffs page can render a real colored diff. This is
// the structured counterpart to ReplayParser.summarizeInput (which only renders a
// truncated text blob for a replay bubble); here we keep full line fidelity (capped
// generously per file) and compute per-file +added / -removed counts and hunks.
//
// Runs entirely off the main actor, line-by-line and defensively (like ReplayParser):
// a malformed line is skipped, never fatal.

enum SessionDiffParser {

    // Caps so a pathological multi-megabyte session stays responsive. Counts stay
    // exact regardless; only the RENDERED hunk text is capped.
    private static let maxLinesPerFile = 600
    private static let maxFiles = 200

    // MARK: Parse

    static func parse(url: URL) -> SessionDiff {
        // Accumulate per-file edits keyed by absolute path, preserving first-seen order.
        var byPath: [String: FileEdit] = [:]
        var order: [String] = []

        // Fold one logical edit (old -> new) into the file's running totals + hunks.
        func record(path: String, old: String, new: String, isWrite: Bool) {
            if byPath[path] == nil {
                guard order.count < maxFiles else { return }
                byPath[path] = FileEdit(path: path)
                order.append(path)
            }
            guard var file = byPath[path] else { return }

            file.editCount += 1
            if isWrite { file.isNewFile = true }

            // Removed = lines of old_string; added = lines of new_string. A Write has no
            // old text, so every content line counts as added.
            let removedLines = isWrite ? [] : Self.lines(old)
            let addedLines = Self.lines(new)
            file.removed += removedLines.count
            file.added += addedLines.count

            // Build the hunk (removed block, then added block) until the per-file cap.
            let used = file.hunks.reduce(0) { $0 + $1.lines.count }
            var budget = maxLinesPerFile - used
            if budget > 0 {
                var hunk: [DiffLine] = []
                for l in removedLines where budget > 0 { hunk.append(DiffLine(kind: .removed, text: l)); budget -= 1 }
                for l in addedLines where budget > 0 { hunk.append(DiffLine(kind: .added, text: l)); budget -= 1 }
                if !hunk.isEmpty { file.hunks.append(DiffHunk(lines: hunk)) }
            }
            byPath[path] = file
        }

        // Streamed line by line so a multi-megabyte transcript is never fully
        // resident in memory. An unopenable file yields the same empty diff the
        // whole-file read produced.
        JSONLines.forEachLine(in: url) { data in
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["type"] as? String) == "assistant",
                  let message = root["message"] as? [String: Any],
                  let blocks = message["content"] as? [Any] else { return true }

            for block in blocks {
                guard let bd = block as? [String: Any],
                      bd["type"] as? String == "tool_use",
                      let name = bd["name"] as? String,
                      let input = bd["input"] as? [String: Any] else { continue }

                switch name {
                case "Edit":
                    guard let path = input["file_path"] as? String else { continue }
                    record(path: path,
                           old: input["old_string"] as? String ?? "",
                           new: input["new_string"] as? String ?? "",
                           isWrite: false)
                case "MultiEdit":
                    guard let path = input["file_path"] as? String,
                          let edits = input["edits"] as? [[String: Any]] else { continue }
                    for e in edits {
                        record(path: path,
                               old: e["old_string"] as? String ?? "",
                               new: e["new_string"] as? String ?? "",
                               isWrite: false)
                    }
                case "Write":
                    guard let path = input["file_path"] as? String else { continue }
                    record(path: path, old: "",
                           new: input["content"] as? String ?? "",
                           isWrite: true)
                default:
                    break
                }
            }
            return true
        }

        return SessionDiff(files: order.compactMap { byPath[$0] })
    }

    // Split into lines, dropping a single trailing empty line so a block ending in "\n"
    // does not report a phantom extra line.
    private static func lines(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        var parts = s.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}

// MARK: - Diff models
//
// Structured edits for one session, derived from its transcript's Edit / MultiEdit /
// Write tool calls. Distinct from ReplayEvent (which is for the conversation replay):
// these carry the actual before/after text needed to paint a colored diff.

struct SessionDiff: Sendable, Equatable {
    var files: [FileEdit]

    var totalEdits: Int { files.reduce(0) { $0 + $1.editCount } }
    var totalAdded: Int { files.reduce(0) { $0 + $1.added } }
    var totalRemoved: Int { files.reduce(0) { $0 + $1.removed } }
    var fileCount: Int { files.count }
    var isEmpty: Bool { files.isEmpty }
}

struct FileEdit: Identifiable, Sendable, Equatable {
    var id: String { path }
    var path: String
    var editCount: Int = 0
    var added: Int = 0
    var removed: Int = 0
    var hunks: [DiffHunk] = []
    var isNewFile: Bool = false

    /// Last path component for a compact title; the full path shows as a caption.
    var fileName: String { (path as NSString).lastPathComponent }
}

struct DiffHunk: Identifiable, Sendable, Equatable {
    var id = UUID()
    var lines: [DiffLine]
}

struct DiffLine: Identifiable, Sendable, Equatable {
    var id = UUID()
    var kind: Kind
    var text: String

    enum Kind: Sendable, Equatable { case context, added, removed }
}
