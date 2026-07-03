import Foundation
import SwiftUI

// MARK: - SessionStore
//
// Parses every Claude Code transcript under ~/.claude/projects - the main
// <slug>/<uuid>.jsonl files plus the subagent transcripts nested under
// <uuid>/subagents/ - into per-session summaries and day buckets, then derives
// the windowed usage statistics that drive the Readout and Sessions dashboards.
// Duplicate transcript lines for the same API response are billed once.
//
// Parsing happens off the main actor; results are published back on the main actor.

@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [ClaudeSession] = []
    private(set) var isLoading = false
    private(set) var lastScan: Date? = nil

    /// Per-day aggregates, keyed by startOfDay. Kept so windowed stats are exact.
    private var dayBuckets: [Date: DayBucket] = [:]

    /// Cumulative per-day, per-model token totals read from the Readout cost cache
    /// (~/.claude/readout-cost-cache.json). This survives Claude Code's transcript
    /// pruning, so it covers more history than live parsing. Used as the cost source,
    /// merged with live day buckets (live wins for days it still has).
    private var cacheUsage: [Date: [String: TokenUsage]] = [:]

    /// Per-file parse results from the previous scan, keyed by file path. A file whose
    /// mtime + size are unchanged is not re-read on the next scan, so a refresh only
    /// pays for transcripts that actually changed since the last one.
    private var fileCache: [String: FileCacheEntry] = [:]

    private let cost: CostService

    init(cost: CostService) { self.cost = cost }

    /// Drop all parsed transcript data to free memory (e.g. when the main window closes).
    /// `load()` rebuilds it fully on the next open.
    func clear() {
        sessions = []
        dayBuckets = [:]
        cacheUsage = [:]
        fileCache = [:]
        lastScan = nil
    }

    // MARK: - Loading

    func load() async {
        isLoading = true
        let pricing = cost.pricing
        let normalize = { (raw: String) in CostService.staticNormalizeKey(raw) }

        let cacheIn = fileCache
        let parsed = await Task.detached(priority: .userInitiated) {
            Self.parseAll(pricing: pricing, normalize: normalize, cache: cacheIn)
        }.value
        let cache = await Task.detached(priority: .utility) {
            Self.loadCostCache()
        }.value

        self.sessions = parsed.output.sessions.sorted { $0.endedAt > $1.endedAt }
        self.dayBuckets = parsed.output.dayBuckets
        self.fileCache = parsed.cache
        self.cacheUsage = cache
        self.lastScan = Date()
        self.isLoading = false
    }

    /// Parse ~/.claude/readout-cost-cache.json into per-day, per-model token totals.
    /// Shape: { days: { "yyyy-MM-dd": { "<modelId>": {input,output,cacheRead,cacheWrite} } } }.
    nonisolated static func loadCostCache() -> [Date: [String: TokenUsage]] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/readout-cost-cache.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let days = json["days"] as? [String: [String: [String: Any]]] else { return [:] }

        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current

        var out: [Date: [String: TokenUsage]] = [:]
        for (dateStr, models) in days {
            guard let date = df.date(from: dateStr) else { continue }
            let day = cal.startOfDay(for: date)
            var byModel: [String: TokenUsage] = [:]
            for (modelId, u) in models {
                let key = CostService.staticNormalizeKey(modelId)
                let usage = TokenUsage(
                    input: (u["input"] as? Int) ?? 0,
                    output: (u["output"] as? Int) ?? 0,
                    cacheRead: (u["cacheRead"] as? Int) ?? 0,
                    cacheWrite: (u["cacheWrite"] as? Int) ?? 0,
                    cacheWrite1h: (u["cacheWrite1h"] as? Int) ?? 0
                )
                byModel[key, default: TokenUsage()].add(usage)
            }
            out[day] = byModel
        }
        return out
    }

    // MARK: - Windowed statistics

    /// Lightweight cost + token totals for a window (no heatmaps / series), for the
    /// small usage-breakdown rows. Mirrors the cost-coverage merge `stats` uses (live
    /// day usage + the cumulative cache) so pruned historical days still count.
    func totals(window: UsageStats.Window) -> (cost: Double, tokens: Int) {
        let cal = Calendar.current
        let cutoff: Date?
        switch window {
        case .all: cutoff = nil
        case .today: cutoff = cal.startOfDay(for: Date())
        default: cutoff = window.days.map { cal.date(byAdding: .day, value: -$0, to: Date())! }
        }
        var usageByModel: [String: TokenUsage] = [:]
        for day in Set(dayBuckets.keys).union(cacheUsage.keys) {
            if let cutoff, day < cutoff { continue }
            let perModel = dayBuckets[day]?.usageByModel ?? cacheUsage[day] ?? [:]
            for (m, u) in perModel { usageByModel[m, default: TokenUsage()].add(u) }
        }
        let tokens = usageByModel.values.reduce(0) { $0 + $1.total }
        let cost = usageByModel.reduce(0.0) { acc, kv in
            let p = pricingFor(kv.key), u = kv.value
            return acc + Double(u.input) / 1_000_000 * p.input + Double(u.output) / 1_000_000 * p.output
                + Double(u.cacheRead) / 1_000_000 * p.cacheRead + Double(u.cacheWrite) / 1_000_000 * p.cacheWrite
                + Double(u.cacheWrite1h) / 1_000_000 * p.cacheWrite1h
        }
        return (cost, tokens)
    }

    func stats(window: UsageStats.Window = .all) -> UsageStats {
        let cal = Calendar.current
        // `.today` cuts off at the start of the current calendar day; the day-count
        // windows count back N days from now; `.all` has no cutoff.
        let cutoff: Date?
        switch window {
        case .all: cutoff = nil
        case .today: cutoff = cal.startOfDay(for: Date())
        default: cutoff = window.days.map { cal.date(byAdding: .day, value: -$0, to: Date())! }
        }
        let buckets = dayBuckets.values
            .filter { cutoff == nil || $0.date >= cutoff! }
            .sorted { $0.date < $1.date }

        var stats = UsageStats()
        var sessionIds = Set<String>()
        var usageByModel: [String: TokenUsage] = [:]
        var hourly = [Int](repeating: 0, count: 24)

        for b in buckets {
            sessionIds.formUnion(b.sessions)
            stats.messages += b.userMsgs + b.assistantMsgs
            for h in 0..<24 { hourly[h] += b.hourly[h] }
        }
        stats.sessions = sessionIds.count

        // Cost coverage: merge live day usage with the cumulative cache so pruned
        // historical days still count toward spend. Live wins for days it still has
        // (it is fresher); the cache fills in days transcripts have lost.
        for day in Set(dayBuckets.keys).union(cacheUsage.keys) {
            if let cutoff, day < cutoff { continue }
            let perModel = dayBuckets[day]?.usageByModel ?? cacheUsage[day] ?? [:]
            for (m, u) in perModel { usageByModel[m, default: TokenUsage()].add(u) }
        }
        stats.totalTokens = usageByModel.values.reduce(0) { $0 + $1.total }
        stats.totalCost = usageByModel.reduce(0.0) { acc, kv in
            let p = pricingFor(kv.key), u = kv.value
            return acc + Double(u.input) / 1_000_000 * p.input + Double(u.output) / 1_000_000 * p.output
                + Double(u.cacheRead) / 1_000_000 * p.cacheRead + Double(u.cacheWrite) / 1_000_000 * p.cacheWrite
                + Double(u.cacheWrite1h) / 1_000_000 * p.cacheWrite1h
        }
        stats.activeDays = buckets.filter { $0.userMsgs + $0.assistantMsgs > 0 }.count

        // Daily activity series
        stats.dailyActivity = buckets.map {
            DayActivity(date: $0.date, sessions: $0.sessions.count,
                        messages: $0.userMsgs + $0.assistantMsgs,
                        tokens: $0.usageByModel.values.reduce(0) { $0 + $1.total },
                        cost: $0.cost)
        }

        // Streaks
        let activeDates = Set(buckets.filter { $0.userMsgs + $0.assistantMsgs > 0 }.map { $0.date })
        (stats.currentStreak, stats.longestStreak) = Self.streaks(activeDates: activeDates, calendar: cal)

        // Hourly + peak
        if let peak = hourly.indices.max(by: { hourly[$0] < hourly[$1] }), hourly[peak] > 0 {
            stats.peakHour = peak
        }
        let maxHour = max(hourly.max() ?? 1, 1)
        stats.hourly = (0..<24).map { HourBucket(hour: $0, weight: Double(hourly[$0]) / Double(maxHour), messages: hourly[$0]) }

        // Favorite model (by tokens)
        if let fav = usageByModel.max(by: { $0.value.total < $1.value.total })?.key {
            stats.favoriteModel = CostService.displayName(fav)
        }

        // Cost by model
        stats.costByModel = usageByModel.map { key, usage in
            let p = pricingFor(key)
            let c = Double(usage.input) / 1_000_000 * p.input
                + Double(usage.output) / 1_000_000 * p.output
                + Double(usage.cacheRead) / 1_000_000 * p.cacheRead
                + Double(usage.cacheWrite) / 1_000_000 * p.cacheWrite
                + Double(usage.cacheWrite1h) / 1_000_000 * p.cacheWrite1h
            return ModelCost(modelKey: key, display: CostService.displayName(key),
                             cost: c, tokens: usage.total, tint: Self.tint(for: key))
        }
        .sorted { $0.cost > $1.cost }

        // Heatmap: a generous range; the view trims to the most-recent weeks that fit.
        stats.heatmap = Self.heatmap(buckets: dayBuckets, calendar: cal)

        return stats
    }

    /// Ranked skill / MCP / plugin / subagent usage for a window, grouped by kind.
    /// Each kind's array is sorted most-used first. Derived from live transcripts only
    /// (the cost cache doesn't carry attribution), so it covers unpruned history.
    func attribution(window: UsageStats.Window = .all) -> [AttributionKind: [AttributionStat]] {
        let cal = Calendar.current
        let cutoff: Date?
        switch window {
        case .all: cutoff = nil
        case .today: cutoff = cal.startOfDay(for: Date())
        default: cutoff = window.days.map { cal.date(byAdding: .day, value: -$0, to: Date())! }
        }
        var merged: [AttributionKind: [String: Int]] = [:]
        for (day, bucket) in dayBuckets {
            if let cutoff, day < cutoff { continue }
            for (kindRaw, names) in bucket.attribution {
                guard let kind = AttributionKind(rawValue: kindRaw) else { continue }
                for (name, count) in names { merged[kind, default: [:]][name, default: 0] += count }
            }
        }
        return merged.reduce(into: [:]) { out, kv in
            out[kv.key] = kv.value
                .map { AttributionStat(kind: kv.key, name: $0.key, count: $0.value) }
                .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
        }
    }

    private func pricingFor(_ key: String) -> ModelPricing { cost.price(for: key) }

    // Per-model chart tint. Uses DIRECT Color values (not Theme hue tokens) so the
    // cost / token-share charts keep their distinct multi-color legend even though the
    // rest of the UI is collapsed to orange + blue.
    private static func tint(for key: String) -> Color {
        if key.hasPrefix("opus") { return .yellow }
        if key.hasPrefix("sonnet") { return .green }
        if key.hasPrefix("haiku") { return .blue }
        return .purple
    }

    // MARK: - Streak math

    static func streaks(activeDates: Set<Date>, calendar cal: Calendar) -> (current: Int, longest: Int) {
        guard !activeDates.isEmpty else { return (0, 0) }
        let sorted = activeDates.sorted()
        var longest = 1, run = 1
        for i in 1..<sorted.count {
            if let next = cal.date(byAdding: .day, value: 1, to: sorted[i - 1]), next == sorted[i] {
                run += 1
            } else { run = 1 }
            longest = max(longest, run)
        }
        // Current streak counts back from today (or yesterday).
        var current = 0
        var cursor = cal.startOfDay(for: Date())
        if !activeDates.contains(cursor) {
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }
        while activeDates.contains(cursor) {
            current += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }
        return (current, longest)
    }

    // MARK: - Heatmap

    // ~150 weeks of cells (1050 days). The heatmap view shows only the most-recent
    // columns that fit the card and pins today to the right edge, so generating a
    // generous range lets it fill even a wide window with grid cells (gray for the
    // pre-activity days) instead of leaving bare card beside a fixed 52-week grid.
    static func heatmap(buckets: [Date: DayBucket], calendar cal: Calendar) -> [HeatCell] {
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -1049, to: today) else { return [] }
        var cells: [HeatCell] = []
        var d = start
        // Count SESSIONS per day (GitHub-style: one session ~ one contribution), not
        // raw message volume - message counts run into the thousands per day and read
        // wrong as "contributions". Percentile-bucket the per-day session counts.
        let counts = buckets.values.map { $0.sessions.count }.filter { $0 > 0 }.sorted()
        let q = { (p: Double) -> Int in counts.isEmpty ? 0 : counts[min(counts.count - 1, Int(Double(counts.count) * p))] }
        let t1 = q(0.25), t2 = q(0.5), t3 = q(0.8)
        while d <= today {
            let c = buckets[d].map { $0.sessions.count } ?? 0
            let level: Int = c == 0 ? 0 : (c <= t1 ? 1 : (c <= t2 ? 2 : (c <= t3 ? 3 : 4)))
            cells.append(HeatCell(date: d, count: c, level: level))
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        return cells
    }

    // MARK: - Parsing (off-main)

    struct DayBucket {
        var date: Date
        var sessions: Set<String> = []
        var userMsgs = 0
        var assistantMsgs = 0
        var usageByModel: [String: TokenUsage] = [:]
        var hourly = [Int](repeating: 0, count: 24)
        var cost = 0.0
        // Attribution counts for the day, keyed by AttributionKind.rawValue -> name ->
        // number of messages attributed to it. Drives the windowed Skills & Tools panel.
        var attribution: [String: [String: Int]] = [:]
    }

    nonisolated struct ParseOutput {
        var sessions: [ClaudeSession]
        var dayBuckets: [Date: DayBucket]
    }

    private nonisolated struct Line: Decodable {
        var type: String?
        var timestamp: String?
        var cwd: String?
        var gitBranch: String?
        var sessionId: String?
        var requestId: String?
        var lastPrompt: String?
        // Session naming + provenance (envelope-level, see ClaudeSession).
        var slug: String?
        var aiTitle: String?
        var entrypoint: String?
        var version: String?
        // Per-message attribution: which skill / plugin / MCP server / MCP tool /
        // named subagent produced this turn (see AttributionKind).
        var attributionSkill: String?
        var attributionPlugin: String?
        var attributionMcpServer: String?
        var attributionMcpTool: String?
        var agentName: String?
        var message: Msg?
    }
    private nonisolated struct Msg: Decodable {
        var id: String?
        var role: String?
        var model: String?
        var usage: Usage?
    }
    private nonisolated struct Usage: Decodable {
        var input_tokens: Int?
        var output_tokens: Int?
        var cache_read_input_tokens: Int?
        var cache_creation_input_tokens: Int?
        var cache_creation: CacheCreation?
    }
    /// Per-TTL cache-write breakdown; 5m and 1h writes bill at different rates.
    private nonisolated struct CacheCreation: Decodable {
        var ephemeral_5m_input_tokens: Int?
        var ephemeral_1h_input_tokens: Int?
    }

    // MARK: - Incremental parsing
    //
    // parseAll runs in two phases. Phase 1 extracts per-file "facts" - envelope
    // metadata, per-day message counts, attribution tallies, and the file's assistant
    // turns after in-file streaming dedup. Facts depend only on that one file, so
    // they are cached by (path, mtime, size) and reused until the file changes on
    // disk. Phase 2 merges facts in a deterministic order, applying the cross-file
    // billing dedup (one API response billed once across ALL transcripts) exactly as
    // the line-by-line parse did. Files are streamed via JSONLines, so no transcript
    // is ever fully resident in memory.

    /// Facts extracted from ONE transcript file, independent of every other file.
    /// Cross-file billing dedup happens later, in the merge phase.
    nonisolated struct FileFacts: Sendable {
        // Envelope metadata (collected only for a session's main transcript).
        var cwd: String?
        var branch: String?
        var lastPrompt: String?
        var slug: String?
        var aiTitle: String?
        var entrypoint: String?
        var version: String?
        var first: Date?
        var last: Date?
        var userCount = 0
        /// Per-day user-message counts (messages without a timestamp count toward `userCount` only).
        var userMsgsByDay: [Date: Int] = [:]
        /// Attribution tallies: day -> kind raw value -> name -> count.
        var attribution: [Date: [String: [String: Int]]] = [:]
        /// Assistant responses after in-file streaming dedup, in file order.
        var turns: [Turn] = []

        struct Turn: Sendable {
            /// Stable hash of "messageId|requestId" for cross-file billing dedup;
            /// nil when the line carried no message id (such turns always bill).
            var keyHash: UInt64?
            var model: String
            var usage: TokenUsage
            var date: Date?
            var day: Date?
            var hour: Int
        }
    }

    nonisolated struct FileCacheEntry: Sendable {
        var modified: Date
        var size: Int
        var facts: FileFacts
    }

    /// FNV-1a 64-bit over the key's UTF-8 bytes. Deterministic (unlike Hasher's
    /// per-process seeded hashes), so cached turns keep valid dedup keys across
    /// scans. Collisions are astronomically unlikely at this population
    /// (~10^5 keys in a 2^64 space).
    private nonisolated static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h
    }

    /// Phase 1: stream one transcript and extract its facts.
    /// Returns nil when the file could not be opened (nothing is cached then, so a
    /// later scan retries instead of remembering an empty result).
    private nonisolated static func extractFacts(
        url: URL,
        isMain: Bool,
        decoder: JSONDecoder,
        iso: ISO8601DateFormatter,
        isoPlain: ISO8601DateFormatter,
        cal: Calendar,
        normalize: (String) -> String
    ) -> FileFacts? {
        var f = FileFacts()
        var pending: [FileFacts.Turn] = []
        var pendingIndex: [String: Int] = [:]

        func parseDate(_ s: String?) -> Date? {
            guard let s else { return nil }
            return iso.date(from: s) ?? isoPlain.date(from: s)
        }

        let opened = JSONLines.forEachLine(in: url) { data in
            guard let line = try? decoder.decode(Line.self, from: data) else { return true }
            if isMain {
                if f.cwd == nil, let c = line.cwd { f.cwd = c }
                if let b = line.gitBranch, !b.isEmpty { f.branch = b }
                if let lp = line.lastPrompt, !lp.isEmpty { f.lastPrompt = lp }
                if f.slug == nil, let s = line.slug, !s.isEmpty { f.slug = s }
                if let t = line.aiTitle, !t.isEmpty { f.aiTitle = t }
                if f.entrypoint == nil, let e = line.entrypoint, !e.isEmpty { f.entrypoint = e }
                if let v = line.version, !v.isEmpty { f.version = v }
            }

            let date = parseDate(line.timestamp)
            if isMain, let date {
                if f.first == nil || date < f.first! { f.first = date }
                if f.last == nil || date > f.last! { f.last = date }
            }
            let day = date.map { cal.startOfDay(for: $0) }

            if let day {
                func bump(_ kind: AttributionKind, _ name: String?) {
                    guard let name, !name.isEmpty else { return }
                    f.attribution[day, default: [:]][kind.rawValue, default: [:]][name, default: 0] += 1
                }
                bump(.skill, line.attributionSkill)
                bump(.plugin, line.attributionPlugin)
                bump(.mcpServer, line.attributionMcpServer)
                bump(.mcpTool, line.attributionMcpTool)
                bump(.subagent, line.agentName)
            }

            switch line.type {
            case "user":
                guard isMain else { break }
                f.userCount += 1
                if let day { f.userMsgsByDay[day, default: 0] += 1 }
            case "assistant":
                let modelKey = line.message?.model.map(normalize) ?? "unknown"
                var u = TokenUsage()
                if let mu = line.message?.usage {
                    // Cache writes split by TTL when the breakdown is present
                    // (5m and 1h bill at different rates); older transcripts
                    // carry only the total, treated as 5m.
                    let cw5m: Int, cw1h: Int
                    if let cc = mu.cache_creation {
                        cw5m = cc.ephemeral_5m_input_tokens ?? 0
                        cw1h = cc.ephemeral_1h_input_tokens ?? 0
                    } else {
                        cw5m = mu.cache_creation_input_tokens ?? 0
                        cw1h = 0
                    }
                    u = TokenUsage(
                        input: mu.input_tokens ?? 0,
                        output: mu.output_tokens ?? 0,
                        cacheRead: mu.cache_read_input_tokens ?? 0,
                        cacheWrite: cw5m,
                        cacheWrite1h: cw1h
                    )
                }
                let key = line.message?.id.map { "\($0)|\(line.requestId ?? "")" }
                if let key {
                    if let idx = pendingIndex[key] {
                        // Later line of the same streamed response: token
                        // counts are cumulative, so the newest wins.
                        pending[idx].model = modelKey
                        pending[idx].usage = u
                        return true
                    }
                    pendingIndex[key] = pending.count
                }
                pending.append(FileFacts.Turn(
                    keyHash: key.map(Self.fnv1a),
                    model: modelKey,
                    usage: u,
                    date: date,
                    day: day,
                    hour: date.map { cal.component(.hour, from: $0) } ?? 0
                ))
            default:
                break
            }
            return true
        }
        guard opened else { return nil }

        f.turns = pending
        return f
    }

    /// Parse every transcript under ~/.claude/projects into sessions + day buckets.
    /// `cache` carries per-file facts from the previous scan; files whose mtime and
    /// size are unchanged are not re-read. Returns the fresh cache alongside the
    /// output (files that vanished from disk drop out because the cache is rebuilt
    /// from the current walk).
    nonisolated static func parseAll(
        pricing: [String: ModelPricing],
        normalize: (String) -> String,
        cache: [String: FileCacheEntry]
    ) -> (output: ParseOutput, cache: [String: FileCacheEntry]) {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let projectDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return (ParseOutput(sessions: [], dayBuckets: [:]), [:])
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        let cal = Calendar.current
        let decoder = JSONDecoder()

        func priceOf(_ key: String) -> ModelPricing {
            CostService.price(forKey: key, in: pricing)
        }
        func costOf(_ u: TokenUsage, _ p: ModelPricing) -> Double {
            Double(u.input) / 1e6 * p.input + Double(u.output) / 1e6 * p.output
                + Double(u.cacheRead) / 1e6 * p.cacheRead + Double(u.cacheWrite) / 1e6 * p.cacheWrite
                + Double(u.cacheWrite1h) / 1e6 * p.cacheWrite1h
        }

        var sessions: [ClaudeSession] = []
        var dayBuckets: [Date: DayBucket] = [:]
        var newCache: [String: FileCacheEntry] = [:]
        newCache.reserveCapacity(max(cache.count, 64))
        // One API response can span several transcript lines and files (streamed
        // content blocks, resumed sessions copying earlier lines). Each hashed
        // (message id, request id) pair bills exactly once across ALL transcripts.
        // The walk below is fully sorted so the same file claims a duplicated
        // response on every scan, keeping per-session numbers stable.
        var billedResponses = Set<UInt64>()

        for projectDir in projectDirs.sorted(by: { $0.path < $1.path }) {
            guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }

            // A session's transcripts span multiple files: the main <sessionId>.jsonl at
            // the top level plus subagent transcripts under <sessionId>/subagents/
            // (possibly nested further). Group them so subagent tokens and cost roll into
            // the parent session and the day buckets.
            guard let enumerator = fm.enumerator(at: projectDir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            var groups: [String: (main: URL?, subs: [URL])] = [:]
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                let rel = file.path.dropFirst(projectDir.path.count).split(separator: "/").map(String.init)
                if rel.count <= 1 {
                    groups[file.deletingPathExtension().lastPathComponent, default: (nil, [])].main = file
                } else {
                    groups[rel[0], default: (nil, [])].subs.append(file)
                }
            }

            for (sessionId, group) in groups.sorted(by: { $0.key < $1.key }) {
                var first: Date?, last: Date?
                var userCount = 0, assistantCount = 0
                var usage = TokenUsage(), totalCost = 0.0
                var modelCount: [String: Int] = [:]
                var usageByModel: [String: TokenUsage] = [:]
                var cwd: String?, branch: String?, lastPrompt: String?
                var slug: String?, aiTitle: String?, entrypoint: String?, version: String?
                var lastContextTokens = 0

                // Main transcript first: session metadata, message counts, and the
                // hourly activity clock come from it alone; subagent transcripts
                // contribute tokens, cost, and attribution.
                var files: [(url: URL, isMain: Bool)] = []
                if let main = group.main { files.append((main, true)) }
                files += group.subs.sorted { $0.path < $1.path }.map { ($0, false) }

                for (file, isMain) in files {
                    // Phase 1: cached facts when mtime + size are unchanged, else re-extract.
                    let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let modified = attrs?.contentModificationDate
                    let size = attrs?.fileSize
                    let facts: FileFacts
                    if let modified, let size, let hit = cache[file.path],
                       hit.modified == modified, hit.size == size {
                        facts = hit.facts
                    } else if let fresh = autoreleasepool(invoking: { Self.extractFacts(
                        url: file, isMain: isMain, decoder: decoder,
                        iso: iso, isoPlain: isoPlain, cal: cal, normalize: normalize) }) {
                        facts = fresh
                    } else {
                        continue // unreadable file: same as the legacy skip, and not cached
                    }
                    if let modified, let size {
                        newCache[file.path] = FileCacheEntry(modified: modified, size: size, facts: facts)
                    }

                    // Phase 2: merge this file's facts into the session + day buckets.
                    if isMain {
                        cwd = facts.cwd
                        branch = facts.branch
                        lastPrompt = facts.lastPrompt
                        slug = facts.slug
                        aiTitle = facts.aiTitle
                        entrypoint = facts.entrypoint
                        version = facts.version
                        first = facts.first
                        last = facts.last
                        userCount = facts.userCount
                    }
                    for (day, n) in facts.userMsgsByDay {
                        dayBuckets[day, default: DayBucket(date: day)].userMsgs += n
                        dayBuckets[day]?.sessions.insert(sessionId)
                    }
                    for (day, kinds) in facts.attribution {
                        for (kind, names) in kinds {
                            for (name, n) in names {
                                dayBuckets[day, default: DayBucket(date: day)]
                                    .attribution[kind, default: [:]][name, default: 0] += n
                            }
                        }
                    }
                    for turn in facts.turns {
                        if let kh = turn.keyHash {
                            if billedResponses.contains(kh) { continue }
                            billedResponses.insert(kh)
                        }
                        modelCount[turn.model, default: 0] += 1
                        usage.add(turn.usage)
                        usageByModel[turn.model, default: TokenUsage()].add(turn.usage)
                        let c = costOf(turn.usage, priceOf(turn.model))
                        totalCost += c
                        if isMain {
                            assistantCount += 1
                            // Context size of THIS turn (input side only: output isn't part
                            // of the window). Overwritten each turn -> ends on the latest.
                            let turnContext = turn.usage.input + turn.usage.cacheRead + turn.usage.cacheWriteTotal
                            if turnContext > 0 { lastContextTokens = turnContext }
                        }
                        if let day = turn.day {
                            dayBuckets[day, default: DayBucket(date: day)]
                                .usageByModel[turn.model, default: TokenUsage()].add(turn.usage)
                            dayBuckets[day]?.cost += c
                            if isMain, turn.date != nil {
                                dayBuckets[day]?.assistantMsgs += 1
                                dayBuckets[day]?.sessions.insert(sessionId)
                                dayBuckets[day]?.hourly[turn.hour] += 1
                            }
                        }
                    }
                }

                guard assistantCount + userCount > 0, let start = first, let end = last,
                      let mainFile = group.main else { continue }
                // Skip Cortex's OWN summary-generation sessions: the Claude CLI summary
                // backend runs `claude -p` per summary, which logs a transcript here. Those
                // would otherwise show up as junk "You summarize a coding session..." rows.
                if let lp = lastPrompt, SummaryBackend.isCortexSummaryPrompt(lp) { continue }
                let path = cwd ?? Self.decodeSlug(projectDir.lastPathComponent)
                let session = ClaudeSession(
                    id: sessionId,
                    projectSlug: projectDir.lastPathComponent,
                    projectPath: path,
                    projectName: URL(fileURLWithPath: path).lastPathComponent,
                    startedAt: start,
                    endedAt: end,
                    messageCount: userCount + assistantCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    models: modelCount.sorted { $0.value > $1.value }.map { $0.key },
                    usage: usage,
                    cost: totalCost,
                    gitBranch: branch,
                    lastPrompt: lastPrompt,
                    fileURL: mainFile,
                    lastContextTokens: lastContextTokens,
                    slug: slug,
                    aiTitle: aiTitle,
                    entrypoint: entrypoint,
                    version: version
                )
                sessions.append(session)
            }
        }

        return (ParseOutput(sessions: sessions, dayBuckets: dayBuckets), newCache)
    }

    /// Best-effort decode of a project slug back into a path.
    nonisolated static func decodeSlug(_ slug: String) -> String {
        // Slugs replace "/" with "-"; we cannot perfectly recover dashes in names,
        // but reconstructing with "/" gives a readable, usually-correct path.
        "/" + slug.split(separator: "-").joined(separator: "/")
    }
}
