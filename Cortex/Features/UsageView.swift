import SwiftUI

// MARK: - UsageView
//
// Live "how much of my AI subscriptions have I used" panel, modeled on openusage's
// detail pane. One card per provider (Claude / Codex / Cursor / Gemini) with a
// progress bar + reset countdown for each limit window. Data comes from UsageService
// (real, read at the source). See `UsageService.swift`.

struct UsageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PageScaffold(
            title: "Usage",
            subtitle: "Live limits across your AI coding subscriptions",
            toolbar: AnyView(RefreshControl())
        ) {
            // One card per provider, in the same order as the menu-bar reference.
            VStack(spacing: 16) {
                ForEach(model.usage.providers) { provider in
                    ProviderUsageCard(provider: provider)
                }
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
                        QuietNote(icon: "checkmark.circle", text: "No active limits right now.")
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

            // Percent (left) + reset / detail caption (right)
            HStack {
                Text(UsageHeat.percentLabel(metric.percent))
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
        if let resetsAt = metric.resetsAt { return UsageHeat.resetText(resetsAt) }
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
        case .gemini: Color(red: 0.26, green: 0.52, blue: 0.96) // #4285F4
        }
    }

    /// thesvg slug for the provider's brand logo (fetched at runtime via BrandIcon).
    static func slug(_ id: UsageProviderID) -> String {
        switch id {
        case .claude: "claude"
        case .codex: "codex-openai"
        case .cursor: "cursor"
        case .gemini: "google-gemini"
        }
    }

    /// SF Symbol shown when thesvg has no logo for the provider.
    static func fallbackSymbol(_ id: UsageProviderID) -> String {
        switch id {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        case .gemini: "sparkles"
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
}

// MARK: - State views (loading / note / error)

/// Pulsing placeholder bars while a provider is being probed (mirrors openusage's
/// loading skeleton, e.g. the Gemini rows in the reference screenshot).
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
