import SwiftUI
import AppKit

// MARK: - PluginsView
//
// Browses every plugin discovered by ConfigScanner as .plugin ConfigItems
// (~/.claude/plugins). It is the same native browser as SkillsView:
// a header + native selectable List on the left, and the selected plugin's detail
// on the right. The native List draws the selection highlight, so rows stay PLAIN.
//
// Plugins are lighter weight than instruction docs: they may have no markdown body,
// so the detail falls back to a clean info layout. They also have no library home,
// so there are no favorites / collections here, just Show in Finder.

struct PluginsView: View {
    @Environment(AppModel.self) private var model

    // Live search query bound to the list-header search field
    @State private var query = ""
    // Scope filter (nil = all): "Global" or a project name.
    @State private var scope: String?
    // The id of the row whose detail is shown in the right pane (nil == none)
    @State private var selectedID: ConfigItem.ID?

    // Distinct scopes for the filter chips: "Global" first, then projects A-Z.
    private var scopes: [String] {
        let set = Set(model.config.plugins.map(\.scopeLabel))
        let others = set.subtracting(["Global"])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return (set.contains("Global") ? ["Global"] : []) + others
    }

    // Plugins filtered by the live query (name + detail) AND the selected scope, then
    // ordered by the app-wide library sort.
    private var filtered: [ConfigItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.config.plugins.filter { item in
            (scope == nil || item.scopeLabel == scope)
                && (trimmed.isEmpty
                    || item.name.localizedCaseInsensitiveContains(trimmed)
                    || item.detail.localizedCaseInsensitiveContains(trimmed))
        }.sorted(by: model.librarySort)
    }

    // Two-way binding to the app-wide library sort (persisted on the model).
    private var sortBinding: Binding<LibrarySort> {
        Binding(get: { model.librarySort }, set: { model.librarySort = $0 })
    }

    var body: some View {
        SplitDetailView(
            items: filtered,
            selectedID: $selectedID,
            emptyIcon: ConfigKind.plugin.icon,
            emptyTitle: "No plugins selected",
            emptyMessage: "Select a plugin on the left to see its details."
        ) {
            // Left-pane header: page title + live count + search + scope + sort filter
            PluginsListHeader(count: filtered.count, query: $query, scope: $scope, scopes: scopes, sort: sortBinding)
        } row: { item, _ in
            // Plain row content: the native List handles the selection highlight,
            // so this MUST NOT be wrapped in SelectableRow or a custom background.
            PluginRow(item: item)
                .contextMenu {
                    Button {
                        NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
        } detail: { item in
            PluginDetail(item: item)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        // When the search filters out the current selection, fall back to the first
        // remaining row (or nothing) so the detail pane never shows a stale item.
        .onChange(of: query) { _, _ in
            if let id = selectedID, !filtered.contains(where: { $0.id == id }) {
                selectedID = filtered.first?.id
            }
        }
        .onChange(of: scope) { _, _ in
            if let id = selectedID, !filtered.contains(where: { $0.id == id }) {
                selectedID = filtered.first?.id
            }
        }
    }
}

// MARK: - PluginsListHeader
//
// The left pane's sticky header: the page title with the plugin glyph + a live count
// pill, above a self-contained search field that filters the list.

private struct PluginsListHeader: View {
    let count: Int
    @Binding var query: String
    @Binding var scope: String?
    let scopes: [String]
    @Binding var sort: LibrarySort

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title row: smaller page title (name also shows in the toolbar) + count.
            HStack(spacing: 8) {
                Text(ConfigKind.plugin.plural)
                    .font(.cortexTitle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Shared search + scope filter (Global / each project) + sort.
            LibraryFilterBar(query: $query, placeholder: "Search plugins", scope: $scope, scopes: scopes, sort: $sort)
        }
    }
}

// MARK: - PluginSearchField
//
// A compact themed search field (magnifier glyph + text field + clear button) used
// inside the split list header, since the split pane has no toolbar `.searchable`.

private struct PluginSearchField: View {
    @Binding var query: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .fill(Theme.hairFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        )
    }
}

// MARK: - PluginRow
//
// One PLAIN, minimal, native row in the left list: a quiet leading puzzlepiece
// glyph, the plugin name (one line), a Spacer, and a small trailing detail caption.
// No pills, no custom background: the enclosing List(selection:) draws the highlight.

private struct PluginRow: View {
    let item: ConfigItem

    var body: some View {
        HStack(spacing: 8) {
            // Leading plugin glyph (quiet, secondary)
            Image(systemName: ConfigKind.plugin.icon)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            // Plugin name
            Text(item.name)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            // Trailing detail caption (scope / short description)
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - PluginDetail
//
// The right-pane viewer: a top action toolbar (Show in Finder), then the shared
// native NativeDocumentDetail document column (a large native title + detail
// subtitle + rendered MarkdownText when the plugin ships a readme/body, else an
// empty note, with a native GroupBox of LabeledContent metadata rows). Plugins have
// no preview/source toggle, so the body always renders the markdown preview.
// Re-identified by item id so the scroll resets on change.

private struct PluginDetail: View {
    let item: ConfigItem

    var body: some View {
        // Shared native document body: title + subtitle + markdown + metadata. The
        // Show in Finder button floats in the top-right corner (no opaque band) and the
        // inline title reveals on scroll, matching the other library browsers.
        // Document body over a pinned status footer, matching the Agents / Skills panes.
        VStack(spacing: 0) {
            NativeDocumentDetail(
                title: item.name,
                subtitle: item.detail.isEmpty ? nil : item.detail,
                content: item.content,
                showSource: false,
                metadata: metadata,
                topTrailing: AnyView(PluginActionBar(item: item))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            DocumentFooter(item: item)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        // Reset the scroll position when the selection changes.
        .id(item.id)
    }

    // Metadata rows for the GroupBox: scope, location, size, modified.
    private var metadata: [DocumentMetadataRow] {
        [
            DocumentMetadataRow(label: "Scope", value: item.scopeLabel),
            DocumentMetadataRow(label: "Location", value: PluginFmt.abbreviatePath(item.path)),
            DocumentMetadataRow(label: "Size", value: PluginFmt.size(item.fileSize)),
            DocumentMetadataRow(label: "Modified", value: item.modified.formatted(date: .abbreviated, time: .shortened)),
        ]
    }
}

// MARK: - PluginActionBar
//
// The detail pane's floating top-right accessory (passed to NativeDocumentDetail as
// `topTrailing`). Plugins have no library home, so this is just a quiet Show in Finder
// button (the native idiom for revealing the backing file/folder), in a glass pill so
// it matches the other browsers' floating toolbars.

private struct PluginActionBar: View {
    let item: ConfigItem

    var body: some View {
        // Reveal the backing file in Finder.
        Button {
            NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
        } label: {
            Image(systemName: "folder")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show in Finder")
        .padding(4)
        .glassPill()
    }
}

// MARK: - PluginFmt
//
// Small formatting helpers for the plugin detail bar: a locale-aware byte size and
// a home-abbreviated path. File-scoped so it never collides with ConfigFmt.

enum PluginFmt {
    // File-size formatter: bytes / KB / MB, locale-aware.
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB]
        return f
    }()

    // Human-readable file size from a raw byte count.
    static func size(_ bytes: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(bytes))
    }

    // Collapse the user's home directory prefix to "~" for compact display.
    static func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
