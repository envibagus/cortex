import SwiftUI
import AppKit

// MARK: - HooksView
//
// The "Hooks" config page over `model.config.hooks` (flattened from
// settings.json and settings.local.json). Hooks are grouped by lifecycle event:
// one section per event, headed by the event name as a colored badge plus a
// per-event count. Each row shows the matcher (when present), the command in
// mono (truncated, with a copy button), and a source Pill.

struct HooksView: View {
    @Environment(AppModel.self) private var model

    // Hooks grouped by event, each group already command-sorted by ConfigScanner,
    // with events ordered by the canonical lifecycle then alphabetically.
    private var groups: [HookGroup] {
        let byEvent = Dictionary(grouping: model.config.hooks, by: \.event)
        return byEvent
            .map { HookGroup(event: $0.key, hooks: $0.value) }
            .sorted { lhs, rhs in
                let l = HookStyle.order(of: lhs.event)
                let r = HookStyle.order(of: rhs.event)
                if l != r { return l < r }
                return lhs.event.localizedCaseInsensitiveCompare(rhs.event) == .orderedAscending
            }
    }

    var body: some View {
        PageScaffold(
            title: "Hooks",
            subtitle: ConfigKind.hook.blurb
        ) {
            // Section header with the live total hook count
            SectionHeader(
                icon: ConfigKind.hook.icon,
                title: ConfigKind.hook.plural,
                tint: Theme.orange,
                trailing: "\(model.config.hooks.count)"
            )

            // One grouped card per event, or an empty state when nothing is configured
            if groups.isEmpty {
                Card(padding: 0) {
                    CortexEmptyState(
                        icon: ConfigKind.hook.icon,
                        title: "No hooks",
                        message: "Add a \"hooks\" block to ~/.claude/settings.json to see them here."
                    )
                }
            } else {
                ForEach(groups) { group in
                    HookEventSection(group: group)
                }
            }
        }
    }
}

// MARK: - Hook group model
//
// One lifecycle event and all of its hook commands.

private struct HookGroup: Identifiable {
    var id: String { event }
    let event: String
    let hooks: [HookItem]
}

// MARK: - Hook event section
//
// A Card per event: a header that shows the event name as a colored, filled
// badge plus the per-event count, then a hairline-separated stack of hook rows.

private struct HookEventSection: View {
    let group: HookGroup

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // Event badge header
                HStack(spacing: 8) {
                    Pill(text: group.event, tint: HookStyle.tint(for: group.event), filled: true)
                    Text("\(group.hooks.count) \(group.hooks.count == 1 ? "hook" : "hooks")")
                        .font(.cortexCaption)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider().overlay(Theme.stroke)

                // Hook rows for this event
                ForEach(Array(group.hooks.enumerated()), id: \.element.id) { index, hook in
                    if index > 0 {
                        Divider().overlay(Theme.stroke)
                    }
                    HookRow(hook: hook, tint: HookStyle.tint(for: group.event))
                }
            }
        }
    }
}

// MARK: - Hook row
//
// One hook command: an optional matcher pill on the leading edge, the command in
// mono (truncated) with a copy button, and a trailing source Pill.

private struct HookRow: View {
    let hook: HookItem
    let tint: Color

    // Confirmation state for the copy button (resets shortly after a copy)
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            // Matcher + command stack
            VStack(alignment: .leading, spacing: 6) {
                // Matcher pattern, only when this hook is scoped to one
                if let matcher = hook.matcher, !matcher.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        Text(matcher)
                            .font(.cortexMono)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                // The command itself in mono, truncated to a single line
                Text(hook.command)
                    .font(.cortexMono)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Favorite + copy + source cluster
            HStack(spacing: 8) {
                FavoriteToggle(id: hook.id)
                CopyButton(copied: copied) { copyCommand() }
                Pill(text: hook.source, tint: Theme.textSecondary, filled: false)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // Write the command to the pasteboard and flash the copied confirmation
    private func copyCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hook.command, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }
}

// MARK: - Copy button
//
// A small mono-command copy control that swaps to a green checkmark for a beat
// after a successful copy.

private struct CopyButton: View {
    let copied: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(copied ? Theme.green : (hovering ? Theme.textPrimary : Theme.textTertiary))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                        .fill(hovering ? Theme.cardRaised : .clear)
                )
        }
        .buttonStyle(.plain)
        .linkCursor()
        .onHover { hovering = $0 }
        .help(copied ? "Copied" : "Copy command")
    }
}

// MARK: - Hook presentation helpers
//
// Shared lifecycle ordering and per-event tint so the section badges stay stable
// and color-coded by phase (start / tool use / completion / notification).

private enum HookStyle {
    // Canonical lifecycle order; unknown events sort to the end alphabetically.
    private static let lifecycle: [String] = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Notification", "PreCompact", "Stop", "SubagentStop", "SessionEnd",
    ]

    static func order(of event: String) -> Int {
        lifecycle.firstIndex(of: event) ?? lifecycle.count
    }

    // Color an event by its lifecycle phase for the section badge.
    static func tint(for event: String) -> Color {
        switch event {
        case "SessionStart": Theme.green
        case "UserPromptSubmit": Theme.blue
        case "PreToolUse": Theme.purple
        case "PostToolUse": Theme.claude
        case "Notification": Theme.yellow
        case "PreCompact": Theme.orange
        case "Stop", "SubagentStop", "SessionEnd": Theme.warn
        default: Theme.textSecondary
        }
    }
}
