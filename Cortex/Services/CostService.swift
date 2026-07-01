import Foundation

// MARK: - CostService
//
// Owns model pricing and turns token usage into dollars. Ships an embedded
// pricing table (USD per 1M tokens) and, when present, merges the user's own
// ~/.claude/readout-pricing.json so the numbers track the latest published rates.

@MainActor
@Observable
final class CostService {
    private(set) var pricing: [String: ModelPricing] = CostService.defaultPricing

    func load() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/readout-pricing.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [String: [String: Any]] else { return }
        var merged = Self.defaultPricing
        for (key, v) in models {
            merged[normalizeKey(key)] = ModelPricing(
                input: v["input"] as? Double ?? 0,
                output: v["output"] as? Double ?? 0,
                cacheRead: v["cacheRead"] as? Double ?? 0,
                cacheWrite: v["cacheWrite"] as? Double ?? 0,
                cacheWrite1h: v["cacheWrite1h"] as? Double
            )
        }
        pricing = merged
    }

    /// Cost in USD for a usage bundle under a given raw model id.
    func cost(for usage: TokenUsage, model: String) -> Double {
        let p = price(for: model)
        return Double(usage.input) / 1_000_000 * p.input
            + Double(usage.output) / 1_000_000 * p.output
            + Double(usage.cacheRead) / 1_000_000 * p.cacheRead
            + Double(usage.cacheWrite) / 1_000_000 * p.cacheWrite
            + Double(usage.cacheWrite1h) / 1_000_000 * p.cacheWrite1h
    }

    func price(for model: String) -> ModelPricing {
        Self.price(forKey: normalizeKey(model), in: pricing)
    }

    /// Shared rate lookup for a normalized model key. Exact table entries win, then
    /// family prefixes. Models with no known rate - local runtimes and any vendor not
    /// listed here - are counted at $0 rather than guessed: their tokens still appear
    /// in every breakdown, and a real rate can be set per model id (or under
    /// "default") in ~/.claude/readout-pricing.json.
    nonisolated static func price(forKey key: String, in pricing: [String: ModelPricing]) -> ModelPricing {
        if let exact = pricing[key] { return exact }
        if key.hasPrefix("fable") || key.hasPrefix("mythos") { return pricing["fable"] ?? fable }
        if key.hasPrefix("opus") { return pricing["opus"] ?? opus }
        if key.hasPrefix("sonnet") { return pricing["sonnet"] ?? sonnet }
        if key.hasPrefix("haiku") { return pricing["haiku"] ?? haiku }
        if key.hasPrefix("glm") || key.hasPrefix("gpt") || key.hasPrefix("gemini") { return thirdParty }
        return pricing["default"] ?? free
    }

    /// Normalize a raw model id like `claude-opus-4-7-20251001` -> `opus-4-7`.
    func normalizeKey(_ raw: String) -> String { Self.staticNormalizeKey(raw) }

    nonisolated static func staticNormalizeKey(_ raw: String) -> String {
        var k = raw.lowercased()
        if k.hasPrefix("claude-") { k = String(k.dropFirst("claude-".count)) }
        // Strip trailing -YYYYMMDD date stamp if present.
        if let m = k.firstMatch(of: /-(\d{8})$/) {
            k = String(k[..<m.range.lowerBound])
        }
        return k
    }

    /// Human label for a model id. Anthropic models are prettified to "Opus 4.8" / "Sonnet 5"
    /// (dropping the "claude-" prefix + any trailing date). ANY other id - a third-party or local
    /// model routed through Claude Code via the ANTHROPIC_DEFAULT_*_MODEL env vars - is shown
    /// VERBATIM so its real name and casing survive. Placeholder transcript models like
    /// "<synthetic>" have no real name and render as "Unknown".
    static func displayName(_ key: String) -> String {
        let raw = key.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !raw.hasPrefix("<") else { return "Unknown" }
        let low = raw.lowercased()
        // Only prettify Anthropic/Claude ids; everything else keeps its exact configured name.
        let isClaude = low.hasPrefix("claude-") || low.hasPrefix("anthropic")
            || low.hasPrefix("opus") || low.hasPrefix("sonnet") || low.hasPrefix("haiku")
        guard isClaude else { return raw }
        let normalized = staticNormalizeKey(raw)
        let parts = normalized.split(separator: "-")
        guard let family = parts.first else { return raw }
        let fam = family.prefix(1).uppercased() + family.dropFirst()
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(fam) : "\(fam) \(version)"
    }

    // MARK: - Pricing tables (USD / 1M tokens)

    static let fable = ModelPricing(input: 10, output: 50, cacheRead: 1.0, cacheWrite: 12.5)
    static let opus = ModelPricing(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)
    // Opus 4.1 and earlier billed at the original Opus rate before the 4.5 price cut.
    static let opusLegacy = ModelPricing(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)
    static let sonnet = ModelPricing(input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75)
    static let haiku = ModelPricing(input: 1, output: 5, cacheRead: 0.10, cacheWrite: 1.25)
    static let haiku35 = ModelPricing(input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1.0)
    // Generic third-party rate for the API models Claude Code can route to via the
    // ANTHROPIC_DEFAULT_*_MODEL env vars.
    static let thirdParty = ModelPricing(input: 0.6, output: 2.2, cacheRead: 0.11,
                                         cacheWrite: 0.6, cacheWrite1h: 0.6)
    // Models with no known published price (local runtimes, unrecognized vendors):
    // tokens are still counted everywhere, but priced at $0 rather than guessed.
    static let free = ModelPricing(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cacheWrite1h: 0)

    static let defaultPricing: [String: ModelPricing] = [
        "fable": fable, "fable-5": fable, "mythos-5": fable,
        "opus": opus,
        "opus-4-8": opus, "opus-4-7": opus, "opus-4-6": opus, "opus-4-5": opus,
        "opus-4-1": opusLegacy, "opus-4": opusLegacy,
        "sonnet": sonnet,
        "sonnet-5": sonnet, "sonnet-4-6": sonnet, "sonnet-4-5": sonnet, "sonnet-4": sonnet, "sonnet-3-7": sonnet,
        "haiku": haiku,
        "haiku-4-5": haiku, "haiku-3-5": haiku35,
    ]
}
