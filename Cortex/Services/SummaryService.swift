import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - SummaryService
//
// Generates short, one-line summaries of long config descriptions (mainly agents,
// whose `description:` frontmatter is often a full paragraph) using Apple's on-device
// Foundation Models LLM - free, private, no network. Summaries are cached to disk
// keyed by file path + modified time, so the model runs once per file and only
// re-runs when that file actually changes. Everything degrades gracefully: when
// Apple Intelligence is unavailable (older macOS, not enabled, model still
// downloading) nothing is queued and callers fall back to the raw description.

// MARK: - Summary backend
//
// Which engine generates AI summaries. Off by default; selectable in Settings so a
// user can opt into what they have: the local Claude Code CLI (Haiku, cheap + high
// quality, but spawns a session per summary), Apple's on-device model (free + private
// but needs macOS 26 + Apple silicon), or Off (fall back to raw text).
enum SummaryBackend: String, CaseIterable, Identifiable, Hashable {
    case claude   // local `claude` CLI, Haiku model
    case apple    // Apple Intelligence (on-device Foundation Models)
    case off

    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: "Claude (Haiku)"
        case .apple: "Apple Intelligence"
        case .off: "Off"
        }
    }

    /// The persisted choice (UserDefaults key shared with Settings). Defaults to Off:
    /// a fresh install should never spawn Claude sessions on its own, and Apple
    /// Intelligence isn't available on every Mac (needs macOS 26 on Apple silicon),
    /// so summaries are strictly opt-in via Settings.
    static var current: SummaryBackend {
        SummaryBackend(rawValue: UserDefaults.standard.string(forKey: "summaryBackend") ?? "")
            ?? .off
    }

    /// True when a transcript's first user prompt is one of Cortex's OWN summary tasks.
    /// The Claude CLI backend spawns a logged `claude -p` session per summary, so without
    /// this filter those self-generated sessions would pollute the sessions list. Matches
    /// the fixed openings of the session + agent instruction prompts below.
    nonisolated static func isCortexSummaryPrompt(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("You summarize a coding session")
            || t.hasPrefix("You summarize an AI coding-agent")
    }
}

@MainActor
@Observable
final class SummaryService {
    /// path -> cached summary. Observed, so rows/detail update as summaries land.
    private(set) var summaries: [String: Cached] = [:]

    // Paths currently queued or generating (so repeated scans don't double-enqueue).
    private var inFlight: Set<String> = []
    // Pending work, processed one at a time off the main actor's critical path.
    private var queue: [Pending] = []
    private var worker: Task<Void, Never>?

    struct Cached: Codable, Sendable {
        var text: String
        var modified: Double   // the file mtime (epoch) this summary was generated for
    }

    private struct Pending: Sendable {
        var key: String
        var modified: Double
        var source: Source
        var kind: Kind
        var backend: SummaryBackend
    }

    // Where the text to summarize comes from: a ready string (agent descriptions) or a
    // session JSONL whose user prompts are extracted off-main at generation time.
    private enum Source: Sendable {
        case text(String)
        case sessionPrompts(URL)
    }

    private enum Kind: Sendable { case agent, session }

    init() { load() }

    // MARK: - Availability

    /// The active backend (persisted in Settings).
    var backend: SummaryBackend { SummaryBackend.current }

    /// Whether summaries can be generated right now with the selected backend: the
    /// Claude CLI must be on disk for `.claude`; Apple Intelligence must be ready for
    /// `.apple`; `.off` is never available. Gates work and hints in the UI.
    var isAvailable: Bool {
        switch backend {
        case .off: return false
        case .claude: return Self.claudeCLIPath != nil
        case .apple: return Self.appleAvailable
        }
    }

    /// Apple's on-device model readiness (false pre-macOS 26, when disabled, ineligible,
    /// or still downloading).
    private static var appleAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Path to the local `claude` CLI, resolved once. GUI apps don't inherit the login
    /// shell PATH, so we probe the common install locations, then fall back to asking a
    /// login shell. nil when Claude Code isn't installed.
    static let claudeCLIPath: String? = {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.claude/local/claude",      // Claude Code native installer
            "/opt/homebrew/bin/claude",          // Homebrew (Apple silicon)
            "/usr/local/bin/claude",             // Homebrew (Intel) / npm global
            home + "/.local/bin/claude",
            home + "/.bun/bin/claude",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) { return path }

        // Fall back to a login shell `command -v claude` (captures the user's real PATH).
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let resolved = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fm.isExecutableFile(atPath: resolved) ? resolved : nil
    }()

    // MARK: - Lookup

    /// The cached AI summary for an item, or nil when there isn't a fresh one (the
    /// file changed since, or it was never summarized). Callers fall back to the raw
    /// description so the UI is never blank.
    func summary(for item: ConfigItem) -> String? {
        guard let cached = summaries[item.path] else { return nil }
        // Treat as stale if the file was edited after the summary was made.
        guard abs(cached.modified - item.modified.timeIntervalSince1970) < 1 else { return nil }
        let text = cached.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Scheduling

    /// Queue background summarization for items whose description is long enough to
    /// benefit and that lack a fresh cached summary. Short descriptions are already
    /// one-liners, so they're skipped. No-op when the on-device model is unavailable.
    func ensureSummaries(for items: [ConfigItem], minLength: Int = 120) {
        guard isAvailable else { return }
        for item in items {
            let desc = item.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard desc.count >= minLength else { continue }   // already concise
            guard summary(for: item) == nil else { continue } // fresh cache hit
            guard !inFlight.contains(item.path) else { continue }
            inFlight.insert(item.path)
            queue.append(Pending(
                key: item.path,
                modified: item.modified.timeIntervalSince1970,
                source: .text(String(desc.prefix(2000))),     // cap input for speed
                kind: .agent,
                backend: backend
            ))
        }
        startWorkerIfNeeded()
    }

    // MARK: - Session summaries

    private func sessionKey(_ id: String) -> String { "session:" + id }

    /// The cached AI summary of what a session was about, or nil when not yet generated
    /// or stale (the session was appended to since).
    func sessionSummary(for session: ClaudeSession) -> String? {
        guard let cached = summaries[sessionKey(session.id)] else { return nil }
        guard abs(cached.modified - session.endedAt.timeIntervalSince1970) < 1 else { return nil }
        let text = cached.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// True once a session summary has been requested and is still being generated (so
    /// the UI can show a "Summarizing…" placeholder rather than nothing).
    func isSummarizing(_ session: ClaudeSession) -> Bool {
        inFlight.contains(sessionKey(session.id))
    }

    /// Generate (once) a 1-2 sentence summary of the given session from its user
    /// prompts. Lazy + on-demand: call it for the session the user is actually viewing,
    /// not the whole list. Jumps the queue so the open session summarizes promptly.
    func ensureSessionSummary(for session: ClaudeSession) {
        guard isAvailable else { return }
        let key = sessionKey(session.id)
        guard sessionSummary(for: session) == nil else { return }
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        queue.insert(Pending(
            key: key,
            modified: session.endedAt.timeIntervalSince1970,
            source: .sessionPrompts(session.fileURL),
            kind: .session,
            backend: backend
        ), at: 0)
        startWorkerIfNeeded()
    }

    // Drain the queue sequentially (one request at a time avoids the model's
    // concurrent-request / rate-limit errors), publishing each summary as it lands.
    private func startWorkerIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { @MainActor in
            defer { worker = nil }
            while !queue.isEmpty {
                if Task.isCancelled { break }
                let next = queue.removeFirst()
                let text = await Self.generate(source: next.source, kind: next.kind, backend: next.backend)
                inFlight.remove(next.key)
                if let text, !text.isEmpty {
                    summaries[next.key] = Cached(text: text, modified: next.modified)
                    save()
                }
            }
        }
    }

    // MARK: - On-device generation

    private static func generate(source: Source, kind: Kind, backend: SummaryBackend) async -> String? {
        // Resolve the input text once (session prompts are read + parsed off-main here),
        // then hand to whichever backend is selected.
        let input: String
        switch source {
        case .text(let text):
            input = text
        case .sessionPrompts(let url):
            input = await Task.detached(priority: .utility) { Self.extractPrompts(from: url) }.value
        }
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        switch backend {
        case .off: return nil
        case .claude: return await generateWithClaude(input: input, kind: kind)
        case .apple: return await generateWithApple(input: input, kind: kind)
        }
    }

    // MARK: Apple Intelligence (on-device Foundation Models)

    private static func generateWithApple(input: String, kind: Kind) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let session = LanguageModelSession(instructions: kind == .session ? Self.sessionInstructions : Self.agentInstructions)
            do {
                let response = try await session.respond(to: input)
                return Self.clean(response.content, oneLine: kind == .agent)
            } catch {
                return nil   // refusal / unavailable mid-run / etc. -> fall back to raw text
            }
        }
        #endif
        return nil
    }

    // MARK: Claude (local CLI, Haiku)
    //
    // Shells out to the user's `claude` CLI in print mode with the cheap Haiku model:
    // `claude -p <instructions + input> --model haiku`. Uses the existing Claude Code
    // auth (no API key needed). Runs off-main; a nonzero exit / missing CLI returns nil
    // so callers fall back to the raw text. No tools, so it never prompts.

    private static func generateWithClaude(input: String, kind: Kind) async -> String? {
        guard let bin = claudeCLIPath else { return nil }
        let instructions = kind == .session ? Self.sessionInstructions : Self.agentInstructions
        let prompt = instructions + "\n\nInput:\n" + input
        let oneLine = kind == .agent
        return await Task.detached(priority: .utility) { () -> String? in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = ["-p", prompt, "--model", "haiku"]
            proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            do { try proc.run() } catch { return nil }
            // Watchdog: terminate a stuck CLI (offline network, an interactive gate) after
            // 45s so the single serial summary worker can never hang indefinitely.
            let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: watchdog)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            watchdog.cancel()
            guard proc.terminationStatus == 0 else { return nil }
            let raw = String(data: data, encoding: .utf8) ?? ""
            let cleaned = Self.clean(raw, oneLine: oneLine)
            return cleaned.isEmpty ? nil : cleaned
        }.value
    }

    private static let agentInstructions = """
    You summarize an AI coding-agent description into ONE short line for a list UI. \
    Reply with a single plain sentence of at most 12 words saying what the agent does. \
    No quotes, no markdown, no leading label, no trailing period.
    """

    private static let sessionInstructions = """
    You summarize a coding session from the user's prompts. Write 1-2 short, plain \
    sentences describing what the session was about and what was done. \
    No markdown, no preamble, no quotes.
    """

    // Pull the user prompts out of a session JSONL (reusing the replay parser) and join
    // the first several into one capped string - enough to capture the session's intent
    // without feeding thousands of turns to the model.
    private nonisolated static func extractPrompts(from url: URL) -> String {
        guard case .success(let events) = ReplayParser.parse(url: url) else { return "" }
        let prompts = events
            .filter { $0.kind == .user }
            .map { $0.body.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return String(prompts.prefix(12).joined(separator: "\n---\n").prefix(3000))
    }

    // Normalize the model's reply: collapse newlines, strip wrapping quotes; for the
    // one-line agent subtitle also drop a trailing period.
    private nonisolated static func clean(_ raw: String, oneLine: Bool) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\n", with: " ")
        while let f = s.first, f == "\"" || f == "'" { s.removeFirst() }
        while let l = s.last, l == "\"" || l == "'" || (oneLine && l == ".") { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Persistence (Application Support/Cortex/summaries.json)

    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("Cortex", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("summaries.json")
    }

    private func load() {
        guard let url = Self.fileURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Cached].self, from: data) else { return }
        summaries = decoded
    }

    private func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(summaries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
