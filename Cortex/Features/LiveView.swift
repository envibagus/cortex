import SwiftUI

// MARK: - LiveView
//
// A "what's happening now" feed for the on-device Claude Code stack. The top row
// summarizes today's totals (sessions started today, messages today, today's
// estimated cost) as native GroupBox tiles, all derived live from
// `model.sessions.sessions`. Below sits a GroupBox-framed native List of the most
// recent sessions, newest first, with the very latest entry badged "Latest". A
// refresh control re-runs the full data load.

struct LiveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PageScaffold(
            title: "Live",
            subtitle: "What's happening right now across your sessions",
            toolbar: AnyView(GlassRefreshButton())
        ) {
            // Today's headline numbers (GroupBox tiles)
            TodayStats()

            // The recent-sessions feed, grouped by project
            LiveTimeline()
        }
    }
}

// MARK: - Today stats
//
// Three native GroupBox tiles for today: sessions started today, messages
// exchanged today, and today's estimated cost. Sessions and messages are derived
// directly from sessions whose startedAt falls within the current calendar day;
// the cost reuses the last entry of the all-time daily activity series when it is
// today.

private struct TodayStats: View {
    @Environment(AppModel.self) private var model

    // Sessions whose work started today (local calendar day).
    private var todaysSessions: [ClaudeSession] {
        let start = Calendar.current.startOfDay(for: Date())
        return model.sessions.sessions.filter { $0.startedAt >= start }
    }

    // Today's message volume across those sessions.
    private var messagesToday: Int {
        todaysSessions.reduce(0) { $0 + $1.messageCount }
    }

    // Today's estimated spend: prefer the daily-activity series (exact per-day
    // cost), falling back to summing today's session costs.
    private var costToday: Double {
        let start = Calendar.current.startOfDay(for: Date())
        if let last = model.stats.dailyActivity.last,
           Calendar.current.isDate(last.date, inSameDayAs: start) {
            return last.cost
        }
        return todaysSessions.reduce(0) { $0 + $1.cost }
    }

    var body: some View {
        HStack(spacing: 16) {
            TodayStatBox(label: "Sessions today", value: "\(todaysSessions.count)", dot: Theme.textSecondary)
            TodayStatBox(label: "Messages today", value: Fmt.grouped(messagesToday), dot: Theme.textSecondary)
            TodayStatBox(label: "Cost today", value: Fmt.money(costToday), dot: Theme.textSecondary)
        }
    }
}

// MARK: - Today stat box
//
// A single big metric in a native GroupBox: a status dot + caption label over a
// large bold value.

private struct TodayStatBox: View {
    let label: String
    let value: String
    var dot: Color? = nil

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let dot {
                        Circle().fill(dot).frame(width: 7, height: 7)
                    }
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Live timeline (grouped by project)
//
// Sessions grouped by project folder, each group sorted newest-first and capped at
// four rows with a "Show N more" expander. Groups themselves are ordered by their
// most-recent activity, so the project you touched last sits at the top. Each row
// shows the model, last prompt, time + message count, an "active" dot when the
// session was touched in the last couple of minutes, and a hover CTA to resume it in
// Terminal.

private struct LiveTimeline: View {
    @Environment(AppModel.self) private var model

    /// Group every session by project name, newest-first within a group, groups
    /// ordered by their most recent session.
    private var groups: [LiveProjectGroup] {
        Dictionary(grouping: model.sessions.sessions, by: \.projectName)
            .map { name, list in
                LiveProjectGroup(id: name, sessions: list.sorted { $0.endedAt > $1.endedAt })
            }
            .sorted { $0.mostRecent > $1.mostRecent }
    }

    var body: some View {
        let groups = groups
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                // Section header with a live indicator
                HStack(spacing: 8) {
                    Label("Recent activity", systemImage: "waveform.path.ecg")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("\(groups.count) \(groups.count == 1 ? "project" : "projects")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 12)
                    LiveBadge()
                }

                if model.sessions.isLoading && model.sessions.sessions.isEmpty {
                    CortexEmptyState(icon: "clock.arrow.circlepath",
                                   title: "Tuning in",
                                   message: "Reading your latest Claude Code sessions from disk.")
                } else if groups.isEmpty {
                    CortexEmptyState(icon: "waveform.path.ecg",
                                   title: "Nothing happening yet",
                                   message: "Run Claude Code and your sessions will stream in here.")
                } else {
                    // The freshest project overall badges its newest session "Latest".
                    let latestID = groups.first?.sessions.first?.id
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(groups) { group in
                            ProjectGroupView(group: group, latestSessionID: latestID)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - One project group (header + up to 4 rows + show-more)

private struct ProjectGroupView: View {
    @Environment(AppModel.self) private var model
    let group: LiveProjectGroup
    let latestSessionID: String?
    @State private var expanded = false

    private var visible: [ClaudeSession] {
        expanded ? group.sessions : Array(group.sessions.prefix(4))
    }

    // How many Claude windows are open in this project right now (running processes
    // whose cwd is this project), so an open-but-idle window still reads as active.
    private var runningCount: Int {
        model.runningClaudeByProject[group.sessions.first?.projectPath ?? ""] ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header: project folder name + its session count + a "running" badge
            // when one or more Claude windows are open in it.
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(group.id)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(group.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if runningCount > 0 {
                    RunningBadge(count: runningCount)
                }
                Spacer(minLength: 8)
            }
            .padding(.bottom, 8)

            // Up to four session rows (all when expanded). No dividers - quiet spacing
            // reads cleaner than hairlines between every row. With N windows open in this
            // project we can't tell which sessions they're driving (a running claude
            // doesn't hold its transcript open), so we mark the N most-recent sessions
            // active - the best estimate - keeping the "N running" badge and the Active
            // rows consistent.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { idx, session in
                    LiveSessionRow(session: session,
                                   isLatest: session.id == latestSessionID,
                                   forceActive: idx < runningCount)
                }
            }

            // Show more / less when the group has more than four sessions.
            if group.total > 4 {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                        Text(expanded ? "Show less" : "Show \(group.total - 4) more")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        )
    }
}

/// One project's sessions, newest-first, plus the group's freshest timestamp.
struct LiveProjectGroup: Identifiable {
    let id: String
    let sessions: [ClaudeSession]
    var mostRecent: Date { sessions.first?.endedAt ?? .distantPast }
    var total: Int { sessions.count }
}

// MARK: - One session row (info + active dot + resume CTA)

private struct LiveSessionRow: View {
    @Environment(AppModel.self) private var model
    let session: ClaudeSession
    let isLatest: Bool
    // Set when a Claude window is OPEN in this project (a running process), so the row
    // reads active even if it hasn't written in the last 2 minutes.
    var forceActive: Bool = false
    @State private var hovering = false

    // "Active" when a Claude window is open in this project (forceActive) OR its
    // transcript was written in the last 2 minutes (recently typed). The process signal
    // catches open-but-idle windows the recency heuristic alone would miss.
    private var isActive: Bool { forceActive || Date().timeIntervalSince(session.endedAt) < 120 }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Leading status dot: green when active, else quiet.
            statusDot

            VStack(alignment: .leading, spacing: 4) {
                // Top row: model + state pill, then trailing meta. On hover the meta
                // fades and the action cluster floats in its place (an OVERLAY), so the
                // row never grows / pushes its siblings.
                HStack(spacing: 8) {
                    if let primary = session.primaryModel {
                        Pill(text: CostService.displayName(primary), tint: modelTint(primary))
                    }
                    if isActive {
                        Pill(text: "Active", tint: Theme.green, filled: true)
                    } else if isLatest {
                        Pill(text: "Latest", tint: Theme.claude, filled: true)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        Text(Fmt.relative(session.endedAt))
                            .font(.caption)
                            .foregroundStyle(isActive ? Theme.green : (isLatest ? Theme.claude : Theme.textTertiary))
                        Text("\(session.messageCount) msgs")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .opacity(hovering ? 0 : 1)
                }
                .overlay(alignment: .trailing) {
                    if hovering { actionCluster }
                }
                Text(session.lastPrompt ?? "No prompt recorded")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Tokens this session's most recent turn carried (honest absolute count;
                // no % since the window size isn't recorded). Hidden when no turn usage.
                if session.lastContextTokens > 0 {
                    ContextTokensLabel(tokens: session.lastContextTokens)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    // Trailing action cluster shown on hover (floats over the meta, no layout change):
    // resume in Terminal, reveal on disk, and Stop for an active session.
    private var actionCluster: some View {
        HStack(spacing: 8) {
            if isActive {
                actionButton("Stop", icon: "stop.fill", tint: Theme.orange) {
                    SessionLauncher.stop(session)
                }
            }
            actionButton("Open in Terminal", icon: "terminal", tint: Theme.textSecondary) {
                SessionLauncher.resumeInTerminal(session)
            }
            actionButton("Reveal", icon: "folder", tint: Theme.textSecondary) {
                NSWorkspace.shared.activateFileViewerSelecting([session.fileURL])
            }
        }
        .transition(.opacity)
    }

    private var statusDot: some View {
        Circle()
            .fill(isActive ? Theme.green : (isLatest ? Theme.claude : Color.secondary))
            .frame(width: 9, height: 9)
            .padding(.top, 5)
    }

    private func actionButton(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.cardRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func modelTint(_ model: String) -> Color {
        let key = CostService.staticNormalizeKey(model)
        if key.hasPrefix("opus") { return Theme.yellow }
        if key.hasPrefix("sonnet") { return Theme.green }
        if key.hasPrefix("haiku") { return Theme.blue }
        return Theme.purple
    }
}

// MARK: - Session launcher
//
// Opens Terminal.app at the session's project folder and resumes that exact session
// with `claude --resume <id>`. Uses osascript (Terminal's `do script`). We open +
// resume rather than offering a "quit": the app reads historical transcripts and has
// no handle on a live process, so it can't reliably (or safely) kill one.

enum SessionLauncher {
    static func resumeInTerminal(_ session: ClaudeSession) {
        let cmd = "cd \(shellQuote(session.projectPath)) && claude --resume \(shellQuote(session.id))"
        let esc = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = [
            "-e", "tell application \"Terminal\" to activate",
            "-e", "tell application \"Terminal\" to do script \"\(esc)\"",
        ]
        try? proc.run()
    }

    /// Best-effort stop: send SIGINT (graceful, like Ctrl-C) to any `claude` process
    /// whose working directory matches this session's project. SIGINT only interrupts
    /// the current turn - it does not kill data or the shell - so even an over-broad
    /// match is non-destructive and recoverable. The app reads historical transcripts
    /// and has no PID handle, so cwd-matching is the safest available signal.
    static func stop(_ session: ClaudeSession) {
        let path = shellQuote(session.projectPath)
        // For each claude process, read its cwd via lsof and SIGINT it on a match.
        // `-x claude` (exact name) so we only signal the interactive CLI - not
        // claude-tui or mcp-server-* whose command lines also contain "claude" (a broad
        // `-if claude` would over-match and SIGINT those). Matches the Live scanner.
        let script = "for pid in $(pgrep -x claude 2>/dev/null); do "
            + "c=$(lsof -a -p \"$pid\" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1); "
            + "[ \"$c\" = \(path) ] && kill -INT \"$pid\"; done"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", script]
        try? proc.run()
    }

    /// POSIX single-quote a string for safe interpolation into a shell command.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Running badge
//
// A small green pill on a project group header showing how many Claude windows are
// open in it right now ("Running" for one, "N running" for more).

private struct RunningBadge: View {
    let count: Int
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.green)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 0.4 : 1)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
            Text(count == 1 ? "Running" : "\(count) running")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.green)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.green.opacity(0.14)))
        .onAppear { pulse = true }
        .help("\(count) Claude \(count == 1 ? "window is" : "windows are") open in this project")
    }
}

// MARK: - Claude process scanner
//
// Detects RUNNING `claude` CLI processes by their working directory, so the Live page
// can mark a project "active" because a Claude window is open in it - not only when its
// transcript was written in the last couple of minutes (an idle-but-open window writes
// nothing yet still counts). Mirrors SessionLauncher.stop's pgrep + lsof approach.
//
// `pgrep -x claude` matches only the interactive CLI (not claude-tui / mcp-server). The
// app's own `claude -p` assistant subprocess runs with cwd = home, which won't match a
// project group, so it doesn't inflate per-project counts.

enum ClaudeProcessScanner {
    /// Map of working-directory path -> number of running `claude` processes there.
    nonisolated static func runningByProject() -> [String: Int] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // For each claude pid, print its cwd (lsof -d cwd), one path per line.
        let script = "for pid in $(pgrep -x claude 2>/dev/null); do "
            + "lsof -a -p \"$pid\" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; done"
        proc.arguments = ["-lc", script]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let str = String(data: data, encoding: .utf8) else { return [:] }
        var counts: [String: Int] = [:]
        for line in str.split(separator: "\n") {
            let path = line.trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { counts[path, default: 0] += 1 }
        }
        return counts
    }
}

// MARK: - Live badge
//
// A small pulsing "Live" pill that signals the feed updates from disk on refresh.

private struct LiveBadge: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.textSecondary)
                .frame(width: 7, height: 7)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
            Text("Live")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.hairFill))
        .onAppear { pulse = true }
    }
}

// MARK: - Timeline row
//
// One session in the recent-activity List: project name with its primary-model
// pill, the truncated last prompt, and trailing relative time plus message count.
// The newest row carries a "Latest" pill.

private struct TimelineRow: View {
    let session: ClaudeSession
    let isLatest: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Leading status dot.
            Circle()
                .fill(isLatest ? Theme.claude : Color.secondary)
                .frame(width: 9, height: 9)
                .padding(.top, 5)

            // Body: project + model, prompt preview.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(session.projectName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let primary = session.primaryModel {
                        Pill(text: CostService.displayName(primary), tint: modelTint(primary))
                    }
                    if isLatest {
                        Pill(text: "Latest", tint: Theme.claude, filled: true)
                    }
                }
                Text(session.lastPrompt ?? "No prompt recorded")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Trailing: relative end time + message count.
            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.relative(session.endedAt))
                    .font(.caption)
                    .foregroundStyle(isLatest ? Theme.claude : Theme.textTertiary)
                Text("\(session.messageCount) msgs")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }

    // Family tint mirrors the chart tints (opus = yellow, sonnet = green, ...).
    private func modelTint(_ model: String) -> Color {
        let key = CostService.staticNormalizeKey(model)
        if key.hasPrefix("opus") { return Theme.yellow }
        if key.hasPrefix("sonnet") { return Theme.green }
        if key.hasPrefix("haiku") { return Theme.blue }
        return Theme.purple
    }
}
