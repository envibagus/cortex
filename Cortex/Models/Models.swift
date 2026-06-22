import SwiftUI

// MARK: - Tool sources
//
// The AI coding tools Cortex knows about, kept Claude-centric since Cortex is
// built around Claude Code.

enum ToolKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case claude
    case codex
    case cursor
    case windsurf
    case copilot
    case amp
    case opencode
    case gemini
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .windsurf: "Windsurf"
        case .copilot: "Copilot"
        case .amp: "Amp"
        case .opencode: "OpenCode"
        case .gemini: "Gemini"
        case .custom: "Custom"
        }
    }

    var iconName: String {
        switch self {
        case .claude: "brain.head.profile"
        case .codex: "book.closed"
        case .cursor: "cursorarrow.rays"
        case .windsurf: "wind"
        case .copilot: "airplane"
        case .amp: "bolt"
        case .opencode: "terminal"
        case .gemini: "sparkles"
        case .custom: "folder"
        }
    }

    var tint: Color {
        switch self {
        case .claude: Theme.claude
        case .codex: .green
        case .cursor: .blue
        case .windsurf: .teal
        case .copilot: .purple
        case .amp: .pink
        case .opencode: .red
        case .gemini: .cyan
        case .custom: .gray
        }
    }
}

// MARK: - Config items (skills, agents, commands, rules)
//
// Skills, agents, commands and rules are all markdown-with-frontmatter on disk,
// so Cortex models them with one shape and discriminates with `kind`.

enum ConfigKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case skill
    case agent
    case command
    case rule
    case mcp
    case hook
    case memory
    case plugin
    case instruction

    var id: String { rawValue }

    var plural: String {
        switch self {
        case .skill: "Skills"
        case .agent: "Agents"
        case .command: "Commands"
        case .rule: "Rules"
        case .mcp: "MCP Servers"
        case .hook: "Hooks"
        case .memory: "Memory"
        case .plugin: "Plugins"
        case .instruction: "Instructions"
        }
    }

    var singular: String { String(plural.dropLast(plural.hasSuffix("s") ? 1 : 0)) }

    var icon: String {
        switch self {
        case .skill: "bolt"
        case .agent: "person.2"
        case .command: "terminal"
        case .rule: "list.bullet.rectangle"
        case .mcp: "server.rack"
        case .hook: "link"
        case .memory: "brain"
        case .plugin: "puzzlepiece.extension"
        case .instruction: "book.closed"
        }
    }
}

/// A skill / agent / command / rule discovered on disk.
struct ConfigItem: Identifiable, Sendable, Hashable {
    var id: String        // resolved path (stable identity)
    var name: String
    var detail: String    // description / first meaningful line
    var path: String
    var kind: ConfigKind
    var source: ToolKind
    var isGlobal: Bool
    var projectName: String?
    var fileSize: Int
    var modified: Date
    var content: String
    var frontmatter: [String: String]

    var scopeLabel: String { isGlobal ? "Global" : (projectName ?? "Project") }
}

extension Array where Element == ConfigItem {
    /// Order a list of ConfigItems by the app-wide library sort. `.name` is A-Z
    /// (case-insensitive); `.modified` is newest-first; `.size` is largest-first.
    /// Ties fall back to the name so the order stays stable.
    func sorted(by sort: LibrarySort) -> [ConfigItem] {
        switch sort {
        case .name:
            return sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .modified:
            return sorted {
                $0.modified == $1.modified
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : $0.modified > $1.modified
            }
        case .size:
            return sorted {
                $0.fileSize == $1.fileSize
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : $0.fileSize > $1.fileSize
            }
        }
    }
}

// MARK: - MCP servers

struct MCPServer: Identifiable, Sendable, Hashable {
    var id: String        // server name
    var name: String
    var transport: String // "stdio" | "sse" | "http"
    var command: String?  // for stdio
    var url: String?      // for sse / http
    var scope: String     // "user" | "project" | "global"
    var needsAuth: Bool
    var toolCount: Int     // best-effort count of exposed tools, 0 if unknown
}

extension Array where Element == MCPServer {
    /// Order MCP servers by the app-wide library sort. MCP servers have no on-disk
    /// modified date or file size, so `.modified` and `.size` are not available here:
    /// every order falls back to A-Z by name (a sensible, never-crashing default).
    func sorted(by sort: LibrarySort) -> [MCPServer] {
        sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Hooks

struct HookItem: Identifiable, Sendable, Hashable {
    var id: String
    var event: String     // SessionStart, PreToolUse, PostToolUse, Stop, ...
    var matcher: String?
    var command: String
    var source: String    // settings.json | settings.local.json | plugin name
}

// MARK: - Memory

struct MemoryItem: Identifiable, Sendable, Hashable {
    var id: String        // path
    var name: String
    var hook: String      // one-line summary / pointer text
    var path: String
    var scope: String     // "Global" | project name
    var modified: Date
    var sizeBytes: Int
}

extension Array where Element == MemoryItem {
    /// Order memory files by the app-wide library sort. `.name` is A-Z
    /// (case-insensitive); `.modified` is newest-first; `.size` is largest-first
    /// (by sizeBytes). Ties fall back to the name so the order stays stable.
    func sorted(by sort: LibrarySort) -> [MemoryItem] {
        switch sort {
        case .name:
            return sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .modified:
            return sorted {
                $0.modified == $1.modified
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : $0.modified > $1.modified
            }
        case .size:
            return sorted {
                $0.sizeBytes == $1.sizeBytes
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : $0.sizeBytes > $1.sizeBytes
            }
        }
    }
}

// MARK: - Sessions & usage

/// Token usage for a turn or aggregated across a session, parsed from
/// `message.usage` in session JSONL.
struct TokenUsage: Codable, Sendable, Equatable, Hashable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0

    var total: Int { input + output + cacheRead + cacheWrite }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }

    mutating func add(_ other: TokenUsage) { self = self + other }
}

/// One Claude Code session, aggregated from a single `*.jsonl` transcript.
struct ClaudeSession: Identifiable, Sendable, Hashable {
    var id: String            // sessionId / file stem
    var projectSlug: String   // directory name under ~/.claude/projects
    var projectPath: String   // decoded cwd
    var projectName: String   // last path component of projectPath
    var startedAt: Date
    var endedAt: Date
    var messageCount: Int
    var userMessageCount: Int
    var assistantMessageCount: Int
    var models: [String]      // model ids seen, most-used first
    var usage: TokenUsage
    var cost: Double
    var gitBranch: String?
    var lastPrompt: String?
    var fileURL: URL
    // The context the MOST RECENT assistant turn carried: that turn's input + cache-read
    // + cache-write tokens (the tokens actually sent to the model), straight from the
    // last transcript message. This absolute count IS real data and matches Claude's
    // /context numerator. We deliberately do NOT derive a "% of window": the 200K vs 1M
    // window size is a runtime setting Claude Code does not persist in the transcript
    // (the model is logged as plain "claude-opus-4-8" with no [1m] marker), so any
    // percentage would be a guess - and Opus ships in both sizes. 0 when none recorded.
    var lastContextTokens: Int = 0

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
    var primaryModel: String? { models.first }
}

// MARK: - Aggregated usage statistics (powers the dashboards)

/// One calendar day of activity.
struct DayActivity: Identifiable, Sendable, Hashable {
    var id: Date { date }
    var date: Date
    var sessions: Int
    var messages: Int
    var tokens: Int
    var cost: Double
}

/// One hour-of-day bucket (0...23) for the "When You Work" chart.
struct HourBucket: Identifiable, Sendable, Hashable {
    var id: Int { hour }
    var hour: Int
    var weight: Double   // normalized 0...1
    var messages: Int
}

/// One cell of the GitHub-style contribution heatmap.
struct HeatCell: Identifiable, Sendable, Hashable {
    var id: Date { date }
    var date: Date
    var count: Int
    var level: Int       // 0...4 intensity bucket
    var commits: Int = 0 // GitHub contributions that day (commits + PRs + issues + reviews); 0 when none
}

/// Spend grouped by model, for the "Cost by Model" chart.
struct ModelCost: Identifiable, Sendable, Hashable {
    var id: String { modelKey }
    var modelKey: String      // normalized family key, e.g. "opus-4-7"
    var display: String       // "Opus 4.7"
    var cost: Double
    var tokens: Int
    var tint: Color
}

/// Everything the dashboards render. Computed by `SessionStore`/`CostService`.
struct UsageStats: Sendable {
    var sessions: Int = 0
    var messages: Int = 0
    var totalTokens: Int = 0
    var totalCost: Double = 0
    var activeDays: Int = 0
    var currentStreak: Int = 0
    var longestStreak: Int = 0
    var peakHour: Int? = nil
    var favoriteModel: String? = nil      // display name
    var dailyActivity: [DayActivity] = []
    var hourly: [HourBucket] = []
    var heatmap: [HeatCell] = []
    var costByModel: [ModelCost] = []

    /// Filter window applied to a copy. `nil` days == all-time. `.today` is the current
    /// calendar day (start-of-day cutoff), handled specially by `SessionStore.stats`.
    enum Window: String, CaseIterable, Identifiable {
        case today = "Today"
        case days7 = "7d"
        case days30 = "30d"
        case all = "All"
        var id: String { rawValue }
        var days: Int? { switch self { case .all: nil; case .today: 1; case .days7: 7; case .days30: 30 } }
    }
}

// MARK: - Model pricing

struct ModelPricing: Codable, Sendable, Hashable {
    var input: Double      // USD per 1M tokens
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double
}

// MARK: - Repos

struct RepoInfo: Identifiable, Sendable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var currentBranch: String?
    var commitsToday: Int
    var uncommittedFiles: Int
    var behind: Int
    var ahead: Int
    var lastCommit: Date?
    var remoteURL: String?
    var isGitHub: Bool
    var skillCount: Int
    var agentCount: Int
    var hasClaudeMd: Bool
    var claudeMdLines: Int

    var hasSkills: Bool { skillCount > 0 }
    var hasAgents: Bool { agentCount > 0 }
    var isDirty: Bool { uncommittedFiles > 0 }
}

/// A repository on GitHub, fetched via `gh`.
struct GitHubRepo: Identifiable, Sendable, Hashable {
    var id: String { nameWithOwner }
    var nameWithOwner: String
    var name: String
    var owner: String
    var description: String?
    var isPrivate: Bool
    var isFork: Bool
    var stars: Int
    var language: String?
    var updatedAt: Date?
    var url: String
}

// MARK: - Ports

struct PortInfo: Identifiable, Sendable, Hashable {
    var id: String { "\(port)-\(pid)-\(family)" }
    var port: Int
    var pid: Int
    var command: String       // short command name from lsof
    var processName: String   // friendlier name
    var family: String        // "IPv4" | "IPv6"
    var user: String
    var project: String?      // resolved project dir name, if a known dev server

    var url: URL? { URL(string: "http://localhost:\(port)") }
}

// MARK: - Hygiene / insights

struct HygieneIssue: Identifiable, Sendable {
    enum Severity: Int, Sendable, Comparable {
        case info = 0, warning = 1, critical = 2
        static func < (l: Severity, r: Severity) -> Bool { l.rawValue < r.rawValue }
        // Orange + blue only (the distinct icon below carries the severity, not a
        // third color): info reads blue, warning and critical read orange.
        var tint: Color {
            switch self { case .info: Theme.blue; case .warning: Theme.orange; case .critical: Theme.orange }
        }
        var icon: String {
            switch self {
            case .info: "info.circle"
            case .warning: "exclamationmark.triangle"
            case .critical: "xmark.octagon"
            }
        }
    }
    enum Category: String, Sendable { case git, cost, config, memory, ports, session }

    var id: String
    var title: String
    var detail: String
    var severity: Severity
    var category: Category
    var badge: String?          // trailing pill text, e.g. "~$1.77/mo" or "Cost control"
    var badgeTint: Color?
    var route: Route?           // where tapping the row navigates
}

// MARK: - Chat

struct ChatMessage: Identifiable, Sendable, Equatable, Codable {
    enum Role: String, Sendable, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var createdAt: Date = Date()
    var isStreaming: Bool = false
    var cost: Double? = nil
    // Navigation CTAs the assistant attached to this reply (parsed out of a
    // ```cortex-action``` block); MessageBubble renders these as buttons.
    var actions: [ChatAction] = []
}

// MARK: - Chat action (assistant-emitted navigation CTA)
//
// The assistant can suggest an in-app jump by emitting a fenced `cortex-action`
// JSON block; ChatService parses it off the reply text into one of these and the
// message bubble renders a button. `route` is a Route rawValue; `search` / `scope`
// are optional hints the destination view pre-applies on appear (e.g. open Sessions
// already filtered to a project). Codable so it survives in saved conversations.

struct ChatAction: Identifiable, Sendable, Equatable, Codable {
    var id = UUID()
    var label: String      // button text, e.g. "Open Costs"
    var route: Route       // destination
    var search: String?    // optional query to pre-fill at the destination
    var scope: String?     // optional scope (project name) to pre-select

    private enum CodingKeys: String, CodingKey { case id, label, route, search, scope }
}

// MARK: - Chat conversation (persisted history)
//
// One saved Assistant conversation, written to Application Support so past chats can
// be reopened. The title is derived from the first user message; updatedAt drives the
// newest-first history order.

struct ChatConversation: Identifiable, Sendable, Codable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
}

// MARK: - Reusable formatting helpers

enum Fmt {
    static func compact(_ n: Int) -> String {
        let d = Double(n)
        switch d {
        case 1_000_000_000...: return String(format: "%.1fB", d / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", d / 1_000_000)
        case 1_000...: return String(format: "%.1fK", d / 1_000)
        default: return "\(n)"
        }
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func money(_ v: Double) -> String {
        if v >= 1000 { return "$" + grouped(Int(v.rounded())) }
        return String(format: "$%.2f", v)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "-" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func hourLabel(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        switch h {
        case 0: return "12 AM"
        case 12: return "12 PM"
        case 1..<12: return "\(h) AM"
        default: return "\(h - 12) PM"
        }
    }
}

// MARK: - Path helpers

extension String {
    /// An absolute path with the user's home directory replaced by `~` for display.
    /// The inverse of `NSString.expandingTildeInPath` used when scanning.
    var tildeAbbreviated: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}
