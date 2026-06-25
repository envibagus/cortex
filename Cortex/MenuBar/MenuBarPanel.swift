import SwiftUI

// MARK: - MenuBarPanel
//
// The click-to-open detail panel for the menu-bar item. A compact (320pt) summary of the
// live Claude limits (Session / Weekly / extra usage) using the shared UsageMiniRow, an
// optional live-activity row when hooks are enabled, the Codex card when it is connected,
// and a footer to open the main window, refresh, or quit. Hosted in the controller's
// NSPopover with AppModel injected, so it reads the exact same stores as the window.

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model

    private var claude: ProviderUsage? { model.usage.providers.first { $0.id == .claude } }
    private var codex: ProviderUsage? { model.usage.providers.first { $0.id == .codex } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            // Only show the activity row while something is happening; stay empty at idle.
            if model.menuBarLiveActivityEnabled, model.activity.current.isActive {
                activityRow
                Divider().overlay(Theme.stroke)
            }

            claudeSection

            // Only when the heavy session data is loaded (the window has been opened);
            // otherwise it's been freed to save memory, so skip the spend breakdown.
            if model.isReady, case .ok = claude?.result {
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
        .task { await model.usage.load() }
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
