import SwiftUI
import AppKit

// MARK: - FavoritesView
//
// A native SplitDetailView browser over the user's favorited library items
// (skills + agents + commands + rules together), mirroring the native library layout:
// the LEFT pane is a header ("Favorites" title + live count + search) above a NATIVE
// List(selection:) of plain rows (kind glyph, name over detail, trailing source glyph,
// plus a yellow star.fill marking the favorite); the RIGHT pane is the selected item's
// document detail (title + a preview/source toggle over the markdown body + a pinned
// DetailMetadataBar). Rows and the detail both expose the shared item context menu
// (Unfavorite, Collections submenu with a "New Collection..." alert, Show in Finder).
// When nothing is favorited the whole view becomes an empty state explaining how to
// favorite items. Self-contained: it owns its own row / detail / menu helpers so it
// does not depend on ConfigBrowser's private subviews.

struct FavoritesView: View {
    @Environment(AppModel.self) private var model

    // Live search query bound to the list-header search field
    @State private var query = ""
    // Active kind filter (nil == "All"), driven by the scroll-chip row under search.
    @State private var kindFilter: ConfigKind?
    // The id of the row whose detail is shown in the right pane (nil == none)
    @State private var selectedID: ConfigItem.ID?
    // New-collection alert state, shared by row + detail menus. `pendingItemID`
    // remembers which item should join the freshly created collection.
    @State private var showNewCollection = false
    @State private var newCollectionName = ""
    @State private var pendingItemID: String?

    // All favorited items across every kind, sorted by name. MCP servers, memory
    // files, and hooks aren't ConfigItems, so favorited ones are synthesized into
    // ConfigItems here (the row + detail are ConfigItem-typed and render them unchanged).
    private var favorites: [ConfigItem] {
        var out = model.config.items.filter { model.library.isFavorite($0.id) }

        out += model.config.mcpServers
            .filter { model.library.isFavorite($0.id) }
            .map { server in
                ConfigItem(
                    id: server.id, name: server.name,
                    detail: "MCP · \(server.transport.uppercased()) · \(server.scope)",
                    path: server.command ?? server.url ?? "",
                    kind: .mcp, source: .claude, isGlobal: server.scope == "user",
                    projectName: server.scope == "user" ? nil : server.scope,
                    fileSize: 0, modified: Date(),
                    content: "**Transport:** \(server.transport)\n\n**Scope:** \(server.scope)\n\n`\(server.command ?? server.url ?? "unknown")`",
                    frontmatter: [:]
                )
            }

        out += model.config.memories
            .filter { model.library.isFavorite($0.id) }
            .map { mem in
                ConfigItem(
                    id: mem.id, name: mem.name, detail: mem.hook, path: mem.path,
                    kind: .memory, source: .claude, isGlobal: mem.scope == "Global",
                    projectName: mem.scope == "Global" ? nil : mem.scope,
                    fileSize: mem.sizeBytes, modified: mem.modified,
                    content: mem.hook, frontmatter: [:]
                )
            }

        out += model.config.hooks
            .filter { model.library.isFavorite($0.id) }
            .map { hook in
                let matcher = (hook.matcher?.isEmpty == false) ? "\(hook.matcher!) · " : ""
                let settingsPath = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/\(hook.source)").path
                return ConfigItem(
                    id: hook.id, name: hook.event, detail: "\(matcher)\(hook.source)",
                    path: settingsPath, kind: .hook, source: .claude, isGlobal: true,
                    projectName: nil, fileSize: 0, modified: Date(),
                    content: "`\(hook.command)`\n\nSource: \(hook.source)", frontmatter: [:]
                )
            }

        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // The kinds actually present among the favorites, in ConfigKind's canonical order,
    // so the chip row only offers filters that match something (no dead "Plugins" chip
    // when nothing is a plugin). Derived from the unfiltered favorites.
    private var presentKinds: [ConfigKind] {
        let present = Set(favorites.map(\.kind))
        return ConfigKind.allCases.filter { present.contains($0) }
    }

    // Favorites narrowed by the active kind chip AND the live query (matches name +
    // detail). The two filters compose: a chip selection plus a query intersect.
    private var filtered: [ConfigItem] {
        var out = favorites
        if let kindFilter {
            out = out.filter { $0.kind == kindFilter }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return out }
        return out.filter { item in
            item.name.localizedCaseInsensitiveContains(trimmed)
                || item.detail.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        // The split browser stays mounted even with zero favorites; the whole-view
        // empty state sits ON TOP as an opaque overlay. Swapping the split out (which
        // unmounts its native List/scroll views and toolbar) triggered an AppKit
        // re-layout that stranded the SIDEBAR's scroll offset up over the traffic
        // lights - with an overlay, nothing is ever torn down.
        splitBrowser
            .overlay {
                if favorites.isEmpty {
                    FavoritesEmptyState()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
            // ONE page chrome for both states, applied outside the overlay.
            .cortexScrollEdge()
            .cortexPageChrome("Favorites", subtitle: "Everything you've starred", count: filtered.count)
        // Native new-collection alert with a TextField + create button. Triggered from
        // either the row context menu or the detail toolbar menu; on create the pending
        // item (if any) is added to the new collection.
        .alert("New Collection", isPresented: $showNewCollection) {
            TextField("Collection name", text: $newCollectionName)
            Button("Cancel", role: .cancel) { resetNewCollection() }
            Button("Create") { commitNewCollection() }
        } message: {
            Text("Create a collection to organize your favorited items.")
        }
    }

    // MARK: Split browser

    private var splitBrowser: some View {
        // No title here: the page chrome lives at the body level (outside the
        // empty-state swap), so this split renders only its core layout.
        SplitDetailView(
            items: filtered,
            selectedID: $selectedID,
            // No skeleton while the whole-pane empty state covers this split: the
            // skeleton respects the top safe area but the real list extends under the
            // band, so the 0.3s skeleton flip resized the pane and visibly slid the
            // centered empty state down. With zero favorites the real layout is
            // trivially cheap, so it builds immediately and the size never changes.
            showSkeleton: !favorites.isEmpty,
            emptyIcon: "star",
            emptyTitle: "No item selected",
            emptyMessage: "Select a favorite on the left to see its contents."
        ) {
            // Left-pane header: title + live count + search field + kind chip row
            FavoritesListHeader(
                count: filtered.count,
                query: $query,
                kindFilter: $kindFilter,
                kinds: presentKinds
            )
        } row: { item, _ in
            // Plain row content: the native List draws the selection highlight, so this
            // must not add its own background. A trailing star.fill marks the favorite.
            FavoriteItemRow(item: item)
                .contextMenu { itemMenu(for: item) }
        } detail: { item in
            // Document detail with a preview/source toggle + a toolbar star/menu.
            FavoriteItemDetail(
                item: item,
                onNewCollection: { beginNewCollection(for: item.id) }
            )
        }
        // Unfavoriting or filtering out the current selection is reconciled by
        // SplitDetailView itself: it moves the selection to the neighboring row
        // (next item, or the new last row), so no fallback handlers are needed here.
    }

    // MARK: Shared item context menu
    //
    // The native menu shared by the row .contextMenu and (in a slightly different host)
    // the detail toolbar Menu: a Favorite/Unfavorite toggle, a Collections submenu
    // (one membership toggle per collection + a "New Collection..." action), and
    // "Show in Finder".

    @ViewBuilder
    private func itemMenu(for item: ConfigItem) -> some View {
        ItemActionsMenu(
            item: item,
            onNewCollection: { beginNewCollection(for: item.id) }
        )
    }

    // MARK: New-collection flow

    private func beginNewCollection(for itemID: String?) {
        pendingItemID = itemID
        newCollectionName = ""
        showNewCollection = true
    }

    private func commitNewCollection() {
        let created = model.library.createCollection(name: newCollectionName)
        if let id = pendingItemID {
            model.toggleMember(id, in: created.id)
        }
        resetNewCollection()
    }

    private func resetNewCollection() {
        newCollectionName = ""
        pendingItemID = nil
    }
}

// MARK: - FavoritesEmptyState
//
// Shown when the user has not favorited anything yet: a star glyph and a short
// explanation of how to add favorites (right-click any item, or tap its star).

private struct FavoritesEmptyState: View {
    var body: some View {
        CortexEmptyState(
            icon: "star",
            title: "No favorites yet",
            message: "Tap the star on a skill, agent, command, rule, MCP server, or memory file (or right-click and choose Favorite) to pin it here."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

// MARK: - FavoritesListHeader
//
// The left pane's sticky header: a star glyph + "Favorites" title + a live count pill,
// above a self-contained search field that filters the list by name/detail, and below
// that a horizontal scroll-chip row that filters the list by kind (All + one chip per
// kind actually present among the favorites).

private struct FavoritesListHeader: View {
    let count: Int
    @Binding var query: String
    @Binding var kindFilter: ConfigKind?
    let kinds: [ConfigKind]

    var body: some View {
        // Title + count now live in the toolbar band (`.cortexPageChrome`); the left pane
        // keeps the search field + kind chip row.
        VStack(alignment: .leading, spacing: 12) {
            // Inline search field filtering by name/detail
            FavoritesSearchField(query: $query, placeholder: "Search favorites")

            // Kind filter chip row (only when there's more than one kind to pick from,
            // otherwise a single "All" chip is just noise).
            if kinds.count > 1 {
                FavoritesKindChips(kindFilter: $kindFilter, kinds: kinds)
            }
        }
    }
}

// MARK: - FavoritesKindChips
//
// A horizontal, scrollable row of small capsule chips that filters the favorites list
// by kind: an "All" chip (clears the filter) followed by one chip per kind present
// among the favorites. The selected chip carries an accent-tinted fill; the rest sit on
// the faint hairline fill. Tapping a chip toggles its kind (tapping the active one
// reverts to "All"). Self-contained here (not the library scope popover): chips, by kind.

private struct FavoritesKindChips: View {
    @Binding var kindFilter: ConfigKind?
    let kinds: [ConfigKind]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // "All" clears the kind filter.
                chip(label: "All", icon: nil, selected: kindFilter == nil) {
                    kindFilter = nil
                }
                // One chip per present kind, toggling that kind on/off.
                ForEach(kinds) { kind in
                    chip(label: kind.plural, icon: kind.icon, selected: kindFilter == kind) {
                        kindFilter = (kindFilter == kind) ? nil : kind
                    }
                }
            }
            // Inset so the selected chip's fill isn't clipped at the scroll edges.
            .padding(.horizontal, 1)
            .padding(.vertical, 1)
        }
    }

    // One capsule chip: optional kind glyph + label, accent-tinted when selected.
    private func chip(
        label: String,
        icon: String?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(selected ? .white : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(selected ? Theme.accent : Theme.hairFill)
            )
            .overlay(
                Capsule().strokeBorder(selected ? .clear : Theme.stroke, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .linkCursor()
    }
}

// MARK: - FavoritesSearchField
//
// A compact themed search field (magnifier glyph + text field + clear button) used
// inside the split list header, since the split pane has no toolbar `.searchable`.
// Self-contained copy of the ConfigBrowser field so Favorites has no private deps.

private struct FavoritesSearchField: View {
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

// MARK: - FavoriteItemRow
//
// One PLAIN row in the native left list (no custom background): a leading kind glyph,
// the name over a one-line detail, a trailing source-tool glyph tinted to its origin
// tool, and a small yellow star.fill marking it as a favorite. The enclosing
// List(selection:) draws the system selection highlight, so this supplies only content.

private struct FavoriteItemRow: View {
    let item: ConfigItem

    var body: some View {
        HStack(spacing: 10) {
            // Leading kind glyph (skill / agent / command / rule)
            Image(systemName: item.kind.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18)

            // Name over a single-line detail
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Favorite marker (always favorited in this list)
            Image(systemName: "star.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            // Trailing source-tool glyph (Claude Code, Codex, ...)
            Image(systemName: item.source.iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(0.7)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - ItemActionsMenu
//
// The shared library actions for a ConfigItem, used both inside a row `.contextMenu`
// and inside the detail toolbar `Menu`. NATIVE controls only: a Favorite/Unfavorite
// Button, a Collections `Menu` whose entries are Buttons that toggle membership (with
// a checkmark glyph when the item is a member), a Divider, a "New Collection..." Button
// that asks the host to raise the new-collection alert, and a "Show in Finder" Button.

private struct ItemActionsMenu: View {
    @Environment(AppModel.self) private var model
    let item: ConfigItem
    var onNewCollection: () -> Void

    var body: some View {
        // Favorite / Unfavorite toggle
        Button {
            model.toggleFavorite(item.id)
        } label: {
            let on = model.library.isFavorite(item.id)
            Label(on ? "Unfavorite" : "Favorite", systemImage: on ? "star.slash" : "star")
        }

        // Collections submenu: one membership toggle per collection + new collection
        Menu {
            ForEach(model.library.collections) { collection in
                Button {
                    model.toggleMember(item.id, in: collection.id)
                } label: {
                    if model.library.isMember(item.id, of: collection.id) {
                        Label(collection.name, systemImage: "checkmark")
                    } else {
                        Label(collection.name, systemImage: collection.icon)
                    }
                }
            }
            Divider()
            Button {
                onNewCollection()
            } label: {
                Label("New Collection...", systemImage: "plus")
            }
        } label: {
            Label("Collections", systemImage: "rectangle.stack")
        }

        Divider()

        // Reveal the backing file in Finder
        Button {
            NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
    }
}

// MARK: - FavoriteItemDetail
//
// The right-pane document viewer for the selected favorite, following the native
// detail pattern: a VStack(spacing: 0) whose top is a header row (title + a small
// preview/source toggle + a star button + a Menu of item actions), then either the
// rendered markdown body (preview) or the raw source in a monospaced selectable
// ScrollView (source), and whose bottom is a pinned DetailMetadataBar (source, path,
// size, modified). Re-identified by item id so the scroll + toggle reset on selection.

private struct FavoriteItemDetail: View {
    @Environment(AppModel.self) private var model
    let item: ConfigItem
    var onNewCollection: () -> Void

    // Preview (rendered markdown) vs source (raw text) mode for the body.
    @State private var showSource = false

    // Bottom metadata bar leading items: source, abbreviated path, formatted size.
    private var metadata: [DetailMetadataBar.Item] {
        [
            DetailMetadataBar.Item(
                icon: item.source.iconName,
                text: item.source.displayName,
                tint: Theme.textSecondary
            ),
            DetailMetadataBar.Item(
                icon: "doc",
                text: ConfigFmt.abbreviatePath(item.path)
            ),
            DetailMetadataBar.Item(
                icon: nil,
                text: ConfigFmt.size(item.fileSize)
            ),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Detail toolbar: title + preview/source toggle + star + actions menu
            detailToolbar
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 14)

            // Scrolling document body: preview markdown or raw source
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // Secondary line (the item's detail / description)
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                    }

                    // Body: empty note, rendered markdown (preview), or raw source.
                    if item.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("This file is empty.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 8)
                    } else if showSource {
                        Text(item.content)
                            .font(.cortexMono)
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    } else {
                        MarkdownText(markdown: item.content)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Pinned full-width bottom metadata bar
            DetailMetadataBar(
                leading: metadata,
                trailing: Fmt.relative(item.modified)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        // Reset scroll + view mode when the selection changes.
        .id(item.id)
    }

    // MARK: Detail toolbar

    private var detailToolbar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // Document title (item name)
            Text(item.name)
                .font(.cortexTitle)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            // Preview / source segmented toggle (eye vs code glyphs)
            PreviewSourceToggle(showSource: $showSource)

            // Star toggle for the current item: filled while favorited.
            Button {
                model.toggleFavorite(item.id)
            } label: {
                let on = model.library.isFavorite(item.id)
                Image(systemName: on ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .linkCursor()
            .help("Favorite")

            // Overflow menu mirroring the row context menu
            Menu {
                ItemActionsMenu(item: item, onNewCollection: onNewCollection)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

// MARK: - PreviewSourceToggle
//
// A two-button segmented toggle for the detail body: an "eye" button selects the
// rendered markdown preview, a "chevron.left.forwardslash.chevron.right" button selects
// the raw source. The active button is filled with the raised card color so it reads as
// selected, mirroring the preview/source switch. NATIVE buttons only.

private struct PreviewSourceToggle: View {
    @Binding var showSource: Bool

    var body: some View {
        HStack(spacing: 2) {
            // Preview (rendered markdown)
            toggleButton(icon: "eye", active: !showSource, help: "Preview") {
                showSource = false
            }
            // Source (raw text)
            toggleButton(
                icon: "chevron.left.forwardslash.chevron.right",
                active: showSource,
                help: "Source"
            ) {
                showSource = true
            }
        }
        .padding(3)
        .background(Theme.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func toggleButton(
        icon: String,
        active: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Theme.cardRaised : .clear)
                )
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help(help)
    }
}
