import Foundation
import AppKit

// MARK: - UpdateService
//
// A lightweight "is there a newer release?" check against the public GitHub repo's
// Releases API. It does NOT download or install anything (the app isn't notarized, so a
// downloaded build would hit Gatekeeper): it compares the running version to the latest
// published release and, when newer, points the user at the release page to download.
// Read-only network call to a public endpoint; no auth, no data sent.

@MainActor
@Observable
final class UpdateService {
    /// owner/repo of the public release repo updates are published to.
    static let repo = "envibagus/cortex"

    private(set) var latestTag: String?
    private(set) var releaseURL: URL?
    private(set) var updateAvailable = false
    private(set) var isChecking = false
    private(set) var lastChecked: Date?
    private(set) var lastError: String?

    /// The running app's marketing version (CFBundleShortVersionString).
    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    /// Query the latest published release and update the published state. Returns whether
    /// a newer version is available.
    @discardableResult
    func check() async -> Bool {
        guard !isChecking else { return updateAvailable }
        isChecking = true
        defer { isChecking = false }
        lastError = nil

        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=1")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Cortex", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let latest = releases.first(where: { ($0["draft"] as? Bool) != true })
            else {
                lastError = "Couldn't read the latest release."
                return false
            }
            latestTag = (latest["tag_name"] as? String) ?? (latest["name"] as? String)
            releaseURL = (latest["html_url"] as? String).flatMap { URL(string: $0) }
            updateAvailable = UpdateService.isNewer(latestTag ?? "", than: currentVersion)
            lastChecked = Date()
            return updateAvailable
        } catch {
            lastError = "Couldn't reach GitHub."
            return false
        }
    }

    /// Semantic-ish comparison: strip a leading "v" and any "-beta"-style suffix, then
    /// compare the dotted numeric components ("1.10.0" > "1.9.0", "1.1.0" > "1.0.5").
    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ raw: String) -> [Int] {
            var v = raw
            if v.first == "v" || v.first == "V" { v.removeFirst() }
            v = String(v.prefix { $0 != "-" && $0 != "+" })
            return v.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
