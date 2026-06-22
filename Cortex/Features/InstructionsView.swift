import SwiftUI
import AppKit

// MARK: - InstructionsView
//
// Browses every CLAUDE.md / AGENTS.md discovered by ConfigScanner as .instruction
// ConfigItems. These are the long-form instruction documents that steer the coding
// tools, so the markdown body is the star: the layout is a native
// browser (a header + native selectable List on the left, a document-style markdown
// detail on the right with a preview/source toggle and a native metadata GroupBox).
//
// It mirrors SkillsView's ConfigBrowser pattern but keeps its own minimal rows:
// a quiet leading book glyph, the document name, a Spacer, an optional favorite
// star, and a small trailing caption naming the file (CLAUDE.md / AGENTS.md). The
// native List draws the selection highlight, so rows stay PLAIN.

struct InstructionsView: View {
    @Environment(AppModel.self) private var model

    // Live search query bound to the list-header search field
    @State private var query = ""
    // The id of the row whose detail is shown in the right pane (nil == none)
    @State private var selectedID: ConfigItem.ID?

    // New-collection native alert state (shared by row + detail menus)
    @State private var showNewCollectionAlert = false
    @State private var newCollectionName = ""
    // Item that triggered "New Collection..."; the just-created collection adds it.
    @State private var pendingMembershipID: String?
    // Scope filter (nil = all): "Global" or a project name.
    @State private var scope: String?

    // Distinct scopes for the filter chips: "Global" first, then projects A-Z.
    private var scopes: [String] {
        let set = Set(model.config.instructions.map(\.scopeLabel))
        let others = set.subtracting(["Global"])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return (set.contains("Global") ? ["Global"] : []) + others
    }

    // Instruction docs filtered by the live query (name + detail + filename) AND scope,
    // then ordered by the app-wide library sort.
    private var filtered: [ConfigItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.config.instructions.filter { item in
            (scope == nil || item.scopeLabel == scope)
                && (trimmed.isEmpty
                    || item.name.localizedCaseInsensitiveContains(trimmed)
                    || item.detail.localizedCaseInsensitiveContains(trimmed)
                    || InstructionFmt.fileLabel(for: item).localizedCaseInsensitiveContains(trimmed))
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
            emptyIcon: ConfigKind.instruction.icon,
            emptyTitle: "No instructions selected",
            emptyMessage: "Select a CLAUDE.md or AGENTS.md on the left to read it."
        ) {
            // Left-pane header: page title + live count + search + scope + sort filter
            InstructionsListHeader(count: filtered.count, query: $query, scope: $scope, scopes: scopes, sort: sortBinding)
        } row: { item, _ in
            // Plain row content: the native List handles the selection highlight,
            // so this MUST NOT be wrapped in SelectableRow or a custom background.
            InstructionRow(item: item)
                .contextMenu {
                    LibraryItemMenu(item: item, requestNewCollection: requestNewCollection)
                }
        } detail: { item in
            InstructionDetail(item: item, requestNewCollection: requestNewCollection)
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
        // When arriving here from "Create CLAUDE.md" in Repos, land on the new file.
        .onAppear {
            if let id = model.recentlyCreatedID, filtered.contains(where: { $0.id == id }) {
                selectedID = id
            }
        }
        // Single native alert with a TextField + Create button, reached from any menu.
        .alert("New Collection", isPresented: $showNewCollectionAlert) {
            TextField("Collection name", text: $newCollectionName)
            Button("Cancel", role: .cancel) {
                newCollectionName = ""
                pendingMembershipID = nil
            }
            Button("Create") { createCollection() }
        } message: {
            Text("Name your new collection.")
        }
    }

    // Open the new-collection alert, remembering which item should join it.
    private func requestNewCollection(for itemID: String) {
        pendingMembershipID = itemID
        newCollectionName = ""
        showNewCollectionAlert = true
    }

    // Create the collection from the alert's field, then add the pending item to it.
    private func createCollection() {
        let trimmed = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { newCollectionName = ""; pendingMembershipID = nil; return }
        let collection = model.library.createCollection(name: trimmed)
        if let itemID = pendingMembershipID {
            model.toggleMember(itemID, in: collection.id)
        }
        newCollectionName = ""
        pendingMembershipID = nil
    }
}

// MARK: - InstructionsListHeader
//
// The left pane's sticky header: the page title with the instruction glyph + a live
// count pill, above a self-contained search field that filters the list.

private struct InstructionsListHeader: View {
    let count: Int
    @Binding var query: String
    @Binding var scope: String?
    let scopes: [String]
    @Binding var sort: LibrarySort

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title row: smaller page title (the name also shows in the toolbar) + count.
            HStack(spacing: 8) {
                Text(ConfigKind.instruction.plural)
                    .font(.cortexTitle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Shared search + scope filter (Global / each project) + sort.
            LibraryFilterBar(query: $query, placeholder: "Search instructions", scope: $scope, scopes: scopes, sort: $sort)
        }
    }
}

// MARK: - InstructionSearchField
//
// A compact themed search field (magnifier glyph + text field + clear button) used
// inside the split list header, since the split pane has no toolbar `.searchable`.

private struct InstructionSearchField: View {
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

// MARK: - InstructionRow
//
// One PLAIN, minimal, native row in the left list: a quiet leading book glyph, the
// document name (one line), a small favorite star when favorited, a Spacer, and a
// small trailing caption naming the backing file (CLAUDE.md / AGENTS.md). No pills,
// no custom background: the enclosing List(selection:) draws the highlight.

private struct InstructionRow: View {
    @Environment(AppModel.self) private var model
    let item: ConfigItem

    var body: some View {
        HStack(spacing: 8) {
            // Leading instruction glyph (quiet, secondary)
            Image(systemName: ConfigKind.instruction.icon)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            // Document name
            Text(item.name)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            // Favorite indicator: a tiny star shown only when favorited.
            if model.library.isFavorite(item.id) {
                Image(systemName: "star")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            // Trailing caption naming the file (CLAUDE.md / AGENTS.md)
            Text(InstructionFmt.fileLabel(for: item))
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - InstructionDetail
//
// The right-pane document viewer: a top action toolbar (favorite star, an ellipsis
// library menu, and a markdown preview/source toggle), then the shared, native
// NativeDocumentDetail document column (a large native title + the document's
// scope/filename subtitle + rendered markdown OR raw source, with a native GroupBox
// of LabeledContent metadata rows). Re-identified by item id so the scroll + toggle
// reset on change.

private struct InstructionDetail: View {
    let item: ConfigItem
    let requestNewCollection: (String) -> Void

    // Markdown preview (false) vs raw source (true). Resets per selection because the
    // whole detail is re-identified by item.id below.
    @State private var showSource = false

    // Secondary subtitle: scope and filename, plus the detail line when meaningful.
    private var subtitle: String {
        let head = "\(item.scopeLabel) · \(InstructionFmt.fileLabel(for: item))"
        let detail = item.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? head : "\(head) · \(detail)"
    }

    var body: some View {
        // Shared native document body: title + subtitle + markdown/source + metadata.
        // The action buttons float in the top-right corner (no opaque band) and the
        // inline title reveals on scroll, matching the Skills/Agents browsers.
        // Document body over a pinned status footer, matching the Agents / Skills panes.
        VStack(spacing: 0) {
            NativeDocumentDetail(
                title: item.name,
                subtitle: subtitle,
                content: item.content,
                showSource: showSource,
                metadata: metadata,
                topTrailing: AnyView(
                    InstructionActionBar(
                        item: item,
                        showSource: $showSource,
                        requestNewCollection: requestNewCollection
                    )
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            DocumentFooter(item: item)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        // Reset the scroll position + toggle when the selection changes.
        .id(item.id)
    }

    // Metadata rows for the GroupBox: scope, file, size, modified.
    private var metadata: [DocumentMetadataRow] {
        [
            DocumentMetadataRow(label: "Scope", value: item.scopeLabel),
            DocumentMetadataRow(label: "File", value: InstructionFmt.fileLabel(for: item)),
            DocumentMetadataRow(label: "Size", value: InstructionFmt.size(item.fileSize)),
            DocumentMetadataRow(label: "Modified", value: item.modified.formatted(date: .abbreviated, time: .shortened)),
        ]
    }
}

// MARK: - InstructionActionBar
//
// The detail pane's floating top-right accessory (passed to NativeDocumentDetail as
// `topTrailing`, so it floats over the document with no opaque band): two glass pills
// grouped together - a preview/source toggle (eye + code) and a favorite + ellipsis
// menu pill - matching the Skills/Agents DetailActionBar exactly.

private struct InstructionActionBar: View {
    let item: ConfigItem
    @Binding var showSource: Bool
    let requestNewCollection: (String) -> Void

    var body: some View {
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 10) {
                // Left pill: markdown preview / source toggle (eye + code)
                DocumentSourceToggle(showSource: $showSource)

                // Right pill: favorite + ellipsis menu (same button size as the left pill)
                HStack(spacing: 2) {
                    StarButton(item: item)

                    Menu {
                        LibraryItemMenu(item: item, requestNewCollection: requestNewCollection)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 26)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(4)
                .glassPill()
            }
        }
    }
}

// MARK: - InstructionFmt
//
// Small formatting helpers for the instruction detail bar: the backing filename
// label (CLAUDE.md / AGENTS.md / the file's own name), a locale-aware byte size, and
// a home-abbreviated path. File-scoped so it never collides with ConfigFmt.

enum InstructionFmt {
    // File-size formatter: bytes / KB / MB, locale-aware.
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB]
        return f
    }()

    // The backing filename (e.g. "CLAUDE.md", "AGENTS.md"), derived from the path.
    static func fileLabel(for item: ConfigItem) -> String {
        let last = (item.path as NSString).lastPathComponent
        return last.isEmpty ? "Instruction" : last
    }

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
