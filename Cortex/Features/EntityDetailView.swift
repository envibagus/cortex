import SwiftUI

// MARK: - EntityStat
//
// One labelled value rendered as a StatTile inside an entity dashboard. The
// tint doubles as the StatTile's status dot so callers can color-code metrics
// (e.g. green for skills, blue for repos, yellow for cost).

struct EntityStat: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    var tint: Color = Theme.textSecondary
}

// MARK: - EntityDetailView
//
// The reusable per-entity dashboard panel presented in a sheet / inspector /
// NavigationStack push by Sessions, Repos, Tools, Skills, and Agents. It is a
// self-contained scroll view: a tinted header, a wrapping grid of StatTiles, an
// optional activity chart, and a caller-supplied `extra` slot for metadata or a
// content preview.

struct EntityDetailView<Extra: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let stats: [EntityStat]
    let activity: [DayActivity]            // empty -> hide the chart
    @ViewBuilder var extra: () -> Extra

    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Identity header (icon + title + subtitle)
                EntityHeader(title: title, subtitle: subtitle, icon: icon, tint: tint)

                // Metric grid built from the supplied stats
                if !stats.isEmpty {
                    EntityStatGrid(stats: stats)
                }

                // Activity chart, only when there is a series to plot
                if !activity.isEmpty {
                    EntityActivityCard(activity: activity, tint: tint)
                }

                // Caller-supplied content (metadata, preview, links)
                extra()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }
}

// MARK: - Convenience init for callers without extra content
//
// Lets Sessions / Tools / etc. construct an EntityDetailView that has no trailing
// `extra` slot without spelling out an empty closure.

extension EntityDetailView where Extra == EmptyView {
    init(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        stats: [EntityStat],
        activity: [DayActivity]
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            icon: icon,
            tint: tint,
            stats: stats,
            activity: activity,
            extra: { EmptyView() }
        )
    }
}

// MARK: - Header
//
// A tinted rounded square holding the entity glyph, beside a bold title and a
// secondary subtitle (path, scope, transport, etc).

private struct EntityHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Glyph badge (grayscale chrome: neutral fill + secondary outline glyph)
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.hairFill)
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                )

            // Title + subtitle
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.cortexTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Stat grid
//
// A responsive FlowGrid of StatTiles. Each EntityStat's tint becomes the tile's
// status dot.

private struct EntityStatGrid: View {
    let stats: [EntityStat]

    var body: some View {
        FlowGrid(data: stats, minWidth: 150) { stat in
            // Status dots are decorative chrome: keep them neutral grayscale.
            StatTile(label: stat.label, value: stat.value, dot: Theme.textSecondary)
        }
    }
}

// MARK: - Activity card
//
// The entity's recent daily activity, framed in a Card with a section header and
// an ActivityBarChart tinted to match the entity.

private struct EntityActivityCard: View {
    let activity: [DayActivity]
    let tint: Color

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                // Section header is chrome: outline glyph + neutral tint. The chart
                // bars below keep the entity color (that is data).
                SectionHeader(icon: "chart.bar", title: "Activity")
                ActivityBarChart(days: activity, tint: tint)
            }
        }
    }
}
