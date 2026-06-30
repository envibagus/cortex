import SwiftUI
import AppKit

// MARK: - SkillsView
//
// Browses every skill discovered by ConfigScanner (~/.claude/skills/<dir>/SKILL.md).
// It is a thin wrapper over the shared ConfigBrowser: same in-page split layout
// (a native selectable list on the left, a document-style markdown detail pane on
// the right) used by AgentsView, parameterized by ConfigKind.

struct SkillsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ConfigBrowser(
            kind: .skill,
            tint: Color.secondary,
            emptyMessage: "Add skills under ~/.claude/skills/<name>/SKILL.md to see them here.",
            items: model.config.skills
        )
    }
}

// MARK: - ConfigBrowser
//
// The shared in-page split browser over an array of ConfigItem (skills or agents).
// The LEFT pane is a header (page title + live count + search field) above a NATIVE
// List(selection:) of plain rows (the system draws the selection highlight); the
// RIGHT pane is the selected item's document-style detail pane (markdown body + a
// pinned bottom metadata bar) or an empty state when nothing is selected. Owned here
// and reused by AgentsView so the two pages stay identical in behavior and styling.
//
// Library features (favorites + collections) live here too: rows show a favorite
// star and a full item context menu, the detail pane has a star toggle + an ellipsis
// menu + a markdown preview/source toggle, and the "New Collection..." flow is wired
// to a single native .alert hosted at this level (so both row and detail menus reach
// the same TextField + Create button).

struct ConfigBrowser: View {
    @Environment(AppModel.self) private var model

    let kind: ConfigKind
    let tint: Color
    let emptyMessage: String
    let items: [ConfigItem]

    // Live search query bound to the list-header search field
    @State private var query = ""
    // Scope filter (nil = all): "Global" or a project name.
    @State private var scope: String?
    // The id of the row whose detail is shown in the right pane (nil == none)
    @State private var selectedID: ConfigItem.ID?

    // New-collection native alert state (shared by row + detail menus)
    @State private var showNewCollectionAlert = false
    @State private var newCollectionName = ""
    // Item that triggered "New Collection..."; the just-created collection adds it.
    @State private var pendingMembershipID: String?

    // Distinct scopes for the filter chips: "Global" first, then projects A-Z.
    private var scopes: [String] {
        let set = Set(items.map(\.scopeLabel))
        let others = set.subtracting(["Global"])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return (set.contains("Global") ? ["Global"] : []) + others
    }

    // Items filtered by the live query (name + detail) AND the selected scope, then
    // ordered by the app-wide library sort. A freshly created item
    // (model.recentlyCreatedID) is floated to the FRONT - AFTER sorting - so it shows
    // at the top of the list while it is being created + auto-edited.
    private var filtered: [ConfigItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = items.filter { item in
            (scope == nil || item.scopeLabel == scope)
                && (trimmed.isEmpty
                    || item.name.localizedCaseInsensitiveContains(trimmed)
                    || item.detail.localizedCaseInsensitiveContains(trimmed))
        }.sorted(by: model.librarySort)
        guard let createdID = model.recentlyCreatedID,
              let idx = matches.firstIndex(where: { $0.id == createdID }) else { return matches }
        var floated = matches
        let item = floated.remove(at: idx)
        floated.insert(item, at: 0)
        return floated
    }

    // Two-way binding to the app-wide library sort (persisted on the model), passed
    // into the filter bar's sort button so changing it reorders the list everywhere.
    private var sortBinding: Binding<LibrarySort> {
        Binding(get: { model.librarySort }, set: { model.librarySort = $0 })
    }

    var body: some View {
        SplitDetailView(
            items: filtered,
            selectedID: $selectedID,
            emptyIcon: kind.icon,
            emptyTitle: "No \(kind.singular.lowercased()) selected",
            emptyMessage: "Select a \(kind.singular.lowercased()) on the left to see its dashboard."
        ) {
            // Left-pane header: page title + live count + search + scope + sort filter
            ConfigListHeader(
                kind: kind,
                count: filtered.count,
                query: $query,
                scope: $scope,
                scopes: scopes,
                sort: sortBinding
            )
        } row: { item, _ in
            // Plain row content: the native List handles the selection highlight,
            // so this MUST NOT be wrapped in SelectableRow or a custom background.
            // The full item context menu is attached here for right-click access.
            ConfigItemRow(item: item)
                .contextMenu {
                    LibraryItemMenu(item: item, requestNewCollection: requestNewCollection)
                }
        } detail: { item in
            ConfigItemDetail(item: item, tint: tint, requestNewCollection: requestNewCollection)
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
        // Same fallback when the scope filter hides the current selection.
        .onChange(of: scope) { _, _ in
            if let id = selectedID, !filtered.contains(where: { $0.id == id }) {
                selectedID = filtered.first?.id
            }
        }
        // A freshly created item (in THIS browser's list) becomes the selection so its
        // detail mounts and ConfigItemDetail can auto-open the editor. Guard on the id
        // belonging here so the other browsers (a different kind) ignore it.
        .onChange(of: model.recentlyCreatedID) { _, new in
            if let new, items.contains(where: { $0.id == new }) {
                selectedID = new
            }
        }
        // The new item floats at the top only while it stays selected; once the user
        // picks a different row, drop the float so the list returns to normal order.
        .onChange(of: selectedID) { _, new in
            if let created = model.recentlyCreatedID, new != created {
                model.recentlyCreatedID = nil
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

// MARK: - StarButton
//
// A native favorite toggle: a borderless Button flipping model.library.toggleFavorite
// for the item, drawing an outline star tinted .primary when favorited (the active
// state) and .secondary otherwise (grayscale chrome). Shared by Skills and Agents.

struct StarButton: View {
    @Environment(AppModel.self) private var model
    let item: ConfigItem

    private var isFavorite: Bool { model.library.isFavorite(item.id) }

    var body: some View {
        Button {
            model.toggleFavorite(item.id)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isFavorite ? .primary : .secondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
    }
}

// MARK: - LibraryItemMenu
//
// The full item action menu, used both as a row .contextMenu and as the content of
// the detail pane's ellipsis Menu. NATIVE controls only: a Favorite/Unfavorite
// Button, a "Collections" submenu (one Button per collection toggling membership
// with a checkmark when a member, then a Divider and "New Collection...") and a
// "Show in Finder" Button. `requestNewCollection` raises the host's native alert.

struct LibraryItemMenu: View {
    @Environment(AppModel.self) private var model
    let item: ConfigItem
    let requestNewCollection: (String) -> Void
    // Optional document actions (only the detail-pane ellipsis passes these, so row
    // context menus stay unchanged): copy a project skill to ~/.claude/skills, and a
    // destructive delete-to-Trash.
    var onMakeGlobal: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    private var isFavorite: Bool { model.library.isFavorite(item.id) }

    var body: some View {
        // Favorite toggle
        Button {
            model.toggleFavorite(item.id)
        } label: {
            Label(isFavorite ? "Unfavorite" : "Favorite",
                  systemImage: isFavorite ? "star.slash" : "star")
        }

        // Collections submenu: membership toggles + New Collection...
        Menu {
            ForEach(model.library.collections) { collection in
                Button {
                    model.toggleMember(item.id, in: collection.id)
                } label: {
                    // A checkmark indicates current membership (native Menu idiom).
                    if model.library.isMember(item.id, of: collection.id) {
                        Label(collection.name, systemImage: "checkmark")
                    } else {
                        Text(collection.name)
                    }
                }
            }
            Divider()
            Button {
                requestNewCollection(item.id)
            } label: {
                Label("New Collection...", systemImage: "plus")
            }
        } label: {
            Label("Collections", systemImage: "rectangle.stack")
        }

        Divider()

        // Reveal the backing file in Finder.
        Button {
            NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }

        // Make a project-scoped skill available globally.
        if let onMakeGlobal {
            Button(action: onMakeGlobal) {
                Label("Make Skill Global", systemImage: "globe")
            }
        }

        // Delete (to Trash). Kept last + destructive so it reads as the heavy action.
        if let onDelete {
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete\u{2026}", systemImage: "trash")
            }
        }
    }
}

// MARK: - ConfigListHeader
//
// The left pane's sticky header: the page title with the kind glyph + a live count
// pill, above a self-contained search field that filters the list by name/detail.

private struct ConfigListHeader: View {
    let kind: ConfigKind
    let count: Int
    @Binding var query: String
    @Binding var scope: String?
    let scopes: [String]
    @Binding var sort: LibrarySort

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title row: smaller page title (the page name also shows in the toolbar) +
            // a plain gray count, no leading kind glyph.
            HStack(spacing: 8) {
                Text(kind.plural)
                    .font(.cortexTitle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Search + scope filter (Global / each project) + sort.
            LibraryFilterBar(
                query: $query,
                placeholder: "Search \(kind.plural.lowercased())",
                scope: $scope,
                scopes: scopes,
                sort: $sort
            )
        }
    }
}

// MARK: - ConfigSearchField
//
// A compact themed search field (magnifier glyph + text field + clear button) used
// inside the split list header, since the split pane has no toolbar `.searchable`.

private struct ConfigSearchField: View {
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

// MARK: - ConfigItemRow
//
// One PLAIN row in the native left list (no SelectableRow, no custom background):
// a leading kind glyph, a name over a one-line detail, a small favorite star when
// the item is favorited, and a trailing source-tool glyph. Chrome glyphs are outline
// + grayscale (no per-tool tint) per the minimal design pass.
// The enclosing List(selection:) draws the system selection highlight, so this view
// supplies only content.

private struct ConfigItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ConfigItem

    var body: some View {
        HStack(spacing: 10) {
            // Leading kind glyph (skill / agent / ...): outline + grayscale chrome.
            Image(systemName: outlineSymbol(item.kind.icon))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18)

            // Name over a single-line detail
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                // Prefer the on-device AI one-line summary when ready; otherwise the
                // raw description (the List truncates it to one line regardless).
                Text(model.summaries.summary(for: item) ?? item.detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Favorite indicator: an outline star shown only when favorited
            // (.primary marks the active/favorited state, grayscale chrome).
            if model.library.isFavorite(item.id) {
                Image(systemName: "star")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            // Trailing source-tool brand logo from thesvg (Claude / Cursor / ...),
            // SF Symbol fallback for tools thesvg has no icon for.
            BrandIcon(slug: BrandSlug.tool(item.source) ?? "",
                      fallbackSymbol: outlineSymbol(item.source.iconName),
                      size: 13, tint: Theme.textSecondary)
                .opacity(0.7)
        }
        .padding(.vertical, 6)
        // Yellow edit border: while THIS item is open in the markdown editor its row
        // gets a yellow rounded stroke (distinct from the blue system selection), so
        // it's obvious which item the editor is bound to.
        .padding(.horizontal, 4)
        .overlay {
            if model.editingItemID == item.id {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.yellow, lineWidth: 1.5)
            }
        }
    }
}

// MARK: - Outline symbol helper
//
// Strips a trailing ".fill" from an SF Symbol name so shared kind/source glyphs
// (defined elsewhere with filled variants) render as the outline chrome variant.
private func outlineSymbol(_ name: String) -> String {
    name.hasSuffix(".fill") ? String(name.dropLast(5)) : name
}

// MARK: - ConfigItemDetail
//
// The right-pane document viewer for the selected item, following the native
// detail pattern: a VStack(spacing: 0) of a top action toolbar (star toggle,
// an ellipsis library menu, and a markdown preview/source toggle), then the shared
// NativeDocumentDetail document column (a large native title + secondary subtitle +
// the rendered markdown OR raw source, with a native GroupBox of LabeledContent
// metadata rows). Re-identified by item id so the scroll + toggle reset on change.

private struct ConfigItemDetail: View {
    @Environment(AppModel.self) private var model
    let item: ConfigItem
    let tint: Color
    let requestNewCollection: (String) -> Void

    // Edit mode is tracked app-wide on the model (model.editingItemID) so the library
    // row can draw its yellow border while this item is open in the editor. Whether
    // THIS item is editing is therefore derived, not local; only the in-progress draft
    // and the save spinner stay local to the detail.
    @State private var draft = ""
    @State private var isSaving = false
    // Drives the native delete-confirmation alert (set by the Delete… menu item).
    @State private var confirmingDelete = false

    // Whether THIS item is the one currently open in the markdown editor.
    private var isEditing: Bool { model.editingItemID == item.id }

    // Save/Cancel is available the whole time the editor is open (so a freshly created
    // item shows it immediately), not only once something changed.
    private var showSaveBar: Bool { isEditing }

    // The subtitle: on-device AI summary when ready, else the raw description (nil hides it).
    private var subtitleText: String? {
        let text = model.summaries.summary(for: item) ?? item.detail
        return text.isEmpty ? nil : text
    }

    var body: some View {
        VStack(spacing: 0) {
            // Shared native document body: title + subtitle + markdown OR editor + metadata.
            NativeDocumentDetail(
                title: item.name,
                // The on-device AI summary when ready, else the raw description.
                subtitle: subtitleText,
                content: item.content,
                isEditing: isEditing,
                editText: $draft,
                metadata: metadata,
                // Action buttons live in the document top bar (top-right corner) in BOTH
                // modes; the eye/pencil toggle reflects whether we're editing.
                topTrailing: AnyView(
                    DetailActionBar(
                        item: item,
                        isEditing: isEditing,
                        showPreview: showPreview,
                        beginEdit: beginEdit,
                        requestNewCollection: requestNewCollection,
                        onMakeGlobal: ConfigFileOps.canMakeGlobal(item) ? makeGlobal : nil,
                        onDelete: delete
                    )
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
            // Floating Save / Cancel: only once there are unsaved changes, with a
            // spring slide-up + fade in/out.
            .overlay(alignment: .bottomTrailing) {
                if showSaveBar {
                    EditSaveCancelBar(isSaving: isSaving, onSave: save, onCancel: cancelEdit)
                        // Inset to sit inside the editor's rounded wrapper (the editor
                        // is padded 24 from the pane edge), not hanging off its corner.
                        .padding(.trailing, 38)
                        .padding(.bottom, 38)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: showSaveBar)

            // Pinned status footer (read-only view only).
            if !isEditing {
                DocumentFooter(item: item)
            }
        }
        .background(Theme.canvas)
        // Reset the scroll position + edit state when the selection changes.
        .id(item.id)
        // Auto-open the editor for a freshly created item: when this detail is the
        // recently-created one, seed the draft and enter edit mode. recentlyCreatedID is
        // NOT cleared here so the item keeps floating at the top of the list while it is
        // open; ConfigBrowser clears it once the user selects a different row.
        .task(id: item.id) {
            if item.id == model.recentlyCreatedID {
                if !isEditing { draft = item.content }
                model.editingItemID = item.id
            }
        }
        // Leaving this detail (selection changed) closes its edit session so a stale
        // yellow border / editor state never lingers on the previous item.
        .onDisappear {
            if model.editingItemID == item.id { model.editingItemID = nil }
        }
        // Native macOS warning before a destructive delete. Confirming moves the item to
        // the Trash and shows an Undo toast (see performDelete).
        .alert("Move \u{201C}\(item.name)\u{201D} to the Trash?", isPresented: $confirmingDelete) {
            Button("Move to Trash", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(item.kind == .skill
                 ? "The whole \(item.name) skill folder will be moved to the Trash."
                 : "This \(item.kind.singular.lowercased()) will be moved to the Trash.")
        }
    }

    // MARK: Edit actions

    private func beginEdit() {
        // Seed the draft only when entering edit (don't clobber in-progress edits if
        // the pencil is tapped again while already editing).
        if !isEditing { draft = item.content }
        model.editingItemID = item.id
    }

    // The eye button: leave edit mode and return to the rendered preview.
    private func showPreview() {
        model.editingItemID = nil
    }

    private func cancelEdit() {
        model.editingItemID = nil
    }

    private func save() {
        isSaving = true
        let content = draft
        Task {
            try? ConfigFileOps.save(item, content: content)
            await reload()
            isSaving = false
            model.editingItemID = nil
            model.showToast("Saved")
        }
    }

    private func makeGlobal() {
        Task {
            try? ConfigFileOps.makeGlobal(item)
            await reload()
            model.showToast("Copied to Global")
        }
    }

    // The Delete… menu item only ASKS; the native alert confirms before anything moves.
    private func delete() {
        confirmingDelete = true
    }

    // Actually move to the Trash (after confirmation) and offer Undo in a toast that
    // restores the item from the Trash to where it lived.
    private func performDelete() {
        let name = item.name
        Task {
            guard let result = try? ConfigFileOps.trash(item) else {
                model.showToast("Couldn't move \u{201C}\(name)\u{201D} to the Trash")
                return
            }
            await reload()
            model.showToast(
                "Moved \u{201C}\(name)\u{201D} to the Trash",
                action: .init(label: "Undo") {
                    Task { @MainActor in
                        do {
                            try ConfigFileOps.restore(from: result.trashed, to: result.original)
                            await model.config.load(roots: model.scanRoots)
                            model.recomputeStats()
                            model.showToast("Restored \u{201C}\(name)\u{201D}")
                        } catch {
                            model.showToast("Couldn't restore \u{201C}\(name)\u{201D} - find it in the Trash")
                        }
                    }
                }
            )
        }
    }

    /// Re-scan config after a file mutation so the list + detail reflect disk.
    private func reload() async {
        await model.config.load(roots: model.scanRoots)
        model.recomputeStats()
    }

    // Metadata rows for the GroupBox: source tool, scope, size, modified.
    private var metadata: [DocumentMetadataRow] {
        [
            DocumentMetadataRow(label: "Source", value: item.source.displayName),
            DocumentMetadataRow(label: "Scope", value: item.scopeLabel),
            DocumentMetadataRow(label: "Size", value: ConfigFmt.size(item.fileSize)),
            DocumentMetadataRow(label: "Modified", value: item.modified.formatted(date: .abbreviated, time: .shortened)),
        ]
    }
}

// MARK: - NativeDocumentDetail (shared)
//
// The shared, native document column reused by every library browser detail pane
// (Skills, Agents, Rules, Commands, Instructions, Plugins, Memory). It renders like
// a stock macOS document viewer: a large native title (.largeTitle.bold), an optional
// secondary subtitle (.secondary), then the document body - either the MarkdownText
// preview (system typography) or a monospaced, selectable raw source - followed by a
// native GroupBox of LabeledContent metadata rows (source / scope / size / modified).
// No custom pills or cards: only native containers and system text styles.

struct DocumentMetadataRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

struct NativeDocumentDetail: View {
    let title: String
    var subtitle: String? = nil
    let content: String
    var showSource: Bool = false
    // Editing: when true, the body is an editable markdown editor bound to `editText`
    // instead of the preview/source. Defaults off so non-editing callers are unaffected.
    var isEditing: Bool = false
    var editText: Binding<String> = .constant("")
    var metadata: [DocumentMetadataRow] = []
    // Optional trailing accessory (action buttons) pinned in the reader's top bar at
    // the top-right corner, beside an inline title that reveals on scroll. nil = none.
    var topTrailing: AnyView? = nil

    // Drives the inline-title reveal: true once the large title has scrolled away.
    @State private var scrolledPastTitle = false
    // Focuses the editor's text the moment edit mode opens (so a freshly created item
    // lands with the cursor already in the canvas).
    @FocusState private var editorFocused: Bool

    private var isEmpty: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Body: editor while editing, scrollable reader otherwise.
            Group {
                if isEditing {
                    editor
                } else {
                    scrollBody
                        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                            let past = y > 44
                            if past != scrolledPastTitle {
                                withAnimation(.easeOut(duration: 0.22)) { scrolledPastTitle = past }
                            }
                        }
                }
            }

            // Pinned top bar: the action buttons stay in the corner in BOTH modes; the
            // inline title only reveals on scroll in the reader.
            if let topTrailing {
                documentTopBar(accessory: topTrailing)
            }
        }
    }

    // MARK: Editor (full-height markdown editor)

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)

            TextEditor(text: editText)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .fill(Theme.hairFill))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Land the cursor in the editor as soon as it appears (deferred, since a
        // synchronous @FocusState in onAppear is dropped before the field is in the
        // responder chain).
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { editorFocused = true } }
    }

    // The pinned bar over the document. When the large title scrolls away (reader only),
    // the inline title fades + slides in and a material strip appears so it stays legible.
    private func documentTopBar(accessory: AnyView) -> some View {
        let revealed = !isEditing && scrolledPastTitle
        return HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 8)
            Spacer(minLength: 8)
            accessory
        }
        .padding(.leading, 24)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .background {
            if revealed { Rectangle().fill(.bar).ignoresSafeArea() }
        }
        .overlay(alignment: .bottom) {
            if revealed { Divider().overlay(Theme.stroke) }
        }
    }

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Document header: large native title + optional secondary subtitle
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                // Body: empty note, raw monospaced source, or rendered markdown preview
                if isEmpty {
                    Text("This file is empty.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                } else if showSource {
                    // Raw markdown source: monospaced + selectable.
                    Text(content)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } else {
                    // Rendered markdown preview (already system typography).
                    MarkdownText(markdown: content)
                        .padding(.top, 4)
                }

                // Native metadata: a GroupBox of LabeledContent key/value rows.
                if !metadata.isEmpty {
                    GroupBox {
                        VStack(spacing: 8) {
                            ForEach(metadata) { row in
                                LabeledContent(row.label) {
                                    Text(row.value)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                if row.id != metadata.last?.id {
                                    Divider()
                                }
                            }
                        }
                    } label: {
                        Label("Details", systemImage: "info.circle")
                            .font(.headline)
                    }
                    .padding(.top, 4)
                }
            }
            // Tighter top so the document title rides up level with the floating action
            // controls instead of leaving an empty band above it.
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - DetailActionBar
//
// The detail pane's top-right action row: the favorite StarButton, an ellipsis Menu
// hosting the same LibraryItemMenu actions as the row context menu, and a two-button
// markdown preview/source toggle (outline eye = rendered, code glyph = raw). The toggle is
// shared with the body via the @Binding so the body re-renders accordingly.

private struct DetailActionBar: View {
    let item: ConfigItem
    var isEditing: Bool
    var showPreview: () -> Void
    var beginEdit: () -> Void
    let requestNewCollection: (String) -> Void
    var onMakeGlobal: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        // Two equally-sized glass pills grouped in a GlassEffectContainer so they
        // render together and blend as they near each other. No opaque band: the
        // toolbar floats over the document.
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 10) {
                // Left pill: preview / edit (eye + pencil), active mode reflects state
                DocumentModeToggle(isEditing: isEditing, showPreview: showPreview, beginEdit: beginEdit)

                // Right pill: favorite + ellipsis menu (same button size as the left pill)
                HStack(spacing: 2) {
                    StarButton(item: item)

                    Menu {
                        LibraryItemMenu(
                            item: item,
                            requestNewCollection: requestNewCollection,
                            onMakeGlobal: onMakeGlobal,
                            onDelete: onDelete
                        )
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

// MARK: - ConfigFmt
//
// Shared formatting helpers for ConfigItem detail metadata bars (file size + home-
// abbreviated path). Used by both Skills and Favorites detail panes so the metadata
// rows render identically. ByteCountFormatter handles the locale-aware size string.

enum ConfigFmt {
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

// MARK: - New library item ("+" menu)
//
// Creates a starter skill / agent / rule / command under ~/.claude from a small
// template, then returns the new file's URL. Never overwrites: a colliding name gets
// a "-2", "-3", ... suffix. The caller rescans + reveals the file in Finder.

enum NewConfigItem {
    /// Kinds the "+" menu can create (each has a clear ~/.claude home).
    static let creatable: [ConfigKind] = [.skill, .agent, .rule, .command]

    /// Create the starter file from a display name under the Claude Code config dir
    /// (~/.claude), returning its URL (nil on failure). Skills / agents / rules /
    /// commands are a Claude Code concept and only Claude's layout round-trips through
    /// the scanner, so creation always targets ~/.claude. The display name is sanitized
    /// into a filesystem-safe slug for the directory/file name, but the ORIGINAL display
    /// name is written into the generated frontmatter `name:`. Colliding names still get
    /// a "-2", "-3", ... suffix.
    static func create(_ kind: ConfigKind, name: String) -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let base = slug(name)
        let display = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .skill:
            guard let dir = uniqueDirectory(in: root.appendingPathComponent("skills"), base: base) else { return nil }
            return write(template(kind, name: display), to: dir.appendingPathComponent("SKILL.md"))
        case .agent:
            guard let file = uniqueFile(in: root.appendingPathComponent("agents"), base: base) else { return nil }
            return write(template(kind, name: display), to: file)
        case .command:
            guard let file = uniqueFile(in: root.appendingPathComponent("commands"), base: base) else { return nil }
            return write(template(kind, name: display), to: file)
        case .rule:
            guard let file = uniqueFile(in: root.appendingPathComponent("rules"), base: base) else { return nil }
            return write(template(kind, name: display), to: file)
        default:
            return nil
        }
    }


    /// A filesystem-safe slug from a display name: lowercase, runs of invalid
    /// characters collapsed to a single "-", trimmed of leading/trailing "-".
    /// Falls back to "new-item" when the name has no usable characters.
    private static func slug(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        var out = ""
        var lastWasDash = false
        for scalar in name.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "new-item" : trimmed
    }

    /// The library route that lists the given kind (where to navigate after creating).
    static func route(for kind: ConfigKind) -> Route {
        switch kind {
        case .agent: return .agents
        case .rule: return .rules
        case .command: return .commands
        default: return .skills
        }
    }

    // MARK: Helpers

    /// A non-colliding `<dir>/<base>[-N]` directory, created on disk.
    private static func uniqueDirectory(in parent: URL, base: String) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let dir = parent.appendingPathComponent(uniqueName(in: parent, base: base, ext: nil))
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        return dir
    }

    /// A non-colliding `<dir>/<base>[-N].md` file path (parent created).
    private static func uniqueFile(in parent: URL, base: String) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent.appendingPathComponent(uniqueName(in: parent, base: base, ext: "md"))
    }

    /// First of `base`, `base-2`, `base-3`, ... that does not already exist.
    private static func uniqueName(in parent: URL, base: String, ext: String?) -> String {
        let fm = FileManager.default
        func name(_ n: Int) -> String {
            let stem = n == 1 ? base : "\(base)-\(n)"
            return ext.map { "\(stem).\($0)" } ?? stem
        }
        var n = 1
        while fm.fileExists(atPath: parent.appendingPathComponent(name(n)).path) { n += 1 }
        return name(n)
    }

    /// Write `text` to `file`, returning the URL on success.
    private static func write(_ text: String, to file: URL) -> URL? {
        do { try text.write(to: file, atomically: true, encoding: .utf8); return file }
        catch { return nil }
    }

    /// Starter content (frontmatter + a heading) for each kind.
    private static func template(_ kind: ConfigKind, name: String) -> String {
        switch kind {
        case .skill:
            return """
            ---
            name: \(name)
            description: A new skill. Describe what it does and when Claude should use it.
            ---

            # \(name)

            Describe the skill here.
            """
        case .agent:
            return """
            ---
            name: \(name)
            description: A new agent.
            ---

            You are \(name). Describe this agent's role, scope, and behavior here.
            """
        case .command:
            return """
            ---
            description: A new command.
            ---

            Describe what this command does. Use $ARGUMENTS to reference the input.
            """
        default: // .rule
            return """
            # \(name)

            Describe the rule here.
            """
        }
    }
}

// MARK: - NewItemMenu ("+" toolbar button)
//
// The window-chrome "+" (placed by ContentView in the detail toolbar, beside the
// sidebar toggle): a menu of New Skill / New Agent / New Rule / New Command. Selecting one opens the
// NewItemSheet modal (name + tool), which on Create writes the file, navigates to
// that library page, rescans, floats the item to the top, and opens it in the editor.
// "New Collection" stays an immediate action since a collection is not a file.

struct NewItemMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(NewConfigItem.creatable) { kind in
                Button {
                    // Open the creation modal for this kind (see NewItemSheet).
                    model.newItemKind = kind
                } label: {
                    Label("New \(kind.singular)", systemImage: kind.icon)
                }
            }
            Divider()
            // Collections are a library construct (not a file), so create + navigate.
            Button {
                _ = model.library.createCollection(name: "New Collection")
                model.route = .collections
            } label: {
                Label("New Collection", systemImage: "rectangle.stack.badge.plus")
            }
        } label: {
            // Explicit weight + primary tint so the glyph keeps full contrast in light
            // mode (the default toolbar Menu rendered it as a faint, washed-out plus).
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .menuIndicator(.hidden)
        .help("Create a new skill, agent, rule, command, or collection")
    }
}

// MARK: - NewItemSheet (creation modal)
//
// A centered dark card presented when NewItemMenu picks a kind: a "<Kind> name"
// field (auto-focused) over a "Tool" picker (defaults to Claude Code, each option
// showing its brand logo), with Cancel / Create in the footer. Create is disabled
// until the name has content; pressing it hands off to AppModel.createConfigItem,
// which writes the file, routes to the page, floats the item, and opens the editor.
// The card chrome mirrors CommandPaletteView.palettePanel (cardRaised + 16pt radius
// + strokeStrong hairline + shadow).

struct NewItemSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let kind: ConfigKind

    // Shared control height so the name field and the tool pop-up button line up.
    static let fieldHeight: CGFloat = 34

    // Entered name. Focus the name field on appear so the user can type immediately
    // (deferred, since a synchronous @FocusState in onAppear is dropped).
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCreate: Bool { !trimmedName.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Title.
            Text("New \(kind.singular)")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            // Name row: label left, auto-focused field right.
            HStack(spacing: 14) {
                Text("\(kind.singular) name")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 96, alignment: .leading)
                TextField("Untitled", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($nameFocused)
                    .onSubmit { if canCreate { create() } }
                    .padding(.horizontal, 10)
                    .frame(height: NewItemSheet.fieldHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                            .fill(Theme.cardRaised)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                            .strokeBorder(Theme.strokeStrong, lineWidth: 1)
                    )
            }

            // Warm note: creation targets the user's Claude Code config. Skills / agents
            // / rules / commands are a Claude Code concept (only that layout round-trips
            // through the scanner), so we always save to ~/.claude - no tool picker.
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.claude)
                Text("Saved to your Claude Code config (~/.claude). Skills, agents, rules, and commands are a Claude Code feature.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .fill(Theme.claude.opacity(0.10))
            )

            // Footer: Cancel (left) and Create (right, accent + disabled while empty).
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .linkCursor()
                Spacer()
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
                    .linkCursor()
            }
        }
        // One clean card: the sheet itself is the panel, so we don't draw a second
        // card inside it (that nested-card look is what read as "multiple modal").
        .padding(24)
        .frame(width: 420)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { nameFocused = true }
        }
    }

    // Hand off to AppModel (which writes the file, routes, rescans, floats + edits),
    // then close the modal.
    private func create() {
        guard canCreate else { return }
        let kind = kind
        let name = trimmedName
        dismiss()
        Task { await model.createConfigItem(kind: kind, name: name) }
    }
}

