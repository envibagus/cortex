import Foundation
import AppKit
import AVFoundation

// MARK: - ActivityService
//
// Live "what is Claude Code doing right now" signal for the menu bar. Claude Code can
// run shell hooks on lifecycle events (a prompt submitted, a tool about to run, the turn
// finished, a permission prompt). This service installs a tiny hook script that records each
// event to a per-session file under ~/.claude/cortex/sessions/<id>.json, then polls that
// directory and turns the raw events into a friendly per-session status ("Editing", "Running
// command", "Awaiting permission") plus a turn timer and an optional completion chime. (It
// also still writes a single latest-event ~/.claude/cortex/activity.json for compatibility.)
//
// IMPORTANT: this is the ONE place Cortex writes outside its own container. Everything
// else is read-only. Enabling live activity writes a scoped `hooks` block to
// ~/.claude/settings.json (a backup is taken first) and drops the hook script; disabling
// removes exactly those entries and the script, leaving the rest of settings.json
// untouched. It is off by default and fully reversible.

// MARK: Activity model

/// What Claude Code is doing right now. `idle` means there is no active turn; `done` is a
/// brief, attention-grabbing flash shown right after a turn finishes.
enum ClaudeActivityState: String, Sendable {
    // `done` = a turn that finished cleanly; `error` = a turn that ended on an API error
    // (Claude Code logged an `isApiErrorMessage` entry). Both are brief end-of-turn flashes,
    // but `error` reads red and never chimes/celebrates, so a failed turn isn't shown as a
    // green "Done".
    case idle, thinking, tool, awaitingPermission, done, error
}

/// A snapshot of the current activity, derived from the latest hook event.
struct ClaudeActivity: Equatable, Sendable {
    var state: ClaudeActivityState
    var label: String
    var tool: String?
    var session: String?
    var cwd: String?
    /// When the current turn began (drives the elapsed timer); nil while idle.
    var turnStartedAt: Date?

    static let idle = ClaudeActivity(state: .idle, label: "Idle", tool: nil,
                                     session: nil, cwd: nil, turnStartedAt: nil)
    var isActive: Bool { state != .idle }
}

/// One Claude session that is CURRENTLY IN A TURN (actively running), as opposed to an
/// open-but-idle window. Derived from the per-session hook state files, so "running" means
/// genuinely working - not just "a `claude` process exists".
struct ClaudeSessionActivity: Sendable, Identifiable, Equatable {
    var id: String { session }
    var session: String
    var state: ClaudeActivityState
    var label: String
    var tool: String?
    var cwd: String?
    var updatedAt: Date
    /// When this session's current turn began (drives the menu-bar uptime); nil if unknown.
    var startedAt: Date?
    /// Pretty model name for the current turn (e.g. "Opus 4.8"), resolved once from the
    /// transcript tail so the menu bar can show it without loading the heavy SessionStore.
    var model: String?
    /// Which Claude Code surface this session runs in (raw `CLAUDE_CODE_ENTRYPOINT`: the terminal
    /// vs a GUI app), used to label CLI vs app. nil if the hook didn't capture one (older
    /// installs, or the surface doesn't export it).
    var client: String?
    /// Last path component of the working directory, or "session" when unknown.
    var projectName: String { cwd.map { ($0 as NSString).lastPathComponent } ?? "session" }
}

// MARK: Tool -> label / glyph

enum ActivityLabels {
    /// Human label for the menu bar from a raw Claude Code tool name.
    static func label(forTool tool: String?) -> String {
        guard let t = tool, !t.isEmpty else { return "Working" }
        switch t {
        case "Read": return "Reading"
        case "Glob", "Grep": return "Searching"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Editing"
        case "Bash": return "Running command"
        case "WebFetch", "WebSearch": return "Browsing web"
        case "Task", "Agent": return "Delegating"
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "Planning"
        default:
            return t.hasPrefix("mcp__") ? "Using tool" : t
        }
    }

    /// SF Symbol shown alongside the label in the menu bar.
    static func symbol(for state: ClaudeActivityState, tool: String?) -> String {
        switch state {
        case .idle, .thinking: return "sparkle"
        case .awaitingPermission: return "exclamationmark.circle"
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .tool:
            switch tool {
            case "Read", "Glob", "Grep": return "magnifyingglass"
            case "Edit", "Write", "MultiEdit", "NotebookEdit": return "pencil"
            case "Bash": return "terminal"
            case "WebFetch", "WebSearch": return "globe"
            case "Task", "Agent": return "person.2"
            default: return "sparkle"
            }
        }
    }
}

// MARK: - Store

@MainActor
@Observable
final class ActivityService {
    /// The headline activity (the most-recently-updated running session), `.idle` when none
    /// is in a turn, briefly `.done` right after the LAST running session finishes.
    private(set) var current: ClaudeActivity = .idle
    /// Every session currently in a turn. Drives the menu bar "N running" + the panel
    /// breakdown - so they reflect actual work, not open-but-idle windows.
    private(set) var activeSessions: [ClaudeSessionActivity] = []
    /// Surfaced install/parse problems (e.g. settings.json isn't plain JSON).
    private(set) var lastError: String?

    // Mirrored in from AppModel when the user changes them.
    var completionSoundEnabled = false
    var completionSoundName = "hero-complete-soft"
    // Skip only trivial instant turns (a quick read, a one-line answer); any real turn chimes.
    var completionThreshold: TimeInterval = 10
    // Retains the AVAudioPlayer while a completion chime plays (a player deallocates - and
    // goes silent - the moment it's released). Kept preloaded across completions and only
    // rebuilt when the chosen sound changes, so playback is a rewind + play, not a
    // create-decode-play in a single tick (which can occasionally race and stay silent).
    private var completionPlayer: AVAudioPlayer?
    private var loadedSoundName: String?

    private var pollTask: Task<Void, Never>?
    // Per-session turn-start times (drives the elapsed timer + the completion-chime
    // threshold), keyed by Claude session id; pruned when a session's file disappears.
    private var sessionTurnStart: [String: Date] = [:]
    // Per-session pretty model name, resolved once from the transcript tail at turn start, so
    // the menu bar can show which model each running session uses (no heavy SessionStore).
    private var sessionModel: [String: String] = [:]
    // Whether the previous poll had at least one running session, so the transition to zero
    // can flash "Done" (+ confetti) exactly once.
    private var hadActive = false
    // Earliest start time among the running turns (so the completion chime measures the
    // longest turn, not whichever session updated last).
    private var oldestActiveStart: Date?
    // Clears the "Done" flash back to idle a few seconds after the last turn finishes.
    private var doneClearTask: Task<Void, Never>?

    // The lifecycle events we register. The core four (UserPromptSubmit, PreToolUse,
    // PostToolUse, Stop) plus Notification (permission) and session bookends. If a name
    // is unknown to the installed Claude Code version that hook simply never fires, which
    // is harmless.
    private let hookEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse",
                              "Notification", "Stop", "SessionStart", "SessionEnd"]

    // MARK: Paths

    private var home: String { NSHomeDirectory() }
    private var dirURL: URL { URL(fileURLWithPath: home).appendingPathComponent(".claude/cortex") }
    private var stateURL: URL { dirURL.appendingPathComponent("activity.json") }
    private var scriptURL: URL { dirURL.appendingPathComponent("activity-hook") }
    private var settingsURL: URL { URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json") }
    private var backupURL: URL { URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json.cortex-backup") }
    /// Substring that identifies our hook entries inside settings.json.
    private var scriptMarker: String { scriptURL.path }

    /// True when our script exists AND our hooks are registered in settings.json.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: scriptURL.path) && hooksPresent()
    }

    // MARK: Enable / disable

    /// Install the hooks + script and start polling. Returns an error message on failure
    /// (the caller should leave the preference off and surface it).
    @discardableResult
    func enable() -> String? {
        do {
            try installHooks()
            lastError = nil
        } catch {
            let msg = (error as? InstallError)?.message ?? error.localizedDescription
            lastError = msg
            return msg
        }
        startPolling()
        return nil
    }

    /// Stop polling, remove our hooks + script, and reset state.
    func disable() {
        stopPolling()
        doneClearTask?.cancel()
        try? uninstallHooks()
        removeArtifacts()
        current = .idle
        activeSessions = []
        sessionTurnStart = [:]
        hadActive = false
        lastError = nil
    }

    /// Start polling without reinstalling (used at launch when already enabled). Rewrites the
    /// hook script first so existing installs pick up new script behavior (e.g. per-session
    /// state files) without the user toggling the preference off and on.
    func resumeIfInstalled() {
        guard isInstalled else { return }
        try? Self.hookScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        startPolling()
    }

    // MARK: Polling

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Re-derive the running sessions from the per-session hook files each tick, then set the
    /// headline `current` and flash "Done" when the last running session finishes.
    private func poll() {
        let now = Date()
        let scan = scanActiveSessions(now: now)
        // Reassign @Observable state only when it actually changed, else every 500ms tick would
        // re-render the menu-bar image even while idle.
        if activeSessions != scan.sessions { activeSessions = scan.sessions }

        if let top = scan.sessions.first {
            doneClearTask?.cancel()
            let next = ClaudeActivity(state: top.state, label: top.label, tool: top.tool,
                                      session: top.session, cwd: top.cwd,
                                      turnStartedAt: sessionTurnStart[top.session])
            if current != next { current = next }
            // The earliest start among the running turns, so the completion chime reflects the
            // LONGEST turn, not whichever session merely updated most recently.
            oldestActiveStart = scan.sessions.compactMap { sessionTurnStart[$0.session] }.min()
            hadActive = true
        } else if hadActive {
            hadActive = false
            // Celebrate only when a turn actually ended (a Stop/idle event), not when the last
            // session was merely pruned for staleness (crashed / left mid-permission-prompt).
            if scan.endedNormally { finishTurnFlash(now: now, errored: scan.endedWithError) }
            else if current != .idle { current = .idle }
            oldestActiveStart = nil
        } else if current.state != .done, current.state != .error, current != .idle {
            current = .idle
        }
    }

    /// Scan `~/.claude/cortex/sessions/*.json` for sessions currently in a turn. Inactive
    /// (Stop/idle) or stale (crashed/abandoned > 30 min) files are deleted so the directory
    /// self-cleans. `endedNormally` is true when at least one tracked session ended via a real
    /// terminal event this tick (vs only staleness), so the caller flashes "Done" only for
    /// genuine completions. Also maintains per-session turn starts.
    private func scanActiveSessions(now: Date) -> (sessions: [ClaudeSessionActivity], endedNormally: Bool, endedWithError: Bool) {
        let dir = dirURL.appendingPathComponent("sessions")
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [ClaudeSessionActivity] = []
        var liveIDs = Set<String>()
        var endedNormally = false
        var endedWithError = false
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let sid = nonEmpty(obj["session"]) ?? file.deletingPathExtension().lastPathComponent
            let event = (obj["event"] as? String) ?? ""
            let tool = nonEmpty(obj["tool"])
            let cwd = nonEmpty(obj["cwd"])
            let note = nonEmpty(obj["note"]) ?? ""
            let transcript = nonEmpty(obj["transcript"])
            let client = nonEmpty(obj["client"])
            let ts = (obj["ts"] as? NSNumber)?.doubleValue ?? Double((obj["ts"] as? String) ?? "") ?? 0
            let eventDate = ts > 0 ? Date(timeIntervalSince1970: ts) : .distantPast

            let (state, label) = Self.interpret(event: event, tool: tool, note: note)
            // A real terminal event (Stop / SessionEnd / idle notification): turn finished.
            if state == .idle {
                try? fm.removeItem(at: file)
                if sessionTurnStart[sid] != nil {
                    endedNormally = true
                    // Distinguish a clean finish from an API error: Claude Code records the
                    // latter as an assistant entry flagged `isApiErrorMessage`, so a turn that
                    // "finished" on an error surfaces as .error (red), not a green Done.
                    if let transcript, Self.transcriptEndedInError(path: transcript) {
                        endedWithError = true
                    }
                }
                sessionTurnStart[sid] = nil
                sessionModel[sid] = nil
                continue
            }
            // Crashed / abandoned (incl. a long-unanswered permission prompt): drop after
            // 30 min, but do NOT treat that as a completion.
            if now.timeIntervalSince(eventDate) > 1800 {
                try? fm.removeItem(at: file)
                sessionTurnStart[sid] = nil
                sessionModel[sid] = nil
                continue
            }
            // First event of a turn: stamp its start and resolve the model once from the
            // transcript tail (reused for the rest of the turn, so the poll stays cheap).
            if sessionTurnStart[sid] == nil {
                sessionTurnStart[sid] = eventDate
                if let transcript { sessionModel[sid] = Self.transcriptModel(path: transcript) }
            }
            liveIDs.insert(sid)
            out.append(ClaudeSessionActivity(session: sid, state: state, label: label,
                                             tool: tool, cwd: cwd, updatedAt: eventDate,
                                             startedAt: sessionTurnStart[sid],
                                             model: sessionModel[sid],
                                             client: client))
        }
        sessionTurnStart = sessionTurnStart.filter { liveIDs.contains($0.key) }
        sessionModel = sessionModel.filter { liveIDs.contains($0.key) }
        return (out.sorted { $0.updatedAt > $1.updatedAt }, endedNormally, endedWithError)
    }

    /// Map a raw hook event to a state + label. `.idle` means "not in a turn".
    private static func interpret(event: String, tool: String?, note: String) -> (ClaudeActivityState, String) {
        switch event {
        case "UserPromptSubmit", "PostToolUse":
            return (.thinking, "Thinking")
        case "PreToolUse":
            return (.tool, ActivityLabels.label(forTool: tool))
        case "Notification":
            // A mid-turn notification is usually a permission prompt; an "idle" one means
            // the turn is over (waiting for the user).
            return note.localizedCaseInsensitiveContains("idle")
                ? (.idle, "Idle") : (.awaitingPermission, "Awaiting permission")
        default: // SessionStart (window opened, no turn yet), Stop, SessionEnd, unknown
            return (.idle, "Idle")
        }
    }

    /// Chime if the longest just-finished turn ran long enough, then flash "Done" (the confetti
    /// + green label are driven off `current.state == .done`) for a few seconds before idle.
    private func finishTurnFlash(now: Date, errored: Bool) {
        // A clean finish may chime; an errored turn never does (it isn't a "success").
        if !errored, completionSoundEnabled, let start = oldestActiveStart,
           now.timeIntervalSince(start) >= completionThreshold {
            playCompletionSound()
        }
        doneClearTask?.cancel()
        current = ClaudeActivity(state: errored ? .error : .done,
                                 label: errored ? "Error" : "Done", tool: nil,
                                 session: current.session, cwd: current.cwd, turnStartedAt: nil)
        // Hold the error flash a touch longer so a failed turn is actually noticed.
        let hold = errored ? 6.0 : 4.0
        doneClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled,
                  self?.current.state == .done || self?.current.state == .error else { return }
            self?.current = .idle
        }
    }

    /// Play the chosen completion chime from the bundled `.caf`. Preloaded + retained for the
    /// duration of playback. Falls back to the default pack, then the system "Glass" sound, if
    /// the asset is missing, so a bad name never leaves the completion silent.
    private func playCompletionSound() {
        // (Re)load only when the chosen sound changed - otherwise reuse the preloaded player.
        if completionPlayer == nil || loadedSoundName != completionSoundName {
            let url = Bundle.main.url(forResource: completionSoundName, withExtension: "caf")
                ?? Bundle.main.url(forResource: "hero-complete-soft", withExtension: "caf")
            guard let url, let player = try? AVAudioPlayer(contentsOf: url) else {
                NSSound(named: NSSound.Name("Glass"))?.play()
                return
            }
            player.prepareToPlay()
            completionPlayer = player
            loadedSoundName = completionSoundName
        }
        // Rewind so a rapid second completion re-triggers instead of being ignored mid-play.
        completionPlayer?.currentTime = 0
        completionPlayer?.play()
    }

    // MARK: Transcript tail (model + error classification)
    //
    // Claude Code records each turn to a JSONL transcript. The last `assistant` entry tells us
    // two things the lightweight per-session hook files can't: which model is running, and
    // whether the turn ended on an API error (flagged `isApiErrorMessage`). We read only the
    // file's tail so a huge transcript never stalls the 500ms poll, and only at turn start
    // (model) / turn end (error), not every tick.

    /// True when the transcript's most recent assistant entry is an API-error message.
    private static func transcriptEndedInError(path: String) -> Bool {
        (lastAssistantEntry(path: path)?["isApiErrorMessage"] as? Bool) == true
    }

    /// The pretty model name (e.g. "Opus 4.8") from the transcript's most recent assistant
    /// entry, or nil if unknown.
    private static func transcriptModel(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail: UInt64 = 32_768
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        // Scan newest-first for the last assistant entry carrying a REAL model. Some surfaces
        // interleave synthetic entries (model "<synthetic>"); skip those so the menu bar shows
        // the actual model, never the placeholder.
        for line in text.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let raw = (msg["model"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !raw.isEmpty, !raw.hasPrefix("<") else { continue }
            return CostService.displayName(raw)
        }
        return nil
    }

    /// The most recent `type == "assistant"` entry, parsed from the transcript's tail (last
    /// 32 KB). Scanning newest-first means a partial leading line simply fails to parse and is
    /// skipped. Returns nil on any read/parse failure (best-effort, never throws into the poll).
    private static func lastAssistantEntry(path: String) -> [String: Any]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail: UInt64 = 32_768
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (obj["type"] as? String) == "assistant" else { continue }
            return obj
        }
        return nil
    }

    private func nonEmpty(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    // MARK: Install / uninstall

    private struct InstallError: Error { let message: String }

    private func installHooks() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)

        // 1. Write the hook script and make it executable.
        try Self.hookScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // 2. Read settings.json (or start fresh). Refuse to clobber a non-JSON file.
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL), !data.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw InstallError(message: "~/.claude/settings.json isn't plain JSON, so Cortex won't edit it. Add the hooks manually or fix the file.")
            }
            root = parsed
            // 3. Back up once before our first write.
            if !fm.fileExists(atPath: backupURL.path) {
                try? data.write(to: backupURL, options: .atomic)
            }
        }

        // 4. Merge: strip any prior Cortex entries (idempotent), then add ours.
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        stripOurEntries(&hooks)
        for event in hookEvents {
            var arr = (hooks[event] as? [[String: Any]]) ?? []
            arr.append(ourEntry(event: event))
            hooks[event] = arr
        }
        root["hooks"] = hooks

        // 5. Write back atomically with stable key order (clean diffs).
        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: settingsURL, options: .atomic)
    }

    private func uninstallHooks() throws {
        guard let data = try? Data(contentsOf: settingsURL),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else { return }
        stripOurEntries(&hooks)
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: settingsURL, options: .atomic)
    }

    /// Delete the script + state file (and the dir if it ends up empty).
    private func removeArtifacts() {
        let fm = FileManager.default
        try? fm.removeItem(at: scriptURL)
        try? fm.removeItem(at: stateURL)
        try? fm.removeItem(at: dirURL.appendingPathComponent("sessions"))
        if let contents = try? fm.contentsOfDirectory(atPath: dirURL.path), contents.isEmpty {
            try? fm.removeItem(at: dirURL)
        }
    }

    /// One settings.json hook entry pointing at our script for the given event.
    private func ourEntry(event: String) -> [String: Any] {
        ["matcher": "",
         "hooks": [["type": "command", "command": "'\(scriptURL.path)' \(event)"]]]
    }

    /// Remove every hook entry whose command runs our script, pruning emptied arrays.
    private func stripOurEntries(_ hooks: inout [String: Any]) {
        for (event, value) in hooks {
            guard var arr = value as? [[String: Any]] else { continue }
            arr.removeAll { entry in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String)?.contains(scriptMarker) == true }
            }
            if arr.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = arr }
        }
    }

    /// Whether any of our hook entries are present in settings.json right now.
    private func hooksPresent() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            guard let arr = value as? [[String: Any]] else { continue }
            for entry in arr {
                if let inner = entry["hooks"] as? [[String: Any]],
                   inner.contains(where: { ($0["command"] as? String)?.contains(scriptMarker) == true }) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: Hook script
    //
    // POSIX sh, no jq / python3 dependency. The event name arrives as $1 (baked into the
    // settings.json command), so the script only extracts a few string fields from the
    // JSON on stdin via sed, then writes the latest event to the state file atomically.
    // Always exits 0 so a hook never blocks a tool call.

    private static let hookScript = #"""
    #!/bin/sh
    # Cortex live-activity hook. Records what Claude Code is doing to a state file that
    # the Cortex menu bar polls. Installed and removed by Cortex (Settings > Menu Bar);
    # safe to delete. Never blocks a tool: it always exits 0.
    event="$1"
    dir="$HOME/.claude/cortex"
    state="$dir/activity.json"
    mkdir -p "$dir" 2>/dev/null
    input="$(cat)"
    field() {
      printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
    }
    tool="$(field tool_name)"
    session="$(field session_id)"
    cwd="$(field cwd)"
    note="$(field notification_type)"
    transcript="$(field transcript_path)"
    # Which Claude Code surface fired this hook (the raw entrypoint: the terminal vs a GUI app).
    # It arrives as an inherited env var, not a stdin field, so the menu bar can label CLI vs app.
    client="${CLAUDE_CODE_ENTRYPOINT:-}"
    ts="$(date +%s)"
    payload="$(printf '{"event":"%s","tool":"%s","session":"%s","cwd":"%s","note":"%s","transcript":"%s","client":"%s","ts":%s}' \
      "$event" "$tool" "$session" "$cwd" "$note" "$transcript" "$client" "$ts")"
    # Latest-event file (the single most recent event across all sessions).
    tmp="$state.tmp.$$"
    printf '%s\n' "$payload" > "$tmp" 2>/dev/null
    mv -f "$tmp" "$state" 2>/dev/null
    # Per-session file so Cortex can tell how many sessions are ACTUALLY in a turn (not just
    # how many windows are open). One file per session id; Cortex prunes finished/stale ones.
    # Skip SessionStart: it fires on window-open AND mid-session (/clear, /compact, resume), so
    # writing it would wrongly clear a turn that is still in progress. UserPromptSubmit begins a
    # turn; a bare window-open then never gets a file (correctly counted as idle).
    if [ -n "$session" ] && [ "$event" != "SessionStart" ]; then
      sdir="$dir/sessions"
      mkdir -p "$sdir" 2>/dev/null
      stmp="$sdir/$session.json.tmp.$$"
      printf '%s\n' "$payload" > "$stmp" 2>/dev/null
      mv -f "$stmp" "$sdir/$session.json" 2>/dev/null
    fi
    exit 0
    """#
}

// MARK: - WorkflowMonitor
//
// Live progress of running Claude Code "dynamic workflows" for the menu bar: how many
// subagents have finished vs started. Claude Code journals each workflow run to
// ~/.claude/projects/<slug>/<session>/subagents/workflows/wf_*/journal.jsonl as a stream of
// {"type":"started"|"result","agentId":...} events. We report ONE entry per live run (its
// name, project, and launched-vs-completed agent counts) so concurrent workflows stay
// distinct; the menu bar shows a combined caption and the panel the per-run breakdown.
// Read-only; the directory walk runs off the main actor.

@MainActor
@Observable
final class WorkflowMonitor {
    /// One running dynamic workflow, tracked per-run so two concurrent workflows aren't blended
    /// into a single number: its run id, name (from the script file), the project it runs in,
    /// and how many subagents have finished vs launched.
    struct RunningWorkflow: Equatable, Sendable, Identifiable {
        var id: String          // run id (wf_…)
        var name: String?
        var project: String?
        var done: Int
        var total: Int
    }
    private(set) var workflows: [RunningWorkflow] = []
    private var task: Task<Void, Never>?

    /// Combined agent progress across every running workflow, for the compact menu-bar caption
    /// (the panel shows the per-workflow breakdown). nil when nothing is running.
    var aggregate: (done: Int, total: Int)? {
        guard !workflows.isEmpty else { return nil }
        return (workflows.reduce(0) { $0 + $1.done }, workflows.reduce(0) { $0 + $1.total })
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let found = await Task.detached(priority: .utility) { WorkflowMonitor.scan() }.value
                if Task.isCancelled { break }
                // Only publish on a real change so observers don't re-render every 3s.
                if self?.workflows != found { self?.workflows = found }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if !workflows.isEmpty { workflows = [] }
    }

    /// Find every running dynamic workflow, ONE entry per run. A run is live while agents are in
    /// flight (started > completed) - the journal only writes on agent start/result, so an active
    /// run can sit silent for seconds, which a tight mtime window would misread as finished - or
    /// it changed very recently; a staleness cap drops abandoned/stopped/finished runs.
    nonisolated static func scan() -> [RunningWorkflow] {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let slugs = try? fm.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        let now = Date()
        let staleCap: TimeInterval = 300   // ignore runs idle this long (finished / stopped / dead)
        let recentGap: TimeInterval = 15   // show briefly across between-phase gaps + on completion
        var out: [RunningWorkflow] = []

        for slug in slugs {
            // Each slug holds session DIRS (which may contain subagents/) plus transcript
            // .jsonl files; only the dirs can hold workflows.
            guard isDir(slug),
                  let sessions = try? fm.contentsOfDirectory(
                    at: slug, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { continue }
            // The slug encodes the project's path; decode it to a readable folder name.
            let project = URL(fileURLWithPath: SessionStore.decodeSlug(slug.lastPathComponent)).lastPathComponent
            for session in sessions where isDir(session) {
                let wfRoot = session.appendingPathComponent("subagents/workflows")
                guard let wfRuns = try? fm.contentsOfDirectory(
                    at: wfRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                else { continue }
                for run in wfRuns where run.lastPathComponent.hasPrefix("wf_") {
                    let journal = run.appendingPathComponent("journal.jsonl")
                    guard let mtime = (try? journal.resourceValues(
                            forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                          now.timeIntervalSince(mtime) < staleCap,
                          let content = try? String(contentsOf: journal, encoding: .utf8)
                    else { continue }
                    var started = Set<String>(), completed = Set<String>()
                    for line in content.split(separator: "\n") {
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = obj["type"] as? String,
                              let agentId = obj["agentId"] as? String else { continue }
                        if type == "started" { started.insert(agentId) }
                        else if type == "result" { completed.insert(agentId) }
                    }
                    let done = completed.intersection(started).count
                    let inFlight = started.count > done
                    guard !started.isEmpty, inFlight || now.timeIntervalSince(mtime) < recentGap
                    else { continue }
                    // Workflow name from its persisted script file (<session>/workflows/scripts/
                    // <name>-<runId>.js), which lives in a sibling subtree, not the run dir.
                    let runId = run.lastPathComponent
                    var name: String?
                    let scripts = session.appendingPathComponent("workflows/scripts")
                    if let files = try? fm.contentsOfDirectory(atPath: scripts.path),
                       let file = files.first(where: { $0.hasSuffix("-\(runId).js") }) {
                        name = String(file.dropLast(runId.count + 4)) // strip "-<runId>.js"
                    }
                    out.append(RunningWorkflow(id: runId, name: name, project: project,
                                               done: done, total: started.count))
                }
            }
        }
        return out.sorted { ($0.name ?? $0.id) < ($1.name ?? $1.id) }
    }

    private nonisolated static func isDir(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
