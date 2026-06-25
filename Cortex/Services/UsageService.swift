import Foundation

// MARK: - UsageService
//
// Live rate-limit / quota indicator for the local AI coding stack. All data is REAL
// and read at the source:
//   - Claude: the Claude Code OAuth token from the macOS Keychain
//     ("Claude Code-credentials") or ~/.claude/.credentials.json, then a GET to
//     https://api.anthropic.com/api/oauth/usage (the same endpoint Claude Code uses).
//   - Codex: the token in ~/.codex/auth.json, then GET chatgpt.com/backend-api/wham/usage.
//
// Read-only by design: we never refresh or rewrite the tokens, so we never rotate
// a refresh token out from under a running `claude`/`codex` session. If a token has
// expired we surface a friendly "open the CLI to refresh" message instead.

// MARK: Display model

/// One provider Cortex can report usage for.
enum UsageProviderID: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, cursor, antigravity
    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        }
    }

    /// SF Symbol used as the provider glyph (no third-party brand assets needed).
    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cube"
        case .antigravity: "atom"
        }
    }
}

/// A single limit window: a percentage used (0...100) and, optionally, when it resets.
/// `detail` overrides the right-hand caption (used for dollar-denominated extras).
struct UsageMetric: Identifiable, Sendable {
    var id: String { label }
    var label: String
    var percent: Double
    var resetsAt: Date?
    var detail: String?

    init(label: String, percent: Double, resetsAt: Date? = nil, detail: String? = nil) {
        self.label = label
        self.percent = max(0, min(100, percent))
        self.resetsAt = resetsAt
        self.detail = detail
    }
}

/// The outcome of probing one provider.
enum UsageResult: Sendable {
    case loading
    case ok(plan: String?, metrics: [UsageMetric])
    /// The provider isn't set up (not logged in / not installed). Informational, not an error.
    case notConfigured(String)
    /// Something went wrong we want to surface loudly (expired token, network, conflict).
    case error(String)
}

/// A provider row as rendered in the Usage view: identity + latest probe result.
struct ProviderUsage: Identifiable {
    let id: UsageProviderID
    var result: UsageResult
    var name: String { id.name }
}

// MARK: - Store

@MainActor
@Observable
final class UsageService {
    private(set) var providers: [ProviderUsage] =
        UsageProviderID.allCases.map { ProviderUsage(id: $0, result: .loading) }
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false

    /// Whether a successful probe has ever populated at least one provider.
    var hasLoaded: Bool { lastRefresh != nil }

    func load() async {
        guard lastRefresh == nil else { return }
        await refresh()
    }

    /// Re-probe every provider concurrently. Network + Keychain work happens off the
    /// main actor (the fetchers are `nonisolated`), so the UI never blocks on the
    /// first-time Keychain access prompt.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let claude = UsageProbe.claude()
        async let codex = UsageProbe.codex()
        let (claudeResult, codexResult) = await (claude, codex)

        providers = [
            ProviderUsage(id: .claude, result: claudeResult),
            ProviderUsage(id: .codex, result: codexResult),
            ProviderUsage(id: .cursor, result: .notConfigured(
                "Cursor stores usage behind its dashboard RPC. Not wired into Cortex yet.")),
            ProviderUsage(id: .antigravity, result: UsageProbe.antigravity()),
        ]
        lastRefresh = Date()
    }
}

// MARK: - Probes (off-main, read-only)

private enum UsageProbe {

    // MARK: Claude

    static func claude() async -> UsageResult {
        guard let creds = loadClaudeCredentials() else {
            return .notConfigured("Not logged in. Run `claude` to authenticate.")
        }
        guard let token = creds.accessToken, !token.isEmpty else {
            return .notConfigured("Not logged in. Run `claude` to authenticate.")
        }
        // Inference-only tokens (no user:profile scope) can't read the usage endpoint.
        if let scopes = creds.scopes, !scopes.isEmpty, !scopes.contains("user:profile") {
            return .error("This token can't read usage limits.")
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")

        let plan = claudePlanLabel(subscriptionType: creds.subscriptionType, tier: creds.rateLimitTier)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                return .error("Token expired. Open Claude Code to refresh.")
            }
            if status == 429 {
                return .error("Rate limited by Anthropic. Try again later.")
            }
            guard (200..<300).contains(status) else {
                return .error("Usage request failed (HTTP \(status)).")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .error("Unexpected usage response.")
            }

            var metrics: [UsageMetric] = []
            if let m = claudeWindowMetric(json["five_hour"], label: "Session") { metrics.append(m) }
            if let m = claudeWindowMetric(json["seven_day"], label: "Weekly") { metrics.append(m) }
            // Per-model weekly windows (seven_day_sonnet, seven_day_opus, ...) as extras.
            for key in json.keys.sorted() where key.hasPrefix("seven_day_") {
                let label = claudeWeeklyModelLabel(key)
                if let m = claudeWindowMetric(json[key], label: label) { metrics.append(m) }
            }
            // Extra Usage only appears when pay-as-you-go credits are actually in use.
            if let extra = claudeExtraUsage(json["extra_usage"]) { metrics.append(extra) }

            if metrics.isEmpty {
                return .ok(plan: plan, metrics: [])
            }
            return .ok(plan: plan, metrics: metrics)
        } catch {
            return .error("Couldn't reach Anthropic. Check your connection.")
        }
    }

    /// A Claude usage window -> metric. Windows look like `{ utilization: 30, resets_at: ... }`.
    private static func claudeWindowMetric(_ raw: Any?, label: String) -> UsageMetric? {
        guard let win = raw as? [String: Any] else { return nil }
        guard let util = num(win["utilization"]) else { return nil }
        return UsageMetric(label: label, percent: util, resetsAt: parseDate(win["resets_at"]))
    }

    /// "seven_day_sonnet" -> "Sonnet · weekly". Keeps Anthropic's odd codenames readable.
    private static func claudeWeeklyModelLabel(_ key: String) -> String {
        let suffix = String(key.dropFirst("seven_day_".count))
        let pretty: String
        switch suffix {
        case "sonnet": pretty = "Sonnet"
        case "opus": pretty = "Opus"
        case "omelette": pretty = "Claude Design"
        default: pretty = suffix.prefix(1).uppercased() + suffix.dropFirst()
        }
        return "\(pretty) · weekly"
    }

    /// Pay-as-you-go extra-usage credits -> a dollar-denominated metric, only when credits
    /// are enabled and actually in use (otherwise nil, so the row is hidden).
    private static func claudeExtraUsage(_ raw: Any?) -> UsageMetric? {
        guard let extra = raw as? [String: Any],
              (extra["is_enabled"] as? Bool) == true,
              let used = num(extra["used_credits"]),
              let limit = num(extra["monthly_limit"]), limit > 0 else { return nil }
        let pct = used / limit * 100
        let detail = "$\(money(used)) of $\(money(limit))"
        return UsageMetric(label: "Extra usage", percent: pct, resetsAt: nil, detail: detail)
    }

    private static func claudePlanLabel(subscriptionType: String?, tier: String?) -> String? {
        guard let sub = subscriptionType?.trimmingCharacters(in: .whitespaces), !sub.isEmpty else { return nil }
        let base: String
        switch sub.lowercased() {
        case "max": base = "Max"
        case "pro": base = "Pro"
        case "team": base = "Team"
        case "enterprise": base = "Enterprise"
        case "free": base = "Free"
        default: base = sub.prefix(1).uppercased() + sub.dropFirst()
        }
        // rateLimitTier like "default_claude_max_20x" -> append "20x".
        if let tier, let match = tier.range(of: #"(\d+)x"#, options: .regularExpression) {
            return base + " " + String(tier[match])
        }
        return base
    }

    // MARK: Codex

    static func codex() async -> UsageResult {
        guard let auth = loadCodexAuth() else {
            return .notConfigured("Not logged in. Run `codex` to authenticate.")
        }
        guard let token = auth.accessToken, !token.isEmpty else {
            return .notConfigured("Not logged in. Run `codex` to authenticate.")
        }

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Cortex", forHTTPHeaderField: "User-Agent")
        if let account = auth.accountId, !account.isEmpty {
            req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 401 || status == 403 {
                return .error("Token expired. Run `codex` to log in again.")
            }
            if status == 429 {
                return .error("Rate limited by OpenAI. Try again later.")
            }
            guard (200..<300).contains(status) else {
                return .error("Usage request failed (HTTP \(status)).")
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

            var metrics: [UsageMetric] = []
            let now = Date()
            let rateLimit = json["rate_limit"] as? [String: Any]
            let primary = rateLimit?["primary_window"] as? [String: Any]
            let secondary = rateLimit?["secondary_window"] as? [String: Any]

            // Prefer the response headers (most precise), fall back to the body windows.
            if let p = num(http?.value(forHTTPHeaderField: "x-codex-primary-used-percent")) {
                metrics.append(UsageMetric(label: "Session", percent: p, resetsAt: codexReset(primary, now: now)))
            } else if let p = num(primary?["used_percent"]) {
                metrics.append(UsageMetric(label: "Session", percent: p, resetsAt: codexReset(primary, now: now)))
            }
            if let s = num(http?.value(forHTTPHeaderField: "x-codex-secondary-used-percent")) {
                metrics.append(UsageMetric(label: "Weekly", percent: s, resetsAt: codexReset(secondary, now: now)))
            } else if let s = num(secondary?["used_percent"]) {
                metrics.append(UsageMetric(label: "Weekly", percent: s, resetsAt: codexReset(secondary, now: now)))
            }

            // Per-model extra windows (e.g. "GPT-5.1-Codex-Spark").
            if let extras = json["additional_rate_limits"] as? [[String: Any]] {
                for entry in extras {
                    guard let rl = entry["rate_limit"] as? [String: Any],
                          let win = rl["primary_window"] as? [String: Any],
                          let pct = num(win["used_percent"]) else { continue }
                    let raw = (entry["limit_name"] as? String) ?? "Model"
                    let short = raw.replacingOccurrences(
                        of: #"^GPT-[\d.]+-Codex-"#, with: "", options: .regularExpression)
                    metrics.append(UsageMetric(label: short.isEmpty ? raw : short,
                                               percent: pct, resetsAt: codexReset(win, now: now)))
                }
            }

            let plan = codexPlanLabel(json["plan_type"])
            return .ok(plan: plan, metrics: metrics)
        } catch {
            return .error("Couldn't reach OpenAI. Check your connection.")
        }
    }

    /// Codex windows carry either `reset_at` (epoch seconds) or `reset_after_seconds`.
    private static func codexReset(_ win: [String: Any]?, now: Date) -> Date? {
        guard let win else { return nil }
        if let at = num(win["reset_at"]) { return epochDate(at) }
        if let after = num(win["reset_after_seconds"]) { return now.addingTimeInterval(after) }
        return nil
    }

    private static func codexPlanLabel(_ raw: Any?) -> String? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        switch s.lowercased() {
        case "prolite": return "Pro 5x"
        case "pro": return "Pro 20x"
        case "plus": return "Plus"
        case "team": return "Team"
        case "free": return "Free"
        default: return s.prefix(1).uppercased() + s.dropFirst()
        }
    }

    // MARK: Antigravity

    /// Antigravity (the `agy` CLI) keeps the selected model in a local, non-secret
    /// settings file, but exposes no readable usage/quota source. So we surface the
    /// current model only and stay honest about limits not being available.
    static func antigravity() -> UsageResult {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".gemini/antigravity-cli/settings.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = (root["model"] as? String)?.trimmingCharacters(in: .whitespaces),
              !model.isEmpty else {
            return .notConfigured("Not set up. Run `agy` to pick a model.")
        }
        return .ok(plan: model, metrics: [])
    }

    // MARK: Credential loading (read-only)

    private struct ClaudeCreds {
        var accessToken: String?
        var subscriptionType: String?
        var rateLimitTier: String?
        var scopes: [String]?
    }

    private static func loadClaudeCredentials() -> ClaudeCreds? {
        // Keychain wins (recent Claude Code keeps the live session there), file is the fallback.
        if let data = readKeychain(service: "Claude Code-credentials"),
           let creds = parseClaudeCreds(data) { return creds }

        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let creds = parseClaudeCreds(data) { return creds }

        return nil
    }

    private static func parseClaudeCreds(_ data: Data) -> ClaudeCreds? {
        guard let root = decodeMaybeHexJSON(data),
              let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        guard let token = oauth["accessToken"] as? String else { return nil }
        return ClaudeCreds(
            accessToken: token,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String,
            scopes: oauth["scopes"] as? [String]
        )
    }

    private struct CodexAuth {
        var accessToken: String?
        var accountId: String?
    }

    private static func loadCodexAuth() -> CodexAuth? {
        let home = NSHomeDirectory() as NSString
        let candidates = [".codex/auth.json", ".config/codex/auth.json"]
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            let p = (env as NSString).appendingPathComponent("auth.json")
            if let auth = parseCodexAuth(p) { return auth }
        }
        for rel in candidates {
            if let auth = parseCodexAuth(home.appendingPathComponent(rel)) { return auth }
        }
        return nil
    }

    private static func parseCodexAuth(_ path: String) -> CodexAuth? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = decodeMaybeHexJSON(data) else { return nil }
        let tokens = root["tokens"] as? [String: Any]
        let token = tokens?["access_token"] as? String
        // OPENAI_API_KEY-only auth can't read the subscription usage endpoint.
        guard token != nil else { return nil }
        return CodexAuth(accessToken: token, accountId: tokens?["account_id"] as? String)
    }

    // MARK: Keychain (read-only generic password, via the `security` CLI)

    /// Read a generic-password Keychain item by service name.
    ///
    /// This spawns `/usr/bin/security find-generic-password -s <service> -w` instead of
    /// calling `SecItemCopyMatching` from inside Cortex, and that distinction is the
    /// whole point. "Claude Code-credentials" is owned by Claude Code, so any other
    /// reader is challenged on first access. macOS binds the user's "Always Allow" to
    /// the *requesting binary*: read it from Cortex directly and the grant is tied to
    /// Cortex's code signature (which changes on every rebuild, so it never sticks and
    /// the prompt returns forever). Route the read through the system `security` tool
    /// and the grant is tied to `/usr/bin/security`, an Apple-signed binary whose
    /// signature never changes, so "Always Allow" sticks permanently: one prompt, ever.
    ///
    /// `-w` prints only the password value to stdout. Returns nil if the item is
    /// missing or access is denied (the caller then falls back to the file on disk).
    private static func readKeychain(service: String) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()  // swallow the "could not be found" stderr line
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        // `-w` appends a trailing newline; trim it and re-encode the JSON payload.
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return Data(text.utf8)
    }

    // MARK: Parsing helpers

    /// Parse JSON that is either raw UTF-8 or hex-encoded UTF-8 (some Keychain payloads).
    private static func decodeMaybeHexJSON(_ data: Data) -> [String: Any]? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        var hex = text
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard hex.count % 2 == 0, hex.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil
        else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
    }

    /// Coerce a JSON number / numeric string to Double.
    private static func num(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// Parse a reset timestamp that may be an ISO-8601 string or an epoch number.
    private static func parseDate(_ v: Any?) -> Date? {
        if let n = num(v) { return epochDate(n) }
        guard let s = v as? String, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    /// Treat large values as milliseconds, smaller ones as seconds.
    private static func epochDate(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
    }

    private static func money(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v.rounded())) : String(format: "%.2f", v)
    }
}
