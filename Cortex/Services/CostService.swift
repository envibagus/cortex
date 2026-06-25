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
                cacheWrite: v["cacheWrite"] as? Double ?? 0
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
    }

    func price(for model: String) -> ModelPricing {
        let key = normalizeKey(model)
        if let exact = pricing[key] { return exact }
        // Fall back to family prefix (e.g. "opus-4-7" -> "opus").
        if key.hasPrefix("opus") { return pricing["opus"] ?? Self.opus }
        if key.hasPrefix("sonnet") { return pricing["sonnet"] ?? Self.sonnet }
        if key.hasPrefix("haiku") { return pricing["haiku"] ?? Self.haiku }
        if key.hasPrefix("glm") || key.hasPrefix("gpt") || key.hasPrefix("gemini") { return Self.thirdParty }
        return Self.sonnet
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

    /// Human label for a model key, e.g. `opus-4-7` -> "Opus 4.7".
    static func displayName(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard let family = parts.first else { return key }
        let fam = family.prefix(1).uppercased() + family.dropFirst()
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(fam) : "\(fam) \(version)"
    }

    // MARK: - Pricing tables (USD / 1M tokens)

    static let opus = ModelPricing(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)
    static let sonnet = ModelPricing(input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75)
    static let haiku = ModelPricing(input: 1, output: 5, cacheRead: 0.10, cacheWrite: 1.25)
    static let thirdParty = ModelPricing(input: 0.6, output: 2.2, cacheRead: 0.11, cacheWrite: 0.6)

    static let defaultPricing: [String: ModelPricing] = [
        "opus": opus,
        "opus-4-8": opus, "opus-4-7": opus, "opus-4-6": opus, "opus-4-5": opus, "opus-4-1": opus, "opus-4": opus,
        "sonnet": sonnet,
        "sonnet-4-6": sonnet, "sonnet-4-5": sonnet, "sonnet-4": sonnet, "sonnet-3-7": sonnet,
        "haiku": haiku,
        "haiku-4-5": haiku, "haiku-3-5": haiku,
    ]
}
