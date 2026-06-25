import SwiftUI

// MARK: - UsageView
//
// Live "how much of my AI subscriptions have I used" detail pane. One card per provider
// (Claude / Codex / Cursor / Antigravity) with a progress bar + reset countdown for each
// limit window. Data comes from UsageService (real, read at the source). See
// `UsageService.swift`.

struct UsageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PageScaffold(
            title: "Usage",
            subtitle: "Live limits across your AI coding subscriptions",
            toolbar: AnyView(HStack(spacing: 12) { UsageOptionsMenu(); RefreshControl() })
        ) {
            // One card per provider.
            VStack(spacing: 16) {
                ForEach(model.usage.providers) { provider in
                    ProviderUsageCard(provider: provider)
                }
                // Daily token usage over the last 30 days (from local Claude sessions).
                DailyTokensCard()
            }

            if let last = model.usage.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.cortexCaption)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        // Probe on first appearance (defers the one-time Keychain prompt until the
        // user actually opens this page, not at app launch).
        .task { await model.usage.load() }
    }
}

// MARK: - Toolbar refresh

private struct RefreshControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            Task { await model.usage.refresh(); model.showToast("Refreshed") }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
                .rotationEffect(.degrees(model.usage.isRefreshing ? 360 : 0))
                .animation(model.usage.isRefreshing
                           ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                           : .default, value: model.usage.isRefreshing)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .help("Refresh usage")
        .disabled(model.usage.isRefreshing)
        .accessibilityIdentifier("usage-refresh")
    }
}

// MARK: - Usage display options
//
// An in-app menu (on the Usage toolbar) mirroring the menu-bar display preferences, so
// the user can flip used/left and reset-time style right from the Usage page. Bound to
// the same AppModel preferences, so the menu bar updates in lockstep.

private struct UsageOptionsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Picker("Show Usage As", selection: usageModeBinding) {
                ForEach(UsageDisplayMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Reset Times", selection: resetStyleBinding) {
                ForEach(ResetTimerStyle.allCases) { Text($0.label).tag($0) }
            }
            if model.menuBarResetStyle == .absolute {
                Picker("Time Format", selection: timeFormatBinding) {
                    ForEach(MenuBarTimeFormat.allCases) { Text($0.label).tag($0) }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Usage display options")
        .accessibilityIdentifier("usage-options")
    }

    private var usageModeBinding: Binding<UsageDisplayMode> {
        Binding(get: { model.menuBarUsageMode }, set: { model.menuBarUsageMode = $0 })
    }
    private var resetStyleBinding: Binding<ResetTimerStyle> {
        Binding(get: { model.menuBarResetStyle }, set: { model.menuBarResetStyle = $0 })
    }
    private var timeFormatBinding: Binding<MenuBarTimeFormat> {
        Binding(get: { model.menuBarTimeFormat }, set: { model.menuBarTimeFormat = $0 })
    }
}

// MARK: - Daily tokens card (bar chart over the last 30 days)
//
// Mirrors the Cost page's daily bar chart but counts tokens per day instead of dollars
// (from local Claude session data). The trailing badge reports the busiest single day.

private struct DailyTokensCard: View {
    @Environment(AppModel.self) private var model
    // Defaults to the weekly window; daily bars only make sense over multi-day spans.
    @State private var window: UsageStats.Window = .days7
    private let windows: [UsageStats.Window] = [.days7, .days30, .all]

    var body: some View {
        let days = model.sessions.stats(window: window).dailyActivity
        let peak = days.map(\.tokens).max() ?? 0

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Tabs on top (with the peak badge trailing).
                HStack {
                    GlassSegmentedControl(items: windows, selection: $window) { $0.rawValue }
                    Spacer()
                    if peak > 0 {
                        Text("peak \(Fmt.compact(peak))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.yellow)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.yellow.opacity(0.14), in: Capsule())
                    }
                }
                // Title under the tabs, named for the selected window.
                Label(windowTitle, systemImage: "calendar")
                    .font(.headline)
                    .foregroundStyle(.primary)
                if days.isEmpty || peak <= 0 {
                    CortexEmptyState(icon: "calendar", title: "No usage yet",
                                     message: "Daily token usage will chart here as you work.")
                } else {
                    ActivityBarChart(days: days, tint: Theme.yellow,
                                     height: 120, metric: { Double($0.tokens) },
                                     hoverCaption: { day in
                                         "\(Fmt.compact(day.tokens)) tokens on \(day.date.formatted(.dateTime.day().month(.wide)))"
                                     })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("usage-daily-tokens")
    }

    /// Card title named for the selected window (the chart shows daily token usage).
    private var windowTitle: String {
        switch window {
        case .today: "Tokens Today"
        case .days7: "Tokens, Last 7 Days"
        case .days30: "Tokens, Last 30 Days"
        case .all: "Tokens, All Time"
        }
    }
}

// MARK: - Provider card

private struct ProviderUsageCard: View {
    let provider: ProviderUsage

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                // Header: brand glyph + name + plan / status pill
                HStack(spacing: 10) {
                    ProviderGlyph(id: provider.id)
                    Text(provider.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    headerTrailing
                }

                // Body varies by probe result.
                switch provider.result {
                case .loading:
                    LoadingBars()
                case let .ok(_, metrics):
                    if metrics.isEmpty {
                        QuietNote(icon: provider.id == .antigravity ? "minus.circle" : "checkmark.circle",
                                  text: provider.id == .antigravity
                                    ? "Antigravity doesn't expose usage limits."
                                    : "No active limits right now.")
                    } else {
                        VStack(spacing: 14) {
                            ForEach(metrics) { UsageProgressRow(metric: $0) }
                        }
                    }
                case let .notConfigured(message):
                    QuietNote(icon: "minus.circle", text: message)
                case let .error(message):
                    ErrorBox(message: message)
                }

                // Spend + token breakdown (Today / 7d / 30d) under Claude, from the
                // local session data. Only Claude has comparable local transcripts.
                if provider.id == .claude, case .ok = provider.result {
                    Divider().overlay(Theme.stroke)
                    UsageHistoryRows()
                }
            }
        }
        .accessibilityIdentifier("usage-card-\(provider.id.rawValue)")
    }

    /// Plan pill (when known) on the right of the header.
    @ViewBuilder private var headerTrailing: some View {
        if case let .ok(plan, _) = provider.result, let plan {
            Pill(text: plan, tint: ProviderStyle.color(provider.id))
        }
    }
}

// MARK: - Progress row (one limit window)

private struct UsageProgressRow: View {
    @Environment(AppModel.self) private var model
    let metric: UsageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Label + status dot
            HStack(spacing: 7) {
                Text(metric.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Circle()
                    .fill(UsageHeat.color(metric.percent))
                    .frame(width: 7, height: 7)
                Spacer()
            }

            // Track + fill
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairFill)
                    Capsule()
                        .fill(UsageHeat.color(metric.percent))
                        .frame(width: max(6, geo.size.width * CGFloat(metric.percent / 100)))
                }
            }
            .frame(height: 8)

            // Percent (left, used vs left per preference) + reset / detail caption (right)
            HStack {
                Text(UsageDisplay.captionLabel(metric.percent, mode: model.menuBarUsageMode))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if let caption = rightCaption {
                    Text(caption)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private var rightCaption: String? {
        if let detail = metric.detail { return detail }
        if let resetsAt = metric.resetsAt {
            return UsageHeat.resetText(resetsAt,
                                       style: model.menuBarResetStyle,
                                       timeFormat: model.menuBarTimeFormat)
        }
        return nil
    }
}

// MARK: - Provider glyph + style

private struct ProviderGlyph: View {
    let id: UsageProviderID

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(ProviderStyle.color(id).opacity(0.14))
            .frame(width: 30, height: 30)
            .overlay {
                // Brand logo fetched from the thesvg CDN (tinted to the provider's
                // accent), with an SF Symbol fallback for tools thesvg has no icon for.
                BrandIcon(slug: ProviderStyle.slug(id),
                          fallbackSymbol: ProviderStyle.fallbackSymbol(id),
                          size: 17,
                          tint: ProviderStyle.color(id))
            }
    }
}

private enum ProviderStyle {
    static func color(_ id: UsageProviderID) -> Color {
        switch id {
        case .claude: Theme.claude
        case .codex: Color(red: 0.45, green: 0.67, blue: 0.61) // #74AA9C
        case .cursor: Theme.textSecondary
        case .antigravity: Color(red: 0.26, green: 0.52, blue: 0.96) // #4285F4 (Google blue)
        }
    }

    /// thesvg slug for the provider's brand logo (fetched at runtime via BrandIcon).
    static func slug(_ id: UsageProviderID) -> String {
        switch id {
        case .claude: "claude"
        case .codex: "codex-openai"
        case .cursor: "cursor"
        case .antigravity: "google-antigravity"
        }
    }

    /// SF Symbol shown when thesvg has no logo for the provider.
    static func fallbackSymbol(_ id: UsageProviderID) -> String {
        switch id {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        case .antigravity: "atom"
        }
    }
}

// MARK: - Usage heat (color ramp + formatting)

enum UsageHeat {
    /// Orange/blue palette only (no red/green): calm blue while there's headroom,
    /// switching to orange once the window is mostly spent.
    static func color(_ percent: Double) -> Color {
        percent < 75 ? Theme.blue : Theme.orange
    }

    static func percentLabel(_ percent: Double) -> String {
        if percent > 0 && percent < 0.1 { return "<0.1%" }
        let rounded = (percent * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? "\(Int(rounded))%"
            : String(format: "%.1f%%", rounded)
    }

    /// "Resets in 2h 54m" / "Resets in 4d 12h" / "Resets in 8m".
    static func resetText(_ date: Date) -> String {
        let secs = Int(max(0, date.timeIntervalSinceNow))
        if secs < 60 { return "Resets now" }
        let days = secs / 86_400
        let hours = (secs % 86_400) / 3_600
        let mins = (secs % 3_600) / 60
        if days > 0 { return "Resets in \(days)d \(hours)h" }
        if hours > 0 { return "Resets in \(hours)h \(mins)m" }
        return "Resets in \(mins)m"
    }

    /// Reset caption honoring the menu-bar style preference: a relative countdown
    /// ("Resets in 1h 44m") or an absolute clock time ("Resets today at 11:04").
    static func resetText(_ date: Date, style: ResetTimerStyle, timeFormat: MenuBarTimeFormat) -> String {
        switch style {
        case .relative:
            return resetText(date)
        case .absolute:
            return "Resets \(absoluteReset(date, timeFormat: timeFormat))"
        }
    }

    /// "today at 11:04" / "tomorrow at 9:00" / "Jun 30 at 11:04", 12- or 24-hour per
    /// the preference (Auto follows the locale).
    private static func absoluteReset(_ date: Date, timeFormat: MenuBarTimeFormat) -> String {
        let cal = Calendar.current
        let time = DateFormatter()
        switch timeFormat {
        case .auto: time.timeStyle = .short; time.dateStyle = .none
        case .twelveHour: time.dateFormat = "h:mm a"
        case .twentyFourHour: time.dateFormat = "HH:mm"
        }
        let clock = time.string(from: date)
        if cal.isDateInToday(date) { return "today at \(clock)" }
        if cal.isDateInTomorrow(date) { return "tomorrow at \(clock)" }
        let day = DateFormatter(); day.dateFormat = "MMM d"
        return "\(day.string(from: date)) at \(clock)"
    }
}

// MARK: - State views (loading / note / error)

/// Pulsing placeholder bars while a provider is being probed.
private struct LoadingBars: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 14) {
            ForEach(0..<2, id: \.self) { _ in
                Capsule()
                    .fill(Theme.hairFill)
                    .frame(height: 8)
                    .opacity(pulse ? 0.4 : 0.9)
            }
        }
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}

/// A muted, non-alarming note (provider not set up / no limits).
private struct QuietNote: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
    }
}

/// An orange-bordered alert (expired token, network failure). Uses the orange accent
/// instead of red so the Usage page stays on the app's orange/blue palette.
private struct ErrorBox: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.orange)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .strokeBorder(Theme.orange.opacity(0.4), lineWidth: 1)
        )
    }
}
