import Foundation

// MARK: - ChatService
//
// The Assistant. Drives Claude Code as a one-shot transport
// (`claude -p --output-format json`) the same way the original app did, but as a
// general assistant: it is seeded with a system prompt describing Cortex and the
// user's on-device AI stack so it can answer questions about *everything* the app
// knows, not a single skill. Each `send` is one stateless turn; prior turns are
// replayed into the prompt so the conversation has memory.

// MARK: - Chat model
//
// The Claude model the Assistant runs on. Sonnet is the balanced default; Opus is the
// smartest (use it for hard reasoning); Haiku is the cheapest/fastest. The rawValue is
// the alias passed to `claude --model`.
enum ChatModel: String, CaseIterable, Identifiable, Hashable {
    case opus, sonnet, haiku
    var id: String { rawValue }
    var label: String {
        switch self {
        case .opus: "Opus"
        case .sonnet: "Sonnet"
        case .haiku: "Haiku"
        }
    }
    var blurb: String {
        switch self {
        case .opus: "Smartest, slower"
        case .sonnet: "Balanced (default)"
        case .haiku: "Fastest, cheapest"
        }
    }
}

// MARK: - Chat mode
//
// Whether the assistant may change files. Read only (default) just answers questions
// about the stack; Allow edit lets the underlying engine run with edit permissions
// (Claude: `--permission-mode acceptEdits`) so it can act, not just describe.
enum ChatMode: String, CaseIterable, Identifiable, Hashable {
    case readOnly, allowEdit
    var id: String { rawValue }
    var label: String {
        switch self {
        case .readOnly: "Read only"
        case .allowEdit: "Allow edit"
        }
    }
    var icon: String {
        switch self {
        case .readOnly: "eye"
        case .allowEdit: "pencil"
        }
    }
}

// MARK: - Chat engine (which installed CLI backs the assistant)
//
// The assistant can run on whichever coding-agent CLI the user has installed. Claude
// Code is the verified default (rich JSON output + cost). Antigravity (Google's `agy`,
// the successor to the now-deprecated individual Gemini CLI sign-in) and Codex are
// best-effort text adapters, gated by `isInstalled` so only CLIs actually on the
// machine are selectable.
enum ChatEngine: String, CaseIterable, Identifiable, Hashable {
    case claude, antigravity, codex
    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: "Claude Code"
        case .antigravity: "Antigravity"
        case .codex: "Codex"
        }
    }
    var blurb: String {
        switch self {
        case .claude: "Verified, full cost + markdown"
        case .antigravity: "Google's agy CLI (Gemini)"
        case .codex: "OpenAI codex exec"
        }
    }
    /// The CLI executable name to resolve on PATH. Antigravity ships as `agy`.
    var cliName: String {
        switch self {
        case .claude: "claude"
        case .antigravity: "agy"
        case .codex: "codex"
        }
    }
    /// Whether this engine's CLI is installed (on PATH).
    var isInstalled: Bool { Shell.which(cliName) != nil }

    static var current: ChatEngine {
        // Migrate the retired "gemini" preference to its successor so an old stored
        // value doesn't silently fall back to Claude.
        let raw = UserDefaults.standard.string(forKey: "assistantEngine") ?? ""
        if raw == "gemini" { return .antigravity }
        return ChatEngine(rawValue: raw) ?? .claude
    }
}

@MainActor
@Observable
final class ChatService {
    private(set) var messages: [ChatMessage] = []
    private(set) var isResponding = false
    private(set) var lastError: String?
    /// While a Claude turn streams, a short human label of what it's doing right now
    /// ("Reading files…", "Running a command…"), or nil. Drives the thinking indicator
    /// so a long turn shows progress instead of a blank wait.
    private(set) var streamingActivity: String?
    /// Available when the selected engine's CLI is installed (or any engine is).
    var isAvailable: Bool { engine.isInstalled || ChatEngine.allCases.contains { $0.isInstalled } }

    /// The model the assistant runs on (user-selectable in the composer). Persisted via
    /// @AppStorage in the view; seeded from that key on launch. (Claude models.)
    var model: ChatModel = {
        ChatModel(rawValue: UserDefaults.standard.string(forKey: "assistantModel") ?? "") ?? .sonnet
    }()

    /// The CLI engine backing the assistant (Settings → AI). Seeded from the same key.
    var engine: ChatEngine = ChatEngine.current

    /// Read-only vs allow-edit (composer pill). Seeded from the persisted key.
    var mode: ChatMode = {
        ChatMode(rawValue: UserDefaults.standard.string(forKey: "assistantMode") ?? "") ?? .readOnly
    }()

    /// Injected by AppModel after a scan so the assistant knows the live context.
    var stackContext: String = ""

    /// Saved past conversations, newest-first, loaded from Application Support on launch
    /// and upserted after every completed turn. Reopenable from the Assistant header.
    private(set) var history: [ChatConversation] = []
    /// The id of the conversation the live `messages` belong to (nil = a fresh, unsaved
    /// chat; an id is minted on the first send). Drives upsert vs insert on persist.
    private var currentConversationID: UUID?

    private var currentProcess: Process?

    init() {
        history = Self.loadHistory()
    }

    /// Start a fresh conversation. The current one is saved first (if it has a reply),
    /// so New Chat never loses what was on screen.
    func reset() {
        persistCurrent()
        messages = []
        lastError = nil
        currentConversationID = nil
    }

    // MARK: - Conversation history

    /// Reopen a saved conversation, persisting the current one first.
    func openConversation(_ id: UUID) {
        persistCurrent()
        guard let convo = history.first(where: { $0.id == id }) else { return }
        messages = convo.messages
        currentConversationID = id
        lastError = nil
    }

    /// Delete a saved conversation. If it is the one on screen, clear to a fresh chat.
    func deleteConversation(_ id: UUID) {
        history.removeAll { $0.id == id }
        if currentConversationID == id {
            messages = []
            currentConversationID = nil
        }
        Self.writeHistory(history)
    }

    /// Upsert the live conversation into history once it has at least one assistant
    /// reply, then write the file. Title = the first user message, trimmed.
    private func persistCurrent() {
        guard messages.contains(where: { $0.role == .assistant && !$0.text.isEmpty }) else { return }
        let id = currentConversationID ?? UUID()
        currentConversationID = id
        let title = messages.first(where: { $0.role == .user })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Conversation"
        let now = Date()
        let created = history.first(where: { $0.id == id })?.createdAt ?? now
        let convo = ChatConversation(
            id: id,
            title: String(title.prefix(80)),
            createdAt: created,
            updatedAt: now,
            // Drop the streaming flag so a reopened turn never shows as in-flight.
            messages: messages.map { var m = $0; m.isStreaming = false; return m }
        )
        history.removeAll { $0.id == id }
        history.insert(convo, at: 0)
        Self.writeHistory(history)
    }

    // MARK: - History persistence (Application Support/Cortex/conversations.json)

    /// Application Support/Cortex, created if needed (shared with library.json).
    /// `nonisolated` so the detached writer can resolve the path off the main actor.
    nonisolated private static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Cortex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated private static var historyURL: URL { supportDir.appendingPathComponent("conversations.json") }

    nonisolated private static func loadHistory() -> [ChatConversation] {
        guard let data = try? Data(contentsOf: historyURL),
              let list = try? JSONDecoder().decode([ChatConversation].self, from: data) else { return [] }
        return list.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Encode + write off the main thread (the transcript can be large). Sendable value
    /// snapshot, so the detached write is safe.
    nonisolated private static func writeHistory(_ list: [ChatConversation]) {
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(list) else { return }
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }
        // Resolve the engine: the chosen one if installed, else the first installed.
        let engine = self.engine.isInstalled ? self.engine : (ChatEngine.allCases.first { $0.isInstalled } ?? .claude)
        guard let bin = Shell.which(engine.cliName) else {
            lastError = "\(engine.label) CLI not found. Pick an installed engine in Settings \u{203A} AI, or install one."
            return
        }

        messages.append(ChatMessage(role: .user, text: trimmed))
        let assistant = ChatMessage(role: .assistant, text: "", isStreaming: true)
        let assistantID = assistant.id
        messages.append(assistant)
        isResponding = true
        lastError = nil
        streamingActivity = nil

        let system = Self.systemPrompt(stack: stackContext)
        let transcript = Self.renderTranscript(messages.dropLast())
        let home = FileManager.default.homeDirectoryForCurrentUser
        let modelArg = model.rawValue
        let mode = self.mode

        // Finalize a landed reply: strip any nav-CTA block, attach actions + cost.
        func finalize(text: String, cost: Double?, error: String?) {
            streamingActivity = nil
            guard let idx = messages.firstIndex(where: { $0.id == assistantID }) else { return }
            if let error {
                messages.remove(at: idx)
                lastError = error
            } else {
                let source = text.isEmpty ? messages[idx].text : text
                let (clean, actions) = Self.parseActions(from: source)
                messages[idx].text = clean.isEmpty ? "(no response)" : clean
                messages[idx].actions = actions
                messages[idx].cost = cost
                messages[idx].isStreaming = false
            }
        }

        switch engine {
        case .claude:
            // Stream the reply token-by-token (and surface tool activity) so a long turn
            // shows live progress instead of a blank "thinking" wait.
            let stream = AsyncStream<ChatStreamEvent> { cont in
                let task = Task.detached(priority: .userInitiated) {
                    Self.runClaudeStreaming(bin: bin, cwd: home, system: system, prompt: transcript,
                                            model: modelArg, mode: mode) { cont.yield($0) }
                    cont.finish()
                }
                cont.onTermination = { _ in task.cancel() }
            }
            for await event in stream {
                switch event {
                case .text(let t):
                    if let idx = messages.firstIndex(where: { $0.id == assistantID }) { messages[idx].text = t }
                case .activity(let a):
                    streamingActivity = a
                case .done(let text, let cost, let error):
                    finalize(text: text, cost: cost, error: error)
                }
            }
        case .antigravity, .codex:
            let result = await Task.detached(priority: .userInitiated) { () -> (text: String, cost: Double?, error: String?) in
                Self.runGeneric(engine: engine, bin: bin, cwd: home, system: system, prompt: transcript, mode: mode)
            }.value
            finalize(text: result.text, cost: result.cost, error: result.error)
        }

        isResponding = false
        streamingActivity = nil
        // Persist the conversation now that a full turn has landed.
        persistCurrent()
    }

    // MARK: - Prompt building

    static func systemPrompt(stack: String) -> String {
        """
        You are Cortex, the user's personal AI-stack assistant living inside a native macOS app of the same name.
        You answer questions about the user's local AI tooling: Claude Code sessions, costs, skills, agents, \
        MCP servers, hooks, memory, repos, and listening ports. Be concise, concrete, and friendly. \
        Use plain markdown. When you reference the user's data, ground it in the context provided below. \
        You are a conversational assistant for the whole app, not scoped to any single skill or MCP server.

        # Grounding rules
        - The app is named "Cortex", but the user's data is organized by their real PROJECT FOLDER names \
        (e.g. "llm-cheatsheet", "appendix"). Cortex's own source lives in a project folder that is NOT \
        literally named "cortex" - so when the user says "this project", "the cortex project", or names a \
        folder, match it case-insensitively (and by partial/substring) against the per-project breakdown \
        below. Never claim a project doesn't exist if a close folder-name match is present; pick the best match.
        - Answer every numeric question from the real numbers in the context. Do not invent or estimate counts. \
        If the exact figure isn't in the context, say so plainly rather than guessing.

        # Navigation actions (optional)
        When a page inside Cortex would let the user see or act on what you just \
        described, you MAY end your reply with ONE fenced code block tagged \
        `cortex-action` containing a JSON array of up to 3 buttons. The app strips this \
        block from your prose and renders the buttons. Only include it when a jump is \
        genuinely useful; never narrate it. Shape:
        ```cortex-action
        [{"label": "Open Costs", "route": "costs"},
         {"label": "Sessions in llm-cheatsheet", "route": "sessions", "scope": "llm-cheatsheet"}]
        ```
        Valid `route` values: readout (Home), usage, live, sessions, costs, ports, repos, \
        workGraph, diffs, snapshots, skills, agents, rules, commands, plugins, memory, \
        hooks, instructions, tools (MCP servers), health, settings. Optional fields: \
        `scope` (a project folder name) and `search` (a query string). The `sessions` and \
        `memory` routes apply `scope` to pre-filter to that project (and `search` to \
        pre-fill the search box), so when you point the user at a specific project's \
        sessions or memory, ALWAYS include `scope` with the folder name. Use a route only \
        from this list; keep labels short (2-4 words).

        # Live on-device context
        \(stack.isEmpty ? "(context not yet loaded)" : stack)
        """
    }

    // MARK: - Action parsing
    //
    // Pull a trailing ```cortex-action [json] ``` block off the reply, decode it into
    // [ChatAction], and return the prose with every such block removed. Tolerant: a
    // malformed or empty block is simply stripped and yields no actions, so a model
    // slip never leaks raw JSON into the bubble.

    static func parseActions(from raw: String) -> (text: String, actions: [ChatAction]) {
        guard raw.contains("cortex-action") else { return (raw, []) }
        var actions: [ChatAction] = []
        var text = raw
        // Match ```cortex-action ... ``` (case-insensitive fence tag, dot-matches-newline).
        let pattern = "```[ \\t]*cortex-action[ \\t]*\\n?([\\s\\S]*?)```"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (raw, [])
        }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches where m.numberOfRanges > 1 {
            let json = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            actions += decodeActions(json)
        }
        // Strip every matched block (back-to-front so ranges stay valid).
        let mutable = NSMutableString(string: text)
        for m in matches.reversed() { mutable.replaceCharacters(in: m.range, with: "") }
        text = (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, Array(actions.prefix(3)))
    }

    /// Decode an action JSON payload (a bare array, a single object, or {"actions":[…]})
    /// into validated ChatActions. Entries with an unknown route or empty label drop.
    private static func decodeActions(_ json: String) -> [ChatAction] {
        struct DTO: Decodable { var label: String; var route: String; var search: String?; var scope: String? }
        struct Wrap: Decodable { var actions: [DTO] }
        guard let data = json.data(using: .utf8) else { return [] }
        let dec = JSONDecoder()
        let dtos: [DTO]
        if let arr = try? dec.decode([DTO].self, from: data) { dtos = arr }
        else if let one = try? dec.decode(DTO.self, from: data) { dtos = [one] }
        else if let w = try? dec.decode(Wrap.self, from: data) { dtos = w.actions }
        else { return [] }
        return dtos.compactMap { dto in
            let label = dto.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, let route = Route(rawValue: dto.route) else { return nil }
            return ChatAction(label: label, route: route,
                              search: dto.search?.isEmpty == true ? nil : dto.search,
                              scope: dto.scope?.isEmpty == true ? nil : dto.scope)
        }
    }

    static func renderTranscript(_ history: ArraySlice<ChatMessage>) -> String {
        var lines: [String] = []
        for m in history {
            let who = m.role == .user ? "User" : "Assistant"
            lines.append("\(who): \(m.text)")
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Streaming runner (Claude)
    //
    // One event emitted to the UI as a Claude turn runs: incremental text, a tool-activity
    // label, or the terminal result. Lets the Assistant show live progress.
    nonisolated enum ChatStreamEvent: Sendable {
        case text(String)        // full accumulated visible text so far
        case activity(String?)   // current tool/status label, nil clears it
        case done(text: String, cost: Double?, error: String?)
    }

    /// A friendly status label for a tool the assistant invoked mid-turn.
    nonisolated static func activityLabel(forTool name: String) -> String {
        switch name {
        case "Read", "Glob", "Grep", "LS": return "Reading files\u{2026}"
        case "Bash": return "Running a command\u{2026}"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Editing files\u{2026}"
        case "WebFetch", "WebSearch": return "Searching the web\u{2026}"
        case "Task": return "Working\u{2026}"
        default: return name.hasPrefix("mcp__") ? "Using a tool\u{2026}" : "Using \(name)\u{2026}"
        }
    }

    /// Run Claude with `--output-format stream-json --include-partial-messages` and emit
    /// events as NDJSON lines arrive: text deltas stream into the bubble, tool_use blocks
    /// surface as an activity label, and the final `result` line carries the cost. Reads
    /// stdout incrementally so the UI updates in realtime.
    nonisolated static func runClaudeStreaming(bin: URL, cwd: URL, system: String, prompt: String,
                                               model: String, mode: ChatMode,
                                               emit: @escaping @Sendable (ChatStreamEvent) -> Void) {
        let proc = Process()
        proc.executableURL = bin
        let settings = #"{"effortLevel":"low","includeCoAuthoredBy":false}"#
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--system-prompt", system,
            "--model", model,
            "--settings", settings,
            // The assistant answers from the injected context; it never needs the user's
            // MCP servers, and loading them adds ~1s of cold-start latency. Skip them.
            "--strict-mcp-config",
        ]
        if mode == .allowEdit {
            // Allow edit: auto-accept edits so it can act, not just describe.
            args += ["--permission-mode", "acceptEdits"]
        } else {
            // Read-only: keep just the LOCAL read tools (it can still inspect files,
            // surfaced as "Reading files…"); block writes, shell, web, and sub-agents.
            // This makes read-only genuinely safe and cuts cold start toward its floor.
            args += ["--disallowedTools", "Bash Edit Write MultiEdit NotebookEdit WebFetch WebSearch Task"]
        }
        args += ["--", prompt]
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-swift"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        proc.environment = env
        proc.currentDirectoryURL = cwd

        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run() } catch {
            emit(.done(text: "", cost: nil, error: "Failed to launch Claude: \(error.localizedDescription)"))
            return
        }

        // Drain stderr CONCURRENTLY so a large `--verbose` diagnostic can't fill the pipe
        // buffer and deadlock the child (hanging the turn). Captured to surface a real
        // error if the turn ends with no output.
        let errHandle = err.fileHandleForReading
        let errQueue = DispatchQueue(label: "cortex.claude.stderr")
        var stderrData = Data()
        errHandle.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            errQueue.sync { stderrData.append(d) }
        }

        var accumulated = ""
        var finalText: String?
        var cost: Double?
        var errorMsg: String?
        var lastEmit: Date?

        // Parse one NDJSON event line and emit any resulting UI update.
        func processLine(_ data: Data) {
            guard !data.isEmpty,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = obj["type"] as? String else { return }
            switch type {
            case "stream_event":
                guard let event = obj["event"] as? [String: Any] else { return }
                let etype = event["type"] as? String
                if etype == "content_block_delta", let delta = event["delta"] as? [String: Any],
                   let t = delta["text"] as? String {
                    accumulated += t
                    // Coalesce UI updates to ~50ms: emitting the full string on every
                    // token forces a full markdown re-render per token (quadratic + janky).
                    // The terminal .done always carries the complete text, so nothing is lost.
                    let now = Date()
                    if lastEmit == nil || now.timeIntervalSince(lastEmit!) > 0.05 {
                        lastEmit = now
                        emit(.text(accumulated))
                    }
                } else if etype == "content_block_start", let cb = event["content_block"] as? [String: Any],
                          (cb["type"] as? String) == "tool_use", let name = cb["name"] as? String {
                    emit(.activity(activityLabel(forTool: name)))
                }
            case "assistant":
                // Fallback for builds that don't stream deltas: take full text blocks,
                // and surface any tool_use as activity.
                guard let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { return }
                var parts: [String] = []
                for block in content {
                    switch block["type"] as? String {
                    case "text": if let t = block["text"] as? String { parts.append(t) }
                    case "tool_use": if let name = block["name"] as? String { emit(.activity(activityLabel(forTool: name))) }
                    default: break
                    }
                }
                let full = parts.joined()
                if !full.isEmpty, accumulated.isEmpty { accumulated = full; emit(.text(accumulated)) }
            case "result":
                if let r = obj["result"] as? String { finalText = r }
                if let c = obj["total_cost_usd"] as? Double { cost = c }
                if (obj["is_error"] as? Bool) == true { errorMsg = (obj["result"] as? String) ?? "Claude reported an error." }
            default:
                break
            }
        }

        // Read stdout incrementally, splitting on newlines so each event renders live.
        var buffer = Data()
        let reader = out.fileHandleForReading
        while true {
            // If the turn was abandoned (Task cancelled), stop and kill the child so an
            // orphaned `claude -p` doesn't keep running in the background.
            if Task.isCancelled { proc.terminate(); break }
            let chunk = reader.availableData
            if chunk.isEmpty { break }   // EOF
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                processLine(lineData)
            }
        }
        if !buffer.isEmpty { processLine(buffer) }
        proc.waitUntilExit()

        // Collect stderr (the handler drained most of it; flush any remainder).
        errHandle.readabilityHandler = nil
        errQueue.sync { stderrData.append(errHandle.readDataToEndOfFile()) }
        let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let errorMsg {
            emit(.done(text: "", cost: cost, error: errorMsg))
        } else if (finalText ?? accumulated).isEmpty && proc.terminationStatus != 0 {
            // Crashed / exited nonzero with no reply: surface the real diagnostic instead
            // of a silent "(no response)".
            let msg = stderrText.isEmpty
                ? "Claude exited with code \(proc.terminationStatus) and produced no output."
                : String(stderrText.suffix(500))
            emit(.done(text: "", cost: cost, error: msg))
        } else {
            emit(.done(text: finalText ?? accumulated, cost: cost, error: nil))
        }
    }

    // MARK: - Generic adapter (Antigravity / Codex)
    //
    // Best-effort, text-only invocation for non-Claude engines (no per-turn cost). The
    // system prompt is folded into the prompt since these CLIs don't take a separate
    // system flag. Antigravity: `agy -p <prompt>` (verified to return clean text as a
    // plain subprocess on agy 1.0.10; `--sandbox` is added in read-only mode to restrict
    // terminal tools, the best guardrail agy's print mode offers). Codex: `codex exec
    // <prompt>`. A nonzero exit surfaces as an error the user can see.
    nonisolated static func runGeneric(engine: ChatEngine, bin: URL, cwd: URL, system: String, prompt: String, mode: ChatMode) -> (text: String, cost: Double?, error: String?) {
        let combined = system + "\n\n" + prompt
        let proc = Process()
        proc.executableURL = bin
        switch engine {
        case .codex:
            proc.arguments = ["exec", combined]
        case .antigravity:
            // Read-only adds --sandbox (terminal restrictions). agy's -p mode has no true
            // read-only flag, so this is best-effort; allow-edit omits the sandbox.
            proc.arguments = (mode == .readOnly ? ["--sandbox"] : []) + ["-p", combined]
        case .claude:
            proc.arguments = ["-p", combined]   // unreached: Claude streams via runClaudeStreaming
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        proc.environment = env
        proc.currentDirectoryURL = cwd

        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run() } catch {
            return ("", nil, "Failed to launch \(engine.label): \(error.localizedDescription)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            return ("", nil, "\(engine.label) exited with an error. It may need setup or a different invocation.")
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (text.isEmpty ? "(no response)" : text, nil, nil)
    }
}
