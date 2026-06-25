import Foundation
import AppKit

// MARK: - ActivityService
//
// Live "what is Claude Code doing right now" signal for the menu bar. Claude Code can
// run shell hooks on lifecycle events (a prompt submitted, a tool about to run, the turn
// finished, a permission prompt). This service installs a tiny hook script that records
// the latest event to ~/.claude/cortex/activity.json, then polls that file and turns the
// raw events into a friendly status ("Editing", "Running command", "Awaiting
// permission") plus a turn timer and an optional completion chime.
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
    case idle, thinking, tool, awaitingPermission, done
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
    /// The latest interpreted activity. `.idle` until a turn starts.
    private(set) var current: ClaudeActivity = .idle
    /// When the state file last changed (so the panel can show "live").
    private(set) var lastEventAt: Date?
    /// Surfaced install/parse problems (e.g. settings.json isn't plain JSON).
    private(set) var lastError: String?

    // Mirrored in from AppModel when the user changes them.
    var completionSoundEnabled = false
    var completionThreshold: TimeInterval = 60

    private var pollTask: Task<Void, Never>?
    private var lastProcessedKey: String?
    // Clears the green "Done" flash back to idle a few seconds after a turn finishes.
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
        lastProcessedKey = nil
        lastError = nil
    }

    /// Start polling without reinstalling (used at launch when already enabled).
    func resumeIfInstalled() {
        guard isInstalled else { return }
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

    /// Read the state file and apply the latest event if it is new.
    private func poll() {
        guard let data = try? Data(contentsOf: stateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let event = (obj["event"] as? String) ?? ""
        let tool = nonEmpty(obj["tool"])
        let session = nonEmpty(obj["session"])
        let cwd = nonEmpty(obj["cwd"])
        let note = nonEmpty(obj["note"]) ?? ""
        let ts = (obj["ts"] as? NSNumber)?.doubleValue ?? Double((obj["ts"] as? String) ?? "") ?? 0

        // Dedupe so we apply each distinct event once (same-second collisions are rare
        // and only cost a missed intermediate state, never the final one).
        let key = "\(event)|\(tool ?? "")|\(note)|\(ts)"
        guard key != lastProcessedKey else { return }
        lastProcessedKey = key

        let eventDate = ts > 0 ? Date(timeIntervalSince1970: ts) : Date()
        apply(event: event, tool: tool, session: session, cwd: cwd, note: note, eventDate: eventDate)
    }

    /// Turn one raw event into the current activity + handle turn timing and the chime.
    private func apply(event: String, tool: String?, session: String?, cwd: String?,
                       note: String, eventDate: Date) {
        lastEventAt = Date()
        // Any fresh activity ends a lingering "Done" flash.
        if event != "Stop" && event != "SessionEnd" { doneClearTask?.cancel() }
        switch event {
        case "UserPromptSubmit", "SessionStart":
            let start = current.turnStartedAt ?? eventDate
            current = ClaudeActivity(state: .thinking, label: "Thinking", tool: nil,
                                     session: session, cwd: cwd, turnStartedAt: start)
        case "PreToolUse":
            let start = current.turnStartedAt ?? eventDate
            current = ClaudeActivity(state: .tool, label: ActivityLabels.label(forTool: tool),
                                     tool: tool, session: session, cwd: cwd, turnStartedAt: start)
        case "PostToolUse":
            let start = current.turnStartedAt ?? eventDate
            current = ClaudeActivity(state: .thinking, label: "Thinking", tool: nil,
                                     session: session, cwd: cwd, turnStartedAt: start)
        case "Notification":
            // A mid-turn notification is usually a permission prompt. Some versions tag
            // an idle prompt ("waiting for you") which we treat as the turn ending.
            if note.localizedCaseInsensitiveContains("idle") {
                finishTurn(eventDate: eventDate)
            } else {
                current = ClaudeActivity(state: .awaitingPermission, label: "Awaiting permission",
                                         tool: tool, session: session, cwd: cwd,
                                         turnStartedAt: current.turnStartedAt)
            }
        case "Stop", "SessionEnd":
            finishTurn(eventDate: eventDate)
        default:
            break
        }
    }

    /// End the active turn: chime if it ran long enough, then flash a green "Done" for a
    /// few seconds (to grab attention) before going idle. A no-op turn goes straight idle.
    private func finishTurn(eventDate: Date) {
        let hadTurn = current.turnStartedAt != nil
        if completionSoundEnabled, let start = current.turnStartedAt,
           eventDate.timeIntervalSince(start) >= completionThreshold {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
        doneClearTask?.cancel()
        guard hadTurn else { current = .idle; return }
        current = ClaudeActivity(state: .done, label: "Done", tool: nil,
                                 session: current.session, cwd: current.cwd, turnStartedAt: nil)
        doneClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self?.current.state == .done else { return }
            self?.current = .idle
        }
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
    ts="$(date +%s)"
    tmp="$state.tmp.$$"
    printf '{"event":"%s","tool":"%s","session":"%s","cwd":"%s","note":"%s","ts":%s}\n' \
      "$event" "$tool" "$session" "$cwd" "$note" "$ts" > "$tmp" 2>/dev/null
    mv -f "$tmp" "$state" 2>/dev/null
    exit 0
    """#
}
