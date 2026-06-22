import SwiftUI

// MARK: - SessionReplayView
//
// An immersive, lightweight "replay" of a single Claude Code session: the whole
// conversation rebuilt from the raw JSONL transcript into a smooth, scrollable
// feed of role-tagged bubbles (user / assistant / thinking / tool call / tool
// result), with a color-coded minimap on the right that identifies every message
// at a glance and doubles as a scrubber, plus a bottom transport bar that plays
// the session back message by message.
//
// One piece of state drives everything: `currentID`, the index of the focused
// event. It is bound to the scroll view's `scrollPosition(id:)`, the transport
// slider, and the minimap, so scrolling, scrubbing, clicking the bar, and
// pressing play all stay in lockstep. Parsing runs off the main actor; the view
// reads only the passed-in `ClaudeSession`, so it is fully decoupled from AppModel
// and cheap to present as a sheet.

struct SessionReplayView: View {
    let session: ClaudeSession
    // When embedded inside another pane (the Sessions detail), drop the sheet-only
    // header + close button; the host already titles the pane.
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss

    // Parsed conversation: nil while loading, then the events (possibly empty).
    @State private var events: [ReplayEvent]?
    @State private var loadError: String?

    // The focused event index. Shared by the scroll position, the slider, and the
    // minimap so all three move together.
    @State private var currentID: Int?
    // The event the pointer is hovering on the minimap (drives the transport label
    // without moving the playhead). Falls back to `currentID` when not hovering.
    @State private var hoverID: Int?

    // Playback transport.
    @State private var isPlaying = false
    @State private var speed: ReplaySpeed = .normal
    // Feed order: false = oldest-first (chronological), true = newest-first.
    @State private var reversed = false

    var body: some View {
        VStack(spacing: 0) {
            // Top chrome (sheet only): title, model/size/duration, legend, close.
            if !embedded {
                ReplayHeaderBar(session: session,
                                eventCount: events?.count ?? 0,
                                onClose: { dismiss() })
                Divider().overlay(Theme.stroke)
            }

            content
        }
        .background(Theme.canvas)
        .task(id: session.id) { await load() }
        // Restart the playback loop whenever play toggles or the speed changes.
        .task(id: playbackToken) { await playbackLoop() }
    }

    // MARK: Body (loading / error / replay)

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView("Could Not Read Session", systemImage: "exclamationmark.triangle",
                                   description: Text(loadError))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let events {
            if events.isEmpty {
                ContentUnavailableView("Nothing to Replay", systemImage: "play.slash",
                                       description: Text("This transcript has no readable conversation turns."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    // Transcript feed + color-coded minimap/scrubber, with the order
                    // toggle floating at the top (above the feed, clear of the transport).
                    HStack(spacing: 0) {
                        ReplayTranscript(events: events, currentID: $currentID, reversed: reversed)
                        Divider().overlay(Theme.stroke)
                        ReplayMinimap(events: events, currentID: $currentID, hoverID: $hoverID, reversed: reversed)
                    }
                    .overlay(alignment: .topTrailing) {
                        ReplayOrderToggle(reversed: $reversed)
                            .padding(.top, 12)
                            .padding(.trailing, 44)   // clear the 28pt minimap + divider
                    }
                    // No bottom transport bar: scroll the feed to read, and tap/drag the
                    // color minimap on the right to scrub. The order toggle floats above.
                }
            }
        } else {
            // First parse from disk.
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Reading the session transcript\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // The event whose detail the transport bar describes: hovered on the minimap if
    // any, otherwise the playhead.
    private var focusEvent: ReplayEvent? {
        guard let events, !events.isEmpty else { return nil }
        let id = hoverID ?? currentID ?? 0
        guard id >= 0 && id < events.count else { return nil }
        return events[id]
    }

    // MARK: Loading

    private func load() async {
        events = nil
        loadError = nil
        isPlaying = false
        let url = session.fileURL
        let result = await Task.detached(priority: .userInitiated) {
            ReplayParser.parse(url: url)
        }.value
        switch result {
        case .success(let parsed):
            events = parsed
            currentID = parsed.first?.id
        case .failure(let error):
            loadError = error.message
        }
    }

    // MARK: Playback

    // Identity for the playback `.task`: changing play state or speed restarts the
    // loop (which resumes from wherever the playhead currently sits).
    private var playbackToken: String { "\(isPlaying)|\(speed.rawValue)" }

    private func playbackLoop() async {
        guard isPlaying, let events, !events.isEmpty else { return }
        let interval = speed.interval
        // Advance one event per tick, scrolling it to center, until the end.
        while !Task.isCancelled && isPlaying {
            let next = (currentID ?? -1) + 1
            if next >= events.count { isPlaying = false; break }
            withAnimation(.easeInOut(duration: min(0.45, interval * 0.6))) {
                currentID = next
            }
            do { try await Task.sleep(for: .seconds(interval)) }
            catch { return } // cancelled
        }
    }

    private func togglePlay() {
        guard let events, !events.isEmpty else { return }
        if !isPlaying, (currentID ?? 0) >= events.count - 1 {
            // At the end: restart from the top.
            withAnimation(.easeInOut(duration: 0.3)) { currentID = 0 }
        }
        isPlaying.toggle()
    }

    // Step the playhead by `delta` (clamped), pausing playback.
    private func step(_ delta: Int) {
        guard let events, !events.isEmpty else { return }
        isPlaying = false
        let target = min(max((currentID ?? 0) + delta, 0), events.count - 1)
        withAnimation(.easeInOut(duration: 0.3)) { currentID = target }
    }
}

// MARK: - Replay header bar
//
// The sheet's own top chrome (a sheet has no toolbar): a play glyph + project
// title, a metadata subline, the role legend, and a close button.

private struct ReplayHeaderBar: View {
    let session: ClaudeSession
    let eventCount: Int
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.projectName)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            ReplayLegend()

            // Close.
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close replay")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let primary = session.primaryModel { parts.append(CostService.displayName(primary)) }
        parts.append("\(eventCount) \(eventCount == 1 ? "event" : "events")")
        parts.append(durationText)
        parts.append(session.startedAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: "  \u{00B7}  ")
    }

    private var durationText: String {
        let total = Int(session.duration)
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }
}

// MARK: - Role legend
//
// A compact key for the minimap colors, so the bar is decodable at a glance.

private struct ReplayLegend: View {
    private let items: [ReplayEvent.Kind] = [.user, .assistant, .thinking, .toolUse, .toolResult]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(items, id: \.self) { kind in
                HStack(spacing: 5) {
                    Circle().fill(kind.color).frame(width: 7, height: 7)
                    Text(kind.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Transcript feed
//
// A lazily-rendered, scrollable column of conversation bubbles. The scroll
// position is bound to `currentID` (anchored to center) so it both tracks manual
// scrolling and animates to the playhead when the slider / minimap / playback move
// it. `scrollTargetLayout()` is what lets `scrollPosition(id:)` resolve per-row.

private struct ReplayTranscript: View {
    let events: [ReplayEvent]
    @Binding var currentID: Int?
    var reversed: Bool = false

    var body: some View {
        // Newest-first just flips the visual order; each row keeps its event.id, so the
        // scroll-to-playhead binding (scrollPosition(id:)) still resolves correctly.
        let ordered = reversed ? Array(events.reversed()) : events
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(ordered) { event in
                    ReplayBubble(event: event, isCurrent: event.id == currentID)
                }
            }
            .scrollTargetLayout()
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition(id: $currentID, anchor: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

// MARK: - Conversation bubble
//
// One replay event as a native card with a kind-colored accent stripe and header.
// Text turns render as full GitHub-flavored markdown; thinking and tool blocks
// render as collapsible monospaced text. The focused (playhead) bubble is raised
// and outlined in its kind color so the eye follows the replay.

private struct ReplayBubble: View {
    let event: ReplayEvent
    let isCurrent: Bool
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Kind-colored accent stripe.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(event.kind.color.opacity(isCurrent ? 1 : 0.5))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 8) {
                header
                bodyView
                if showToggle {
                    Button(expanded ? "Show less" : "Show more") {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(isCurrent ? Theme.cardRaised : Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(isCurrent ? event.kind.color.opacity(0.6) : Theme.stroke,
                              lineWidth: isCurrent ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.2), value: isCurrent)
    }

    // Role glyph + label, optional tool name, trailing timestamp.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: event.kind.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(event.kind.color)
            Text(event.kind.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(event.kind.color)
            if let title = event.title, !title.isEmpty {
                Text(title)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let ts = event.timestamp {
                Text(ts.formatted(date: .omitted, time: .standard))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        switch event.kind {
        case .user, .assistant:
            // Rich markdown for the conversational turns.
            MarkdownText(markdown: event.body)
        case .thinking:
            Text(event.body)
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .toolUse:
            Text(event.body.isEmpty ? "(no input)" : event.body)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .toolResult:
            Text(event.body)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .system, .summary:
            Text(event.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Collapsed line cap per kind (nil == never truncate, e.g. markdown turns).
    private var collapsedLimit: Int? {
        switch event.kind {
        case .thinking: 6
        case .toolUse: 4
        case .toolResult: 8
        default: nil
        }
    }

    // Show the expand toggle only when the collapsed cap is likely to clip.
    private var showToggle: Bool {
        guard let limit = collapsedLimit else { return false }
        let lines = event.body.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) } + 1
        return lines > limit || event.body.count > limit * 80
    }
}

// MARK: - Minimap / scrubber
//
// A single Canvas paints one thin color-coded tick per event (so even a
// multi-thousand-line session stays a cheap, single-draw column), with a bright
// marker on the playhead. Tap or drag anywhere on the bar to scrub; hovering
// reports the event under the pointer to the transport bar.

private struct ReplayMinimap: View {
    let events: [ReplayEvent]
    @Binding var currentID: Int?
    @Binding var hoverID: Int?
    var reversed: Bool = false

    var body: some View {
        GeometryReader { geo in
            let h = max(geo.size.height, 1)
            let n = max(events.count, 1)

            Canvas { ctx, size in
                let rowH = size.height / CGFloat(n)
                // Ticks. In reversed (newest-first) mode the column paints top-down from
                // the last event so it stays aligned with the reversed feed.
                for (i, event) in events.enumerated() {
                    let displayRow = reversed ? (events.count - 1 - i) : i
                    let y = CGFloat(displayRow) * rowH
                    let inset = size.width * 0.3
                    let rect = CGRect(x: inset, y: y + (rowH > 3 ? 0.5 : 0),
                                      width: size.width - inset * 2,
                                      height: max(rowH - (rowH > 3 ? 1 : 0), 0.75))
                    let isCurrent = currentID == i
                    ctx.fill(Path(roundedRect: rect, cornerRadius: min(2, rect.width / 2)),
                             with: .color(event.kind.color.opacity(isCurrent ? 1 : 0.55)))
                }
                // Playhead marker: a full-width bright line at the current event's row.
                if let c = currentID, c >= 0, c < n {
                    let displayRow = reversed ? (n - 1 - c) : c
                    let y = (CGFloat(displayRow) + 0.5) * rowH
                    let line = CGRect(x: 0, y: y - 0.75, width: size.width, height: 1.5)
                    ctx.fill(Path(line), with: .color(Theme.textPrimary.opacity(0.85)))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let idx = index(forY: value.location.y, height: h, count: n)
                        if idx != currentID {
                            withAnimation(.easeOut(duration: 0.15)) { currentID = idx }
                        }
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverID = index(forY: point.y, height: h, count: n)
                case .ended: hoverID = nil
                }
            }
        }
        .frame(width: 28)
        .background(Theme.canvas)
    }

    private func index(forY y: CGFloat, height: CGFloat, count: Int) -> Int {
        let raw = Int((y / height) * CGFloat(count))
        let clamped = min(max(raw, 0), count - 1)
        return reversed ? (count - 1 - clamped) : clamped
    }
}

// MARK: - Transport bar
//
// The bottom controls: a live label for the focused event (hovered-or-playhead),
// step-back / play-pause / step-forward, a scrubber slider, the position counter,
// and a speed switch. The slider binds to the same `currentID` as the scroll view,
// so dragging it scrubs the transcript and playback drags it along.

private struct ReplayControlBar: View {
    let events: [ReplayEvent]
    @Binding var currentID: Int?
    let focusEvent: ReplayEvent?
    @Binding var isPlaying: Bool
    let onPlayToggle: () -> Void
    let onStep: (Int) -> Void

    private var count: Int { events.count }
    private var position: Int { (currentID ?? 0) + 1 }

    var body: some View {
        HStack(spacing: 16) {
            // Focused-event identity (updates on hover + scrub + playback).
            HStack(spacing: 7) {
                if let event = focusEvent {
                    Image(systemName: event.kind.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(event.kind.color)
                    Text(event.title?.isEmpty == false ? "\(event.kind.label) \u{00B7} \(event.title!)" : event.kind.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            .frame(width: 180, alignment: .leading)

            // Transport buttons.
            HStack(spacing: 6) {
                Button { onStep(-1) } label: {
                    Image(systemName: "backward.frame.fill")
                }
                .help("Previous message")
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button(action: onPlayToggle) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .help(isPlaying ? "Pause" : "Play")
                .keyboardShortcut(.space, modifiers: [])

                Button { onStep(1) } label: {
                    Image(systemName: "forward.frame.fill")
                }
                .help("Next message")
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            // Scrubber.
            Slider(
                value: Binding(
                    get: { Double(currentID ?? 0) },
                    set: { newValue in
                        let idx = min(max(Int(newValue.rounded()), 0), max(count - 1, 0))
                        if idx != currentID { currentID = idx }
                    }
                ),
                in: 0...Double(max(count - 1, 1))
            )
            .controlSize(.small)

            // Position counter.
            Text("\(position) / \(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - Order toggle
//
// The newest-first / oldest-first switch, floated above the feed (not crammed into
// the transport). A plain bordered button with an arrow + short label.

private struct ReplayOrderToggle: View {
    @Binding var reversed: Bool

    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.18)) { reversed.toggle() } } label: {
            Label(reversed ? "Newest first" : "Oldest first",
                  systemImage: reversed ? "arrow.up" : "arrow.down")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Toggle conversation order")
    }
}

// MARK: - Playback speed

private enum ReplaySpeed: String, CaseIterable, Hashable {
    case slow = "0.5\u{00D7}"
    case normal = "1\u{00D7}"
    case fast = "2\u{00D7}"

    /// Seconds the playhead rests on each event before advancing.
    var interval: Double {
        switch self {
        case .slow: 2.0
        case .normal: 1.0
        case .fast: 0.5
        }
    }
}

// MARK: - Replay event model

struct ReplayEvent: Identifiable, Equatable {
    let id: Int             // sequential index == position in the feed
    let kind: Kind
    let timestamp: Date?
    let title: String?      // e.g. the tool name for a tool call
    let body: String        // markdown (text turns) or plain text
    let isMarkdown: Bool

    enum Kind: String, Hashable {
        case user, assistant, thinking, toolUse, toolResult, system, summary

        var label: String {
            switch self {
            case .user: "You"
            case .assistant: "Claude"
            case .thinking: "Thinking"
            case .toolUse: "Tool"
            case .toolResult: "Result"
            case .system: "System"
            case .summary: "Summary"
            }
        }

        var icon: String {
            switch self {
            case .user: "person.fill"
            case .assistant: "asterisk"
            case .thinking: "brain"
            case .toolUse: "wrench.and.screwdriver.fill"
            case .toolResult: "arrow.turn.down.right"
            case .system: "gearshape.fill"
            case .summary: "text.quote"
            }
        }

        var color: Color {
            switch self {
            case .user: Theme.blue
            case .assistant: Theme.claude
            case .thinking: Theme.purple
            case .toolUse: Theme.green
            case .toolResult: Color.secondary
            case .system: Theme.orange
            case .summary: Color.secondary
            }
        }
    }
}

// MARK: - Replay parser
//
// Reads a JSONL transcript and expands it into block-level `ReplayEvent`s: a
// single assistant line that mixes prose, a thinking block, and tool calls becomes
// several events, so the minimap and feed distinguish them. Parsing is defensive
// (each line decoded independently, oversized bodies truncated, junk skipped) and
// runs entirely off the main actor.

// Internal (not private): SummaryService reuses this to extract a session's user
// prompts for the on-device AI summary.
enum ReplayParser {
    struct Failure: Error { let message: String }

    // Caps so a pathological multi-megabyte transcript stays responsive.
    private static let maxEvents = 6000
    private static let bodyLimit = 6000
    private static let valueLimit = 400

    static func parse(url: URL) -> Result<[ReplayEvent], Failure> {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return .failure(Failure(message: "The transcript file could not be read. It may have moved or be binary."))
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        var out: [ReplayEvent] = []
        var idx = 0

        // Append one event, trimming + truncating its body. Tool calls may have an
        // empty body (the tool name in `title` carries the meaning); all other kinds
        // require text and are skipped when empty.
        func add(_ kind: ReplayEvent.Kind, title: String?, body: String, stamp: Date?) {
            var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty && kind != .toolUse { return }
            if text.count > bodyLimit { text = String(text.prefix(bodyLimit)) + "\n\u{2026}(truncated)" }
            out.append(ReplayEvent(id: idx, kind: kind, timestamp: stamp, title: title,
                                   body: text, isMarkdown: kind == .user || kind == .assistant))
            idx += 1
        }

        for lineStr in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            if out.count >= maxEvents { break }
            guard let data = lineStr.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let type = (root["type"] as? String) ?? ""
            let stamp = (root["timestamp"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            let message = root["message"] as? [String: Any]
            let content = message?["content"] ?? root["summary"] ?? root["text"]

            switch type {
            case "summary":
                add(.summary, title: nil, body: (root["summary"] as? String) ?? flatten(content), stamp: stamp)
            case "system":
                add(.system, title: nil, body: flatten(content), stamp: stamp)
            case "user":
                if let s = content as? String {
                    add(.user, title: nil, body: s, stamp: stamp)
                } else if let blocks = content as? [Any] {
                    for block in blocks {
                        guard let bd = block as? [String: Any] else {
                            if let s = block as? String { add(.user, title: nil, body: s, stamp: stamp) }
                            continue
                        }
                        switch bd["type"] as? String {
                        case "text": add(.user, title: nil, body: bd["text"] as? String ?? "", stamp: stamp)
                        case "tool_result": add(.toolResult, title: nil, body: flatten(bd["content"]), stamp: stamp)
                        default: break
                        }
                    }
                }
            case "assistant":
                if let blocks = content as? [Any] {
                    for block in blocks {
                        guard let bd = block as? [String: Any] else { continue }
                        switch bd["type"] as? String {
                        case "text": add(.assistant, title: nil, body: bd["text"] as? String ?? "", stamp: stamp)
                        case "thinking": add(.thinking, title: nil, body: bd["thinking"] as? String ?? "", stamp: stamp)
                        case "tool_use": add(.toolUse, title: (bd["name"] as? String) ?? "tool",
                                             body: summarizeInput(bd["input"]), stamp: stamp)
                        default: break
                        }
                    }
                } else if let s = content as? String {
                    add(.assistant, title: nil, body: s, stamp: stamp)
                }
            default:
                break
            }
        }

        return .success(out)
    }

    // Flatten a JSON content value (string / array / typed blocks) into plain text.
    private static func flatten(_ value: Any?) -> String {
        switch value {
        case let s as String:
            return s
        case let arr as [Any]:
            return arr.map { flatten($0) }.filter { !$0.isEmpty }.joined(separator: "\n")
        case let dict as [String: Any]:
            switch dict["type"] as? String {
            case "text": return dict["text"] as? String ?? ""
            case "tool_result": return flatten(dict["content"])
            case "thinking": return dict["thinking"] as? String ?? ""
            default: return (dict["text"] as? String) ?? (dict["content"] as? String) ?? ""
            }
        default:
            return ""
        }
    }

    // Render a tool call's input as readable `key: value` lines, most-telling keys
    // first, each value truncated. Nested arrays / objects are summarized by size.
    private static func summarizeInput(_ input: Any?) -> String {
        if let s = input as? String { return s }
        guard let dict = input as? [String: Any], !dict.isEmpty else { return "" }

        let preferred = ["command", "file_path", "path", "pattern", "query",
                         "description", "prompt", "url", "old_string", "new_string", "content"]
        let ordered = preferred.filter { dict[$0] != nil }
            + dict.keys.filter { !preferred.contains($0) }.sorted()

        var lines: [String] = []
        for key in ordered {
            guard let value = dict[key] else { continue }
            var rendered = render(value).trimmingCharacters(in: .whitespacesAndNewlines)
            if rendered.count > valueLimit { rendered = String(rendered.prefix(valueLimit)) + "\u{2026}" }
            lines.append("\(key): \(rendered)")
        }
        return lines.joined(separator: "\n")
    }

    private static func render(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let arr as [Any]: return "[\(arr.count) item\(arr.count == 1 ? "" : "s")]"
        case let dict as [String: Any]: return "{\(dict.count) key\(dict.count == 1 ? "" : "s")}"
        default: return String(describing: value)
        }
    }
}
