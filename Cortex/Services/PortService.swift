import Foundation

// MARK: - PortService
//
// Lists listening TCP ports via `lsof -iTCP -sTCP:LISTEN -n -P`, mapping each to
// its owning process. Best-effort resolves a project name for node/dev-server
// processes by reading the process working directory.

@MainActor
@Observable
final class PortService {
    private(set) var ports: [PortInfo] = []
    private(set) var isLoading = false
    private(set) var lastScan: Date?

    func load() async {
        isLoading = true
        let parsed = await Task.detached(priority: .userInitiated) { Self.scan() }.value
        self.ports = parsed.sorted { $0.port < $1.port }
        self.lastScan = Date()
        self.isLoading = false
    }

    nonisolated static func scan() -> [PortInfo] {
        guard let res = Shell.run(tool: "lsof", ["-iTCP", "-sTCP:LISTEN", "-n", "-P"]), res.ok else { return [] }
        var out: [PortInfo] = []
        var seen = Set<String>()
        for line in res.stdout.split(separator: "\n").dropFirst() {
            // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 9 else { continue }
            let command = cols[0]
            guard let pid = Int(cols[1]) else { continue }
            let user = cols[2]
            let type = cols[4]   // IPv4 / IPv6
            let name = cols[8]   // *:3000 or 127.0.0.1:3000
            guard let portStr = name.split(separator: ":").last, let port = Int(portStr) else { continue }
            let family = type.contains("6") ? "IPv6" : "IPv4"
            let key = "\(port)-\(pid)-\(family)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(PortInfo(
                port: port, pid: pid, command: command,
                processName: friendlyName(command), family: family,
                user: user, project: projectName(forPid: pid)
            ))
        }
        return out
    }

    /// Resolve the process working directory (and thus a likely project name)
    /// for a PID using `lsof -a -d cwd`.
    nonisolated static func projectName(forPid pid: Int) -> String? {
        guard let res = Shell.run(tool: "lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]), res.ok else { return nil }
        for line in res.stdout.split(separator: "\n") where line.hasPrefix("n") {
            let path = String(line.dropFirst())
            let name = URL(fileURLWithPath: path).lastPathComponent
            if !name.isEmpty, name != "/" { return name }
        }
        return nil
    }

    nonisolated static func friendlyName(_ command: String) -> String {
        switch command.lowercased() {
        case let c where c.hasPrefix("node"): "Node"
        case let c where c.hasPrefix("python"): "Python"
        case let c where c.hasPrefix("ruby"): "Ruby"
        case let c where c.contains("postgres"): "Postgres"
        case let c where c.contains("redis"): "Redis"
        case let c where c.contains("mysql"): "MySQL"
        case let c where c.hasPrefix("controlce"): "Control Center"
        case let c where c.hasPrefix("rapportd"): "AirDrop"
        case "com.docke", "docker": "Docker"
        default: command
        }
    }
}
