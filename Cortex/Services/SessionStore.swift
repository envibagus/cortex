import Foundation
import SwiftUI

// MARK: - SessionStore
//
// Parses every Claude Code transcript under ~/.claude/projects/<slug>/<uuid>.jsonl
// into per-session summaries and day buckets, then derives the windowed usage
// statistics that drive the Readout and Sessions dashboards.
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

    private let cost: CostService

    init(cost: CostService) { self.cost = cost }

    // MARK: - Loading

    func load() async {
        isLoading = true
        let pricing = cost.pricing
        let normalize = { (raw: String) in CostService.staticNormalizeKey(raw) }

        let parsed = await Task.detached(priority: .userInitiated) {
            Self.parseAll(pricing: pricing, normalize: normalize)
        }.value
        let cache = await Task.detached(priority: .utility) {
            Self.loadCostCache()
        }.value

        self.sessions = parsed.sessions.sorted { $0.endedAt > $1.endedAt }
        self.dayBuckets = parsed.dayBuckets
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
                    cacheWrite: (u["cacheWrite"] as? Int) ?? 0
                )
                byModel[key, default: TokenUsage()].add(usage)
            }
            out[day] = byModel
        }
        return out
    }

    // MARK: - Windowed statistics

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
            let c = Double(usage.input) / 1_000_000 * (pricingFor(key).input)
                + Double(usage.output) / 1_000_000 * (pricingFor(key).output)
                + Double(usage.cacheRead) / 1_000_000 * (pricingFor(key).cacheRead)
                + Double(usage.cacheWrite) / 1_000_000 * (pricingFor(key).cacheWrite)
            return ModelCost(modelKey: key, display: CostService.displayName(key),
                             cost: c, tokens: usage.total, tint: Self.tint(for: key))
        }
        .sorted { $0.cost > $1.cost }

        // Heatmap: a generous range; the view trims to the most-recent weeks that fit.
        stats.heatmap = Self.heatmap(buckets: dayBuckets, calendar: cal)

        return stats
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
        var lastPrompt: String?
        var message: Msg?
    }
    private nonisolated struct Msg: Decodable {
        var role: String?
        var model: String?
        var usage: Usage?
    }
    private nonisolated struct Usage: Decodable {
        var input_tokens: Int?
        var output_tokens: Int?
        var cache_read_input_tokens: Int?
        var cache_creation_input_tokens: Int?
    }

    nonisolated static func parseAll(
        pricing: [String: ModelPricing],
        normalize: (String) -> String
    ) -> ParseOutput {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let projectDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return ParseOutput(sessions: [], dayBuckets: [:])
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        let cal = Calendar.current
        let decoder = JSONDecoder()

        func parseDate(_ s: String?) -> Date? {
            guard let s else { return nil }
            return iso.date(from: s) ?? isoPlain.date(from: s)
        }
        func priceOf(_ key: String) -> ModelPricing {
            if let p = pricing[key] { return p }
            if key.hasPrefix("opus") { return pricing["opus"] ?? CostService.opus }
            if key.hasPrefix("sonnet") { return pricing["sonnet"] ?? CostService.sonnet }
            if key.hasPrefix("haiku") { return pricing["haiku"] ?? CostService.haiku }
            return CostService.sonnet
        }

        var sessions: [ClaudeSession] = []
        var dayBuckets: [Date: DayBucket] = [:]

        for projectDir in projectDirs {
            guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let files = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }

                var first: Date?, last: Date?
                var userCount = 0, assistantCount = 0
                var usage = TokenUsage(), totalCost = 0.0
                var modelCount: [String: Int] = [:]
                var usageByModel: [String: TokenUsage] = [:]
                var cwd: String?, branch: String?, lastPrompt: String?
                // Context the latest assistant turn carried (input + cache tokens). Lines
                // are chronological, so the final assignment is the most recent turn - an
                // honest absolute count (we don't infer a % since the window size isn't
                // recorded; see ClaudeSession.lastContextTokens).
                var lastContextTokens = 0
                let sessionId = file.deletingPathExtension().lastPathComponent

                for lineStr in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let data = lineStr.data(using: .utf8),
                          let line = try? decoder.decode(Line.self, from: data) else { continue }
                    if cwd == nil, let c = line.cwd { cwd = c }
                    if let b = line.gitBranch, !b.isEmpty { branch = b }
                    if let lp = line.lastPrompt, !lp.isEmpty { lastPrompt = lp }

                    let date = parseDate(line.timestamp)
                    if let date {
                        if first == nil || date < first! { first = date }
                        if last == nil || date > last! { last = date }
                    }
                    let day = date.map { cal.startOfDay(for: $0) }

                    switch line.type {
                    case "user":
                        userCount += 1
                        if let day { dayBuckets[day, default: DayBucket(date: day)].userMsgs += 1 }
                        if let day { dayBuckets[day]?.sessions.insert(sessionId) }
                    case "assistant":
                        assistantCount += 1
                        let modelKey = line.message?.model.map(normalize) ?? "unknown"
                        modelCount[modelKey, default: 0] += 1
                        var u = TokenUsage()
                        if let mu = line.message?.usage {
                            u = TokenUsage(
                                input: mu.input_tokens ?? 0,
                                output: mu.output_tokens ?? 0,
                                cacheRead: mu.cache_read_input_tokens ?? 0,
                                cacheWrite: mu.cache_creation_input_tokens ?? 0
                            )
                        }
                        usage.add(u)
                        usageByModel[modelKey, default: TokenUsage()].add(u)
                        // Context size of THIS turn (input side only: output isn't part
                        // of the window). Overwritten each turn -> ends on the latest.
                        let turnContext = u.input + u.cacheRead + u.cacheWrite
                        if turnContext > 0 { lastContextTokens = turnContext }
                        let p = priceOf(modelKey)
                        let c = Double(u.input) / 1e6 * p.input + Double(u.output) / 1e6 * p.output
                            + Double(u.cacheRead) / 1e6 * p.cacheRead + Double(u.cacheWrite) / 1e6 * p.cacheWrite
                        totalCost += c
                        if let day, let date {
                            dayBuckets[day, default: DayBucket(date: day)].assistantMsgs += 1
                            dayBuckets[day]?.sessions.insert(sessionId)
                            dayBuckets[day]?.usageByModel[modelKey, default: TokenUsage()].add(u)
                            dayBuckets[day]?.hourly[cal.component(.hour, from: date)] += 1
                            dayBuckets[day]?.cost += c
                        }
                    default:
                        break
                    }
                }

                guard assistantCount + userCount > 0, let start = first, let end = last else { continue }
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
                    fileURL: file,
                    lastContextTokens: lastContextTokens
                )
                sessions.append(session)
            }
        }

        return ParseOutput(sessions: sessions, dayBuckets: dayBuckets)
    }

    /// Best-effort decode of a project slug back into a path.
    nonisolated static func decodeSlug(_ slug: String) -> String {
        // Slugs replace "/" with "-"; we cannot perfectly recover dashes in names,
        // but reconstructing with "/" gives a readable, usually-correct path.
        "/" + slug.split(separator: "-").joined(separator: "/")
    }
}
