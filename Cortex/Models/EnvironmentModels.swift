import Foundation

// MARK: - Environment models
//
// Types for the Environment page, which reflects the developer command-line tools
// installed on this machine. Tools are grouped into categories; each catalogued tool
// carries a version command and a short description, and a scan resolves it to a
// DetectedTool (its path, install source, and version) or leaves it absent. Binaries
// found on PATH that aren't in the catalogue are surfaced under the Uncatalogued group.

// MARK: Category

/// A grouping shown as a section on the Environment page. The order of the cases is the
/// order the sections render in.
enum ToolCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case runtimes
    case versionControl
    case hosting
    case databases
    case mobile
    case media
    case shell
    case aiCLIs
    case build
    case wordpress
    case uncatalogued

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runtimes: "Runtimes & language toolchains"
        case .versionControl: "Version control & GitHub"
        case .hosting: "Hosting & deploy"
        case .databases: "Databases"
        case .mobile: "Mobile / iOS / Android"
        case .media: "Media, docs, scraping"
        case .shell: "Search / data / shell"
        case .aiCLIs: "AI / agent CLIs"
        case .build: "Build tooling"
        case .wordpress: "WordPress"
        case .uncatalogued: "Uncatalogued"
        }
    }

    var icon: String {
        switch self {
        case .runtimes: "cube"
        case .versionControl: "arrow.triangle.branch"
        case .hosting: "cloud"
        case .databases: "cylinder.split.1x2"
        case .mobile: "iphone"
        case .media: "photo.on.rectangle"
        case .shell: "terminal"
        case .aiCLIs: "sparkles"
        case .build: "hammer"
        case .wordpress: "w.circle"
        case .uncatalogued: "tray.full"
        }
    }
}

// MARK: Install source

/// Where a resolved binary was installed from, inferred from its path prefix. Shown as a
/// small badge in the detail pane so the same tool from Homebrew vs a version manager vs a
/// hand-placed script is distinguishable.
enum ToolInstallSource: String, Codable, Sendable {
    case homebrew
    case cargo
    case bun
    case localBin
    case versionManager
    case system
    case other

    var label: String {
        switch self {
        case .homebrew: "Homebrew"
        case .cargo: "Cargo"
        case .bun: "Bun"
        case .localBin: "~/.local/bin"
        case .versionManager: "Version manager"
        case .system: "System"
        case .other: "Other"
        }
    }

    var icon: String {
        switch self {
        case .homebrew: "cup.and.saucer"
        case .cargo: "shippingbox"
        case .bun: "takeoutbag.and.cup.and.straw"
        case .localBin: "folder"
        case .versionManager: "arrow.triangle.2.circlepath"
        case .system: "gearshape"
        case .other: "questionmark.circle"
        }
    }

    /// Canonical display order for grouping by source.
    static let displayOrder: [ToolInstallSource] = [
        .homebrew, .cargo, .bun, .localBin, .versionManager, .system, .other,
    ]

    /// Infer the source from a resolved binary's absolute path.
    static func infer(fromPath path: String) -> ToolInstallSource {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix("/opt/homebrew") || path.contains("/Cellar/") { return .homebrew }
        if path.hasPrefix("\(home)/.cargo/") { return .cargo }
        if path.hasPrefix("\(home)/.bun/") { return .bun }
        if path.hasPrefix("\(home)/.local/bin") { return .localBin }
        // Common version-manager shim locations (Node, Ruby, Python, PHP, generic).
        let vmMarkers = ["/.nvm/", "/.fnm/", "/fnm/", "/.volta/", "/.asdf/", "/Herd/",
                         "/.rbenv/", "/.pyenv/", "/.rustup/", "/.pixi/"]
        if vmMarkers.contains(where: { path.contains($0) }) { return .versionManager }
        if path.hasPrefix("/usr/bin") || path.hasPrefix("/bin")
            || path.hasPrefix("/usr/sbin") || path.hasPrefix("/sbin") { return .system }
        return .other
    }
}

// MARK: Catalogued tool

/// One known command-line tool the Environment scan looks for: the binary name (its id),
/// an optional friendlier display name, the category it belongs under, the arguments that
/// print its version, a short factual description, and an optional upgrade command. Extra
/// binary names it may answer to go in `aliases`.
struct CatalogTool: Identifiable, Sendable {
    let name: String
    var displayName: String? = nil
    let category: ToolCategory
    var versionArgs: [String] = ["--version"]
    var blurb: String? = nil
    var upgrade: String? = nil
    var aliases: [String] = []
    // Absolute candidate paths (may contain `~`) probed before the standard dirs, for tools
    // that commonly install OFF the shell PATH (Android SDK, Google Cloud SDK, Go, ...).
    var extraPaths: [String] = []

    var id: String { name }
    var resolvedDisplayName: String { displayName ?? name }
}

// MARK: Detected tool

/// The result of resolving a tool on this machine: a catalogue entry with its scan
/// outcome, or an uncatalogued binary discovered on PATH. `version` is the parsed number
/// (e.g. "20.20.0"); `rawVersion` is the first line the tool printed. Uncatalogued tools
/// carry no version until the detail pane probes them on demand.
struct DetectedTool: Identifiable, Sendable {
    let name: String
    let displayName: String
    let category: ToolCategory
    var blurb: String? = nil
    var upgrade: String? = nil
    var present: Bool
    var path: String? = nil
    var version: String? = nil
    var rawVersion: String? = nil
    var source: ToolInstallSource = .other

    var id: String { name }

    /// A path with the home directory abbreviated to `~` for display.
    var displayPath: String? { path?.tildeAbbreviated }
}
