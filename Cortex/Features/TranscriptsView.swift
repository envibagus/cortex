import SwiftUI

// MARK: - SessionTranscriptView
//
// The raw transcript reader, embedded as the "Transcript" tab of a session's detail
// (Sessions page). It reads the selected session's `fileURL` from disk, parses the
// JSONL into role-tagged turns on a background task, and renders each turn in its own
// native GroupBox. There is no title/metadata header here: the hosting SessionDetail
// already shows the project name + Summary stats, so this tab is just the turns.
// Very large or binary payloads are skipped / truncated so the view stays responsive
// on multi-megabyte logs. (This used to be a standalone Transcripts page; it now lives
// inside Sessions so there is one place to read a session.)

struct SessionTranscriptView: View {
    let session: ClaudeSession

    // Parsing state: nil while loading, then the parsed turns (possibly empty).
    @State private var turns: [TurnLine]?
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .task(id: session.id) { await load() }
    }

    // MARK: Content (loading / error / turns)

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView(
                "Could Not Read Transcript",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
            .frame(maxWidth: .infinity)
        } else if let turns {
            if turns.isEmpty {
                ContentUnavailableView(
                    "No Readable Turns",
                    systemImage: "doc.plaintext",
                    description: Text("This transcript has no user or assistant lines to show.")
                )
                .frame(maxWidth: .infinity)
            } else {
                ForEach(turns) { turn in
                    TurnView(turn: turn)
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Parsing the raw JSONL from disk\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
        }
    }

    // Read the file off the main actor, then publish the parsed turns.
    private func load() async {
        turns = nil
        loadError = nil
        let url = session.fileURL
        let result = await Task.detached(priority: .userInitiated) {
            TranscriptParser.parse(url: url)
        }.value
        switch result {
        case .success(let parsed): turns = parsed
        case .failure(let error): loadError = error.message
        }
    }
}

// MARK: - Turn view
//
// One parsed transcript turn in a native GroupBox: the role + optional timestamp
// form the GroupBox label, and the preview text fills the body in selectable
// monospaced text.

private struct TurnView: View {
    let turn: TurnLine

    var body: some View {
        GroupBox {
            Text(turn.preview)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        } label: {
            HStack(spacing: 8) {
                // Role label, color-coded by speaker.
                Label(turn.role.capitalized, systemImage: roleIcon)
                    .font(.headline)
                    .foregroundStyle(roleTint)
                Spacer(minLength: 8)
                if let stamp = turn.timestamp {
                    Text(stamp.formatted(date: .omitted, time: .standard))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // Map a role to a consistent SF Symbol.
    private var roleIcon: String {
        switch turn.role.lowercased() {
        case "user": "person"
        case "assistant": "sparkles"
        case "system": "gearshape"
        case "summary": "text.alignleft"
        default: "circle"
        }
    }

    // Map a role to a consistent native tint. Role glyphs are chrome (grayscale);
    // the assistant keeps the Claude coral as its brand identity.
    private var roleTint: Color {
        switch turn.role.lowercased() {
        case "assistant": Theme.claude
        default: .secondary
        }
    }
}

// MARK: - Parsed turn

private struct TurnLine: Identifiable {
    let id: Int
    let role: String
    let timestamp: Date?
    let preview: String
}

// MARK: - Transcript parser
//
// Reads a JSONL transcript and turns each line into a `TurnLine`. Parsing is
// lazy and defensive: each line is decoded independently, oversized payloads are
// truncated to a short preview, and any line that fails to decode (or is binary /
// junk) is skipped. The whole pass runs off the main actor.

private enum TranscriptParser {
    // A human-readable parse failure. `Result.Failure` must be an `Error`, so we
    // wrap the message string in a tiny error type rather than failing with a bare
    // `String` (which does not conform to `Error`).
    struct ParseError: Error {
        let message: String
    }

    // Cap on a single rendered preview so a giant tool result never blocks the UI.
    private static let previewLimit = 1200
    // Cap on total rows so a very long transcript stays responsive.
    private static let maxRows = 4000

    // A minimal shape covering the fields we render. Content is left as raw JSON
    // so we can flatten Claude's mixed string / array message bodies ourselves.
    private struct Line: Decodable {
        var type: String?
        var timestamp: String?
        var message: Message?
        struct Message: Decodable { var role: String? }
    }

    static func parse(url: URL) -> Result<[TurnLine], ParseError> {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return .failure(ParseError(message: "The transcript file could not be read as text. It may have moved or be binary."))
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        let decoder = JSONDecoder()

        var out: [TurnLine] = []
        var index = 0

        for lineStr in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            if out.count >= maxRows { break }
            guard let data = lineStr.data(using: .utf8) else { continue }

            // Decode the structured fields (role + timestamp). Skip non-JSON junk.
            guard let line = try? decoder.decode(Line.self, from: data) else { continue }

            // Only render conversational turns; skip housekeeping line types.
            let role = (line.message?.role ?? line.type ?? "").trimmingCharacters(in: .whitespaces)
            guard ["user", "assistant", "system", "summary"].contains(role.lowercased()) else { continue }

            // Pull a flattened text preview from the raw JSON object so we handle
            // both plain-string and array-of-blocks message bodies.
            let preview = extractPreview(from: data)
            guard !preview.isEmpty else { continue }

            let stamp = line.timestamp.flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            out.append(TurnLine(id: index, role: role, timestamp: stamp, preview: preview))
            index += 1
        }
        return .success(out)
    }

    // Flatten a transcript line's message content into a short plain-text preview.
    // Claude writes `message.content` as either a string or an array of typed
    // blocks ({type:"text",text:...} / {type:"tool_use"} / {type:"tool_result"}).
    private static func extractPreview(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }

        // Prefer message.content; fall back to a top-level summary or text field.
        let message = root["message"] as? [String: Any]
        let content = message?["content"] ?? root["summary"] ?? root["text"]

        let text = flatten(content)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.count > previewLimit {
            return String(trimmed.prefix(previewLimit)) + " \u{2026}"
        }
        return trimmed
    }

    // Recursively reduce JSON content into readable text, labelling tool blocks.
    private static func flatten(_ value: Any?) -> String {
        switch value {
        case let s as String:
            return s
        case let arr as [Any]:
            return arr.map { flatten($0) }.filter { !$0.isEmpty }.joined(separator: "\n")
        case let dict as [String: Any]:
            let type = (dict["type"] as? String) ?? ""
            switch type {
            case "text":
                return (dict["text"] as? String) ?? ""
            case "tool_use":
                let name = (dict["name"] as? String) ?? "tool"
                return "[tool_use: \(name)]"
            case "tool_result":
                let inner = flatten(dict["content"])
                return inner.isEmpty ? "[tool_result]" : "[tool_result] \(inner)"
            case "thinking":
                let t = (dict["thinking"] as? String) ?? ""
                return t.isEmpty ? "" : "[thinking] \(t)"
            default:
                // Unknown block: try its likeliest text-bearing field.
                return (dict["text"] as? String) ?? (dict["content"] as? String) ?? ""
            }
        default:
            return ""
        }
    }
}
