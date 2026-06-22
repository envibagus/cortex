import SwiftUI
import SwiftDraw

// MARK: - BrandIcon
//
// A brand / tech-stack logo fetched at runtime from the thesvg CDN by slug, cached in
// memory + on disk, and drawn as a vector via SwiftDraw. While loading (or when the
// slug has no icon) it shows an SF Symbol fallback, so any framework or language
// Cortex detects gets a real logo automatically, or a graceful glyph when it can't.
//
// thesvg CDN: https://cdn.jsdelivr.net/gh/glincker/thesvg@main/public/icons/<slug>/<variant>.svg

struct BrandIcon: View {
    let slug: String
    var fallbackSymbol: String = "shippingbox"
    var size: CGFloat = 16
    // Monochrome tint (logos render as a template). Defaults to the muted chrome
    // color; pass a stronger tint (e.g. Theme.orange) for a prominent brand mark.
    var tint: Color = .secondary

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                // Rasterized to a fixed box and rendered as a template, so every logo
                // is a uniform monochrome mark tinted to `tint` (matching the chrome /
                // orange-blue palette) instead of a full-color, intrinsically-sized SVG.
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    // Brand SVGs are full-bleed (no internal margin like SF Symbols), so
                    // they read visually heavier than text/glyphs at the same point size.
                    // This inset shrinks the mark to ~64% of its box so every logo sits at
                    // (actually below) the optical weight of adjacent text - uniform across
                    // the app, and clearly smaller than a full-bleed logo would be.
                    .padding(size * 0.18)
                    .frame(width: size, height: size)
                    .foregroundStyle(tint)
            } else {
                // Fallback glyph (also shown briefly while the icon loads).
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.82, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
            }
        }
        .task(id: slug) {
            guard let data = await BrandIconLoader.shared.data(for: slug),
                  let svg = SVG(data: data) else { image = nil; return }
            // Rasterize at 2x for crispness; mark as template so foregroundStyle tints it.
            let raster = svg.rasterize(with: CGSize(width: size * 2, height: size * 2), scale: 1)
            raster.isTemplate = true
            image = raster
        }
    }
}

// MARK: - BrandIconLoader
//
// Fetches thesvg icons by slug (color variant first, then mono) with a memory + on-disk
// cache under Caches/Cortex/BrandIcons, so each icon downloads at most once and
// survives relaunches. Misses are remembered for the session so a missing slug does
// not re-hit the network on every render.

actor BrandIconLoader {
    static let shared = BrandIconLoader()

    private var memory: [String: Data] = [:]
    private var misses: Set<String> = []
    private let cacheDir: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheDir = base.appendingPathComponent("Cortex/BrandIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func data(for slug: String) async -> Data? {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let cached = memory[trimmed] { return cached }
        if misses.contains(trimmed) { return nil }

        // On-disk cache (survives relaunches).
        let file = cacheDir.appendingPathComponent("\(trimmed).svg")
        if let onDisk = try? Data(contentsOf: file), !onDisk.isEmpty {
            memory[trimmed] = onDisk
            return onDisk
        }

        // Fetch from the CDN, preferring the mono variant (a clean single-color
        // silhouette that tints well as a template), then color as a fallback.
        for variant in ["mono", "color"] {
            guard let url = URL(string:
                "https://cdn.jsdelivr.net/gh/glincker/thesvg@main/public/icons/\(trimmed)/\(variant).svg")
            else { continue }
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                memory[trimmed] = data
                try? data.write(to: file)
                return data
            }
        }

        misses.insert(trimmed)
        return nil
    }
}

// MARK: - Brand slug mapping
//
// Best-effort thesvg slug for a detected language / framework display name. A miss
// (nil or a slug thesvg doesn't have) just falls back to the SF Symbol, so this only
// needs to cover the common cases; the slugify default handles the long tail.

enum BrandSlug {
    /// Overrides where a display name doesn't slugify to thesvg's slug.
    private static let overrides: [String: String] = [
        // Verified against the thesvg CDN (slug conventions are mixed: some dashed,
        // some simple-icons "dotjs" style, some renamed).
        "Next.js": "nextdotjs",
        "Three.js": "threedotjs",
        "Vue": "vuedotjs",
        "Tailwind CSS": "tailwind-css",
        "C++": "cplusplus",
        "C#": "dotnet",
        "Java": "openjdk",
        "Objective-C": "objectivec",
        "Shell": "shell",
        "HTML": "html5",
        "CSS": "css3",
        "SQL": "postgresql",
        "Swift Package Manager": "swift",
        "Cargo (Rust)": "rust",
        "Go modules": "go",
        "Bundler (Ruby)": "ruby",
        "Flutter / Dart": "flutter",
        "Composer (PHP)": "php",
        "Maven (Java)": "apache-maven",
        "Gradle": "gradle",
    ]

    /// The thesvg slug for a name: an explicit override, else a slugified guess.
    static func slug(_ name: String) -> String {
        if let override = overrides[name] { return override }
        return slugify(name)
    }

    /// thesvg slug for an AI tool, or nil to fall back to the tool's SF Symbol.
    /// (codex / amp / opencode have no thesvg icon yet, so they keep their glyph.)
    static func tool(_ kind: ToolKind) -> String? {
        switch kind {
        case .claude: "claude"
        case .codex: "codex-openai"
        case .cursor: "cursor"
        case .windsurf: "windsurf"
        case .copilot: "github-copilot"
        case .gemini: "google-gemini"
        case .amp, .opencode, .custom: nil
        }
    }

    /// Lowercase + strip everything but a-z0-9 ("Next.js" -> "nextjs", "Vue" -> "vue").
    private static func slugify(_ name: String) -> String {
        name.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
