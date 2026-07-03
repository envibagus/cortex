import SwiftUI

// MARK: - UsageBar
//
// A compact strip of the live Claude usage limits for the home Overview: the tool
// name + plan badge, then every reported limit window (Session, Weekly, per-model
// weeklies like Fable, extra usage) as labelled progress bars with a percent and a
// reset countdown. Reads the same UsageService the Usage page uses; calls load() in
// .task so the one-time Keychain prompt only happens once and is shared with the
// Usage page. Shows only Claude (the other providers are not configured); states
// stay honest (loading / not connected / error) rather than faking numbers.

struct UsageBar: View {
    @Environment(AppModel.self) private var model

    private var claude: ProviderUsage? {
        model.usage.providers.first { $0.id == .claude }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                header
                body(for: claude?.result ?? .loading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Probe on first appearance; load() guards against duplicate work and shares
        // the deferred Keychain prompt with the Usage page.
        .task { await model.usage.load() }
    }

    // Tool name + plan badge (e.g. "Claude" + "Team 5x") + a manual refresh control.
    private var header: some View {
        HStack(spacing: 10) {
            Text("Claude")
                .font(.title3.bold())
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if case let .ok(plan, _) = claude?.result, let plan, !plan.isEmpty {
                Pill(text: plan, tint: Theme.claude)
            }
            UsageBarRefreshButton()
        }
    }

    @ViewBuilder
    private func body(for result: UsageResult) -> some View {
        switch result {
        case .loading:
            UsageBarSkeleton()
        case let .ok(_, metrics):
            if metrics.isEmpty {
                UsageBarNote(icon: "checkmark.circle", text: "No active limits right now.")
            } else {
                VStack(spacing: 12) {
                    ForEach(metrics) { UsageMiniRow(metric: $0) }
                }
            }
        case let .notConfigured(message):
            UsageBarNote(icon: "minus.circle", text: message)
        case let .error(message):
            UsageBarNote(icon: "exclamationmark.circle", text: message, tint: Theme.orange)
        }
    }
}

// MARK: - Refresh control (manual re-probe from the Home usage card)
//
// A compact spinning-arrow button that re-probes usage on demand. Auto-refresh runs
// every 5 minutes from the app shell; this lets the user force an immediate update
// (e.g. right after a heavy Claude session) without leaving the home page.

private struct UsageBarRefreshButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            Task { await model.usage.refresh(); model.showToast("Refreshed") }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .rotationEffect(.degrees(model.usage.isRefreshing ? 360 : 0))
                .animation(model.usage.isRefreshing
                           ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                           : .default, value: model.usage.isRefreshing)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .disabled(model.usage.isRefreshing)
        .help("Refresh Claude usage")
        .accessibilityIdentifier("usage-bar-refresh")
    }
}

// MARK: - Loading + note states

private struct UsageBarSkeleton: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(Theme.hairFill).frame(width: 60, height: 9)
                    Capsule().fill(Theme.hairFill).frame(height: 7)
                }
                .opacity(pulse ? 0.45 : 0.9)
            }
        }
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}

private struct UsageBarNote: View {
    let icon: String
    let text: String
    var tint: Color = Theme.textSecondary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint == Theme.textSecondary ? Theme.textTertiary : tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(tint)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}
