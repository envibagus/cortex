import SwiftUI

// MARK: - MenuBarPanel
//
// The click-to-open detail panel for the menu-bar item. A compact (320pt) summary of the
// live Claude limits (Session / Weekly / extra usage) using the shared UsageMiniRow, an
// optional live-activity row when hooks are enabled, the Codex card when it is connected,
// and a footer to open the main window, refresh, or quit. Hosted in MenuBarController's
// borderless KeyablePanel with AppModel injected, so it reads the exact same stores as the
// window.

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    // Drives the workflow progress bars to grow from 0 to their value on appear.
    @State private var filled = false

    private var claude: ProviderUsage? { model.usage.providers.first { $0.id == .claude } }
    private var codex: ProviderUsage? { model.usage.providers.first { $0.id == .codex } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            // Running dynamic workflows - one row each (name + project + agents done/total) so
            // two concurrent workflows are shown separately, not blended into one number.
            if !model.workflows.workflows.isEmpty {
                workflowSection
                Divider().overlay(Theme.stroke)
            }

            // What's running right now: a per-session breakdown when 2+ sessions are actually
            // in a turn at once, otherwise the single live-activity row. Both reflect sessions
            // that are working, not open-but-idle windows.
            if model.menuBarLiveActivityEnabled {
                if model.activity.activeSessions.count >= 2 {
                    runningSessionsSection
                    Divider().overlay(Theme.stroke)
                } else if model.activity.current.isActive {
                    activityRow
                    Divider().overlay(Theme.stroke)
                }
            }

            claudeSection

            // The spend breakdown (today / last 7 / last 30 days cost + tokens), unless the
            // user hid it. Only when the heavy session data is loaded (the window has been
            // opened); otherwise it's been freed to save memory, so skip it.
            if model.menuBarShowSpend, model.isReady, case .ok = claude?.result {
                Divider().overlay(Theme.stroke)
                UsageHistoryRows()
            }

            if case .ok = codex?.result {
                Divider().overlay(Theme.stroke)
                codexSection
            }

            Divider().overlay(Theme.stroke)
            footer
        }
        .padding(16)
        .frame(width: 320)
        // Background (the `.menu` material) + rounded corners are provided by the host window's
        // NSVisualEffectView (see MenuBarController.presentPanel); the panel content is clear.
        .task { await model.usage.load() }
        .onAppear { withAnimation(.easeOut(duration: 0.6).delay(0.3)) { filled = true } }
    }

    // MARK: Header (Claude + plan + refresh)

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.claude)
            Text("Claude")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            if case let .ok(plan, _) = claude?.result, let plan, !plan.isEmpty {
                Pill(text: plan, tint: Theme.claude)
            }
            Spacer(minLength: 8)
            refreshButton
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await model.usage.refresh() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .rotationEffect(.degrees(model.usage.isRefreshing ? 360 : 0))
                .animation(model.usage.isRefreshing
                           ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                           : .default, value: model.usage.isRefreshing)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .disabled(model.usage.isRefreshing)
        .help("Refresh usage")
    }

    // MARK: Workflow progress

    /// One row per running dynamic workflow, so concurrent workflows stay distinct.
    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.workflows.workflows) { workflowRow($0) }
        }
    }

    /// A running workflow: name + project on the left, "N/M agents" on the right, with a thin
    /// progress bar. Reflects subagents completed vs launched for THAT run.
    private func workflowRow(_ wf: WorkflowMonitor.RunningWorkflow) -> some View {
        let frac = wf.total > 0 ? Double(wf.done) / Double(wf.total) : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Text(wf.name ?? "Workflow")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let project = wf.project, !project.isEmpty {
                    Text(project)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text("\(wf.done)/\(wf.total) agents")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.textTertiary.opacity(0.25))
                    Capsule().fill(Theme.green).frame(width: filled ? max(4, geo.size.width * frac) : 0)
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: Running sessions breakdown

    /// Lists each session currently in a turn (project + what it's doing) - the detail behind
    /// the menu bar's "N running". Reflects active turns, not open windows.
    private var runningSessionsSection: some View {
        let sessions = model.activity.activeSessions
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Text("Running")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text("\(sessions.count) session\(sessions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(sessions) { session in
                HStack(spacing: 8) {
                    Circle()
                        .fill(session.state == .awaitingPermission ? Color.yellow : Theme.green)
                        .frame(width: 6, height: 6)
                    Text(session.projectName)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(session.label)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: Live activity row

    private var activityRow: some View {
        let act = model.activity.current
        let dotColor: Color
        switch act.state {
        case .idle: dotColor = Theme.textTertiary
        case .awaitingPermission: dotColor = .yellow
        case .done: dotColor = .green
        default: dotColor = Theme.green
        }
        return HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Image(systemName: ActivityLabels.symbol(for: act.state, tool: act.tool))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Text(act.isActive ? act.label : "Idle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            if act.isActive, let start = act.turnStartedAt {
                // Tick the elapsed time once a second while the panel is open.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(MenuBarController.elapsed(since: start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            if let cwd = act.cwd, !cwd.isEmpty {
                Text((cwd as NSString).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: Claude limits

    @ViewBuilder private var claudeSection: some View {
        switch claude?.result {
        case .loading, .none:
            HStack { ProgressView().controlSize(.small); Text("Loading usage\u{2026}").font(.caption).foregroundStyle(Theme.textSecondary) }
        case let .ok(_, metrics):
            let rows = panelMetrics(metrics)
            if rows.isEmpty {
                note("checkmark.circle", "No active limits right now.")
            } else {
                VStack(spacing: 12) {
                    ForEach(rows) { UsageMiniRow(metric: $0) }
                }
            }
        case let .notConfigured(message):
            note("minus.circle", message)
        case let .error(message):
            note("exclamationmark.circle", message, tint: Theme.orange)
        }
    }

    // MARK: Codex (only when connected)

    @ViewBuilder private var codexSection: some View {
        if case let .ok(plan, metrics) = codex?.result {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Codex")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    if let plan, !plan.isEmpty {
                        Pill(text: plan, tint: Theme.textSecondary)
                    }
                    Spacer()
                }
                ForEach(panelMetrics(metrics)) { UsageMiniRow(metric: $0) }
            }
        }
    }

    /// Keep the panel compact: Session, Weekly, and any dollar-denominated extra usage
    /// (the per-model weekly windows stay on the full Usage page).
    private func panelMetrics(_ metrics: [UsageMetric]) -> [UsageMetric] {
        [metrics.first { $0.label == "Session" },
         metrics.first { $0.label == "Weekly" },
         metrics.first { $0.label == "Extra usage" }].compactMap { $0 }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            PanelButton(title: "Open Cortex", systemImage: "macwindow") {
                model.menuBar?.closePanel()
                model.revealMainWindow(route: .usage)
            }
            Spacer(minLength: 0)
            PanelButton(title: "Settings", systemImage: "gearshape") {
                model.menuBar?.closePanel()
                model.settingsTabHint = SettingsView.SettingsTab.menuBar.rawValue
                model.revealMainWindow(route: .settings)
            }
            PanelButton(title: "Quit", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: Note row (states)

    private func note(_ icon: String, _ text: String, tint: Color = Theme.textSecondary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint == Theme.textSecondary ? Theme.textTertiary : tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(tint)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Footer button
//
// A compact icon + label control used in the panel footer (Open Cortex / Settings /
// Quit), styled with the app's hover wash.

private struct PanelButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .hoverHighlight()
        }
        .buttonStyle(.plain)
    }
}
