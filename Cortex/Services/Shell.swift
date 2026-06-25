import Foundation

// MARK: - Shell
//
// Small helper to run command-line tools (git, gh, lsof, claude) off the main
// thread and capture stdout. Resolves binaries from the usual install locations
// since GUI apps do not inherit the user's interactive PATH.

enum Shell {
    struct Result {
        var stdout: String
        var stderr: String
        var exitCode: Int32
        var ok: Bool { exitCode == 0 }
    }

    /// Resolve an executable by probing common install dirs, nvm node versions, and
    /// finally the user's real login-shell PATH (so version-manager dirs like Herd /
    /// fnm / volta are found even though a GUI app doesn't inherit the shell PATH).
    static func which(_ name: String, extra: [String] = []) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = extra
        candidates += [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
            "/sbin/\(name)",
            "/usr/sbin/\(name)",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let nvmDir = "\(home)/.nvm/versions/node"
        if let nodeDirs = try? fm.contentsOfDirectory(atPath: nvmDir) {
            for node in nodeDirs.sorted().reversed() {
                let candidate = "\(nvmDir)/\(node)/bin/\(name)"
                if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
            }
        }
        // Last resort: the user's interactive login-shell PATH. This catches binaries
        // installed by node version managers Herd/fnm/volta/asdf (e.g. `agy`) and
        // anything else the user's terminal can see but a Finder-launched app cannot.
        // Resolved + cached once (see loginPathDirs); only reached on a miss above.
        for dir in loginPathDirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// The user's interactive login-shell PATH directories, resolved ONCE and cached.
    /// A GUI app launched from Finder/Dock does not inherit the shell PATH, so tools
    /// installed by node version managers (nvm, Herd, fnm, volta) live in directories
    /// no hardcoded list can predict. Asking the login shell once finds whatever the
    /// user's own terminal would find. Thread-safe lazy `static let`; prewarmed
    /// off-main at bootstrap so the first UI access never blocks the main thread.
    static let loginPathDirs: [String] = resolveLoginPathDirs()

    private static func resolveLoginPathDirs() -> [String] {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shellPath)
        // -l (login) + -i (interactive) so PATH exported from .zshrc / .zprofile is
        // included. A sentinel brackets the value so prompt/banner noise printed by an
        // interactive shell can't be mistaken for the PATH.
        proc.arguments = ["-lic", #"printf '<<CORTEXPATH>>%s<<END>>' "$PATH""#]
        proc.standardInput = FileHandle.nullDevice   // EOF, so an interactive shell can't hang
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let raw = String(data: data, encoding: .utf8),
              let start = raw.range(of: "<<CORTEXPATH>>"),
              let end = raw.range(of: "<<END>>"), start.upperBound <= end.lowerBound else { return [] }
        return String(raw[start.upperBound..<end.lowerBound])
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    /// Run a resolved binary and capture output. Safe to call from a detached task.
    @discardableResult
    static func run(
        _ executable: URL,
        _ args: [String],
        cwd: URL? = nil,
        env extraEnv: [String: String] = [:],
        timeout: TimeInterval = 30
    ) -> Result {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = cwd }

        var env = ProcessInfo.processInfo.environment
        // Ensure child tools see a sane PATH even when launched from Finder.
        let injected = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = injected + ":" + (env["PATH"] ?? "")
        for (k, v) in extraEnv { env[k] = v }
        proc.environment = env

        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        do { try proc.run() } catch {
            return Result(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }

        // Read concurrently so a full stderr pipe cannot deadlock the child.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        return Result(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: proc.terminationStatus
        )
    }

    /// Convenience: resolve `name` then run, returning nil if the tool is missing.
    static func run(tool name: String, _ args: [String], cwd: URL? = nil, extra: [String] = []) -> Result? {
        guard let url = which(name, extra: extra) else { return nil }
        return run(url, args, cwd: cwd)
    }
}
