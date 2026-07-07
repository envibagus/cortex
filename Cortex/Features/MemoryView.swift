import SwiftUI
import AppKit

// MARK: - MemoryView
//
// The "Memory" config page over `model.config.memories` (markdown files under
// ~/.claude/memory). It uses a three-pane document browser: a
// header with a live count + name/hook search and a NATIVE selectable List on the
// LEFT (system accent selection), and the selected memory rendered as a document
// on the RIGHT (markdown body plus a pinned bottom metadata bar). An empty state
// shows when nothing is selected. Each list row shows a purple brain glyph, the
// name over the one-line hook, and the file size. The detail pane reads the file
// off disk lazily (falling back to the stored hook) and renders it with
// MarkdownText, with scope / path / size / modified in a native GroupBox of rows.

struct MemoryView: View {
    @Environment(AppModel.self) private var model

    // Live search query bound to the in-header search field
    @State private var query = ""
    // Scope filter (nil = all scopes: Global + every project).
    @State private var scope: String?
    // The id (file path) of the memory whose document is shown in the detail pane
    @State private var selectedID: MemoryItem.ID?

    // Distinct scopes for the filter menu: "Global" first, then projects A-Z.
    private var allScopes: [String] {
        let set = Set(model.config.memories.map(\.scope))
        let others = set.subtracting(["Global"])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return (set.contains("Global") ? ["Global"] : []) + others
    }

    // Memories filtered by the live query (name + hook) AND the selected scope, then
    // ordered by the app-wide library sort.
    private var filteredMemories: [MemoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.config.memories.filter { item in
            (scope == nil || item.scope == scope)
                && (trimmed.isEmpty
                    || [item.name, item.hook].contains { $0.localizedCaseInsensitiveContains(trimmed) })
        }.sorted(by: model.librarySort)
    }

    // Two-way binding to the app-wide library sort (persisted on the model).
    private var sortBinding: Binding<LibrarySort> {
        Binding(get: { model.librarySort }, set: { model.librarySort = $0 })
    }

    var body: some View {
        // In-page split: native list of memory files on the left, document on the right
        SplitDetailView(
            items: filteredMemories,
            selectedID: $selectedID,
            title: ConfigKind.memory.plural,
            subtitle: ConfigKind.memory.blurb,
            count: filteredMemories.count,
            emptyIcon: ConfigKind.memory.icon,
            emptyTitle: "No memory selected",
            emptyMessage: "Pick a memory file to read its contents.",
            // Zero memory files at all (not merely filtered out): whole-pane empty state.
            sourceIsEmpty: model.config.memories.isEmpty,
            zeroDataTitle: "No memory files yet",
            zeroDataMessage: "Memory files created by your tools show up here.",
            // ⌘C copies the memory file path.
            actions: { item in
                PageActions(copyPath: { model.copyPath(item.path) })
            }
        ) {
            // List header: page title + live count + name/hook search + scope + sort filter
            MemoryListHeader(query: $query, count: filteredMemories.count,
                             scope: $scope, scopes: allScopes, sort: sortBinding)
        } row: { item, _ in
            // Plain row content: the native List draws the system selection highlight
            MemoryRow(item: item)
        } detail: { item in
            MemoryDetail(item: item)
        }
        // When the scope filter hides the current selection, fall back to the first match.
        .onChange(of: scope) { _, _ in
            if let id = selectedID, !filteredMemories.contains(where: { $0.id == id }) {
                selectedID = filteredMemories.first?.id
            }
        }
        // Apply a scope/search an assistant CTA deep-linked here with (e.g. a
        // "<project> Memory" button pre-filters to that project, not all scopes).
        // Resolve the CTA's scope tolerantly against the real memory scope names.
        .onAppear {
            let pending = model.consumePending(for: .memory)
            if let s = pending.search { query = s }
            if let sc = pending.scope {
                scope = allScopes.first { $0.localizedCaseInsensitiveCompare(sc) == .orderedSame }
                    ?? allScopes.first { $0.localizedCaseInsensitiveContains(sc) }
                    ?? sc
            }
        }
    }
}

// MARK: - Memory list header
//
// The left pane header: a tinted brain glyph + "Memory" title with the live count,
// and a self-contained search field that filters by name or hook. Kept inside the
// split's listHeader so the page needs no separate PageScaffold chrome.

private struct MemoryListHeader: View {
    @Binding var query: String
    let count: Int
    @Binding var scope: String?
    let scopes: [String]
    @Binding var sort: LibrarySort

    var body: some View {
        // Title + count + blurb now live in the toolbar band (`.cortexPageChrome`); the
        // left pane keeps just the shared search / scope / sort filter.
        LibraryFilterBar(
            query: $query,
            placeholder: "Search by name or hook",
            scope: $scope,
            scopes: scopes,
            sort: $sort
        )
    }
}

// MARK: - Memory row
//
// One memory file in the native left list. PLAIN content (no SelectableRow / custom
// background) so the system List paints the accent selection: a purple brain glyph,
// the bold name over its one-line hook (secondary, single line), then the file size
// as a trailing caption.

private struct MemoryRow: View {
    let item: MemoryItem

    var body: some View {
        HStack(spacing: 11) {
            // Memory glyph
            Image(systemName: "brain")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            // Name over its one-line hook
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Text(item.hook)
                    .font(.cortexCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            // Trailing file size
            Text(MemoryFormat.size(item.sizeBytes))
                .font(.cortexCaption)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Memory detail
//
// The right pane for one memory file, styled like a stock macOS document viewer: a
// VStack(spacing: 0) whose top is the preview/source toggle toolbar and whose body
// is the shared NativeDocumentDetail column (a large native title + the rendered
// markdown OR monospaced source, plus a native GroupBox of LabeledContent metadata
// rows: scope / location / size / modified). The file is read lazily off disk via
// String(contentsOfFile:), falling back to the stored one-line hook when it cannot
// be read. Reloads whenever a different memory is selected (keyed by item.id).

private struct MemoryDetail: View {
    let item: MemoryItem

    // The on-disk contents, loaded lazily for the current item
    @State private var content: String?
    @State private var loadedID: MemoryItem.ID?
    // Toggle between rendered markdown (false) and raw source (true)
    @State private var showSource = false

    var body: some View {
        // Shared native document body: title + markdown/source + metadata. The favorite
        // + preview/source toggle floats in the top-right corner (no opaque band) and the
        // inline title reveals on scroll, matching the other library browsers.
        // Document body over a pinned status footer (kind badge + path + size + modified),
        // matching the Agents / Skills detail panes exactly.
        VStack(spacing: 0) {
            NativeDocumentDetail(
                title: item.name,
                subtitle: nil,
                content: bodyText,
                showSource: showSource,
                metadata: metadata,
                topTrailing: AnyView(MemoryActionBar(id: item.id, path: item.path, showSource: $showSource))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            DocumentFooter(kindLabel: ConfigKind.memory.singular.uppercased(),
                           path: item.path,
                           sizeBytes: item.sizeBytes,
                           modified: item.modified)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .task(id: item.id) { loadContent() }
    }

    // Metadata rows for the GroupBox: scope, location, size, modified.
    private var metadata: [DocumentMetadataRow] {
        [
            DocumentMetadataRow(label: "Scope", value: item.scope),
            DocumentMetadataRow(label: "Location", value: MemoryFormat.tildePath(item.path)),
            DocumentMetadataRow(label: "Size", value: MemoryFormat.size(item.sizeBytes)),
            DocumentMetadataRow(label: "Modified", value: item.modified.formatted(date: .abbreviated, time: .shortened)),
        ]
    }

    // Resolved markdown: trimmed file contents, else the stored one-line hook
    private var bodyText: String {
        if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }
        return item.hook
    }

    // Read the markdown file off disk once per selected item
    private func loadContent() {
        guard loadedID != item.id else { return }
        loadedID = item.id
        content = try? String(contentsOfFile: item.path, encoding: .utf8)
    }
}

// MARK: - MemoryActionBar
//
// The detail pane's floating top-right accessory (passed to NativeDocumentDetail as
// `topTrailing`, so it floats over the document with no opaque band): two glass pills -
// a preview/source toggle (eye + code) and a favorite star pill - matching the other
// library browsers' floating toolbars exactly.

private struct MemoryActionBar: View {
    @Environment(AppModel.self) private var model
    let id: String
    let path: String
    @Binding var showSource: Bool
    @State private var confirmingDelete = false

    var body: some View {
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 10) {
                // Left pill: markdown preview / source toggle (eye + code)
                DocumentSourceToggle(showSource: $showSource)

                // Right pill: favorite star + an ellipsis menu (Show in Finder / Delete),
                // matching the Skills / Agents detail toolbars.
                HStack(spacing: 2) {
                    FavoriteToggle(id: id)

                    Menu {
                        Button {
                            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                        Divider()
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("Delete\u{2026}", systemImage: "trash")
                        }
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
        // Native confirmation before moving the memory file to the Trash (reversible).
        .alert("Move this memory to the Trash?", isPresented: $confirmingDelete) {
            Button("Move to Trash", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The memory file moves to the Trash. Undo from the toast, or restore it from the Trash.")
        }
    }

    private func performDelete() {
        let name = (path as NSString).lastPathComponent
        guard let result = try? MemoryFileOps.trash(path) else {
            model.showToast("Couldn't move \u{201C}\(name)\u{201D} to the Trash")
            return
        }
        // Rescan so the trashed file drops out of the list immediately.
        Task { await model.config.load(roots: model.scanRoots) }
        model.showToast(
            "Moved \u{201C}\(name)\u{201D} to the Trash",
            action: AppModel.ToastAction(label: "Undo") {
                do {
                    try MemoryFileOps.restore(from: result.trashed, to: result.original)
                    Task { await model.config.load(roots: model.scanRoots) }
                } catch {
                    // The Trash item may be gone, or a new file now occupies the original path.
                    model.showToast("Couldn't restore \u{201C}\(name)\u{201D} - check the Trash")
                }
            }
        )
    }
}

// MARK: - Memory formatting helpers
//
// Shared byte / path formatting so the row and detail pane display identically.

private enum MemoryFormat {
    // A compact human-readable file size, e.g. "12 KB"
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // Abbreviate an absolute path by replacing the home directory with a tilde
    static func tildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
