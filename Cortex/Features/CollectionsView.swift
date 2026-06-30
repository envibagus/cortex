import SwiftUI
import AppKit

// MARK: - CollectionsView
//
// Native manage-and-browse surface for the user's library Collections (the
// "Collections" tab). The LEFT pane is a native selectable List of
// model.library.collections (icon + name + member-count badge) under a header with a
// "+" button that opens a native .alert for creating a collection; each row carries a
// .contextMenu to Rename (alert + TextField) or Delete. The RIGHT pane shows the
// selected collection's members (resolved from model.config.items) as a second native
// master/detail: a member list with the shared row style + star + item .contextMenu,
// and a document detail with a markdown preview/source toggle and a pinned
// DetailMetadataBar. Everything uses native SwiftUI controls and Theme tokens only.

struct CollectionsView: View {
    @Environment(AppModel.self) private var model

    // The selected collection in the left list (nil == none).
    @State private var selectedCollectionID: LibraryStore.Collection.ID?

    // New-collection alert state (native .alert with a TextField).
    @State private var showNewCollection = false
    @State private var newCollectionName = ""

    var body: some View {
        SplitDetailView(
            items: model.library.collections,
            selectedID: $selectedCollectionID,
            emptyIcon: "rectangle.stack",
            emptyTitle: "No collection selected",
            emptyMessage: "Select a collection on the left to browse its items."
        ) {
            // Left-pane header: title + live count + a native "+" add button.
            CollectionsListHeader(
                count: model.library.collections.count,
                onAdd: beginNewCollection
            )
        } row: { collection, _ in
            // Plain row content; the native List(selection:) draws the highlight.
            CollectionsListRow(collection: collection)
        } detail: { collection in
            // Right pane: the selected collection's members, browsable.
            CollectionDetailPane(collection: collection)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        // Full-pane empty state when there are no collections at all.
        .overlay {
            if model.library.collections.isEmpty {
                CollectionsEmptyPane(onCreate: beginNewCollection)
            }
        }
        // Native new-collection alert: a single TextField + Create / Cancel.
        .alert("New Collection", isPresented: $showNewCollection) {
            TextField("Collection name", text: $newCollectionName)
            Button("Create", action: commitNewCollection)
            Button("Cancel", role: .cancel) { newCollectionName = "" }
        } message: {
            Text("Group skills, agents, commands, and rules together.")
        }
        // A "New Collection..." item nested in a member's Collections menu posts this
        // to open the same native create alert from here.
        .onReceive(NotificationCenter.default.publisher(for: .cortexNewCollectionRequested)) { _ in
            beginNewCollection()
        }
    }

    // MARK: New-collection actions

    private func beginNewCollection() {
        newCollectionName = ""
        showNewCollection = true
    }

    private func commitNewCollection() {
        let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { newCollectionName = ""; return }
        let created = model.library.createCollection(name: name)
        newCollectionName = ""
        // Jump to the freshly created collection.
        selectedCollectionID = created.id
    }
}

// MARK: - CollectionsListHeader
//
// The left pane's sticky header: a stack glyph + "Collections" title + a live count
// pill, and a trailing native "+" button that opens the new-collection alert.

private struct CollectionsListHeader: View {
    let count: Int
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Standard big title, no leading glyph.
            Text("Collections")
                .font(.cortexTitle)
                .foregroundStyle(.primary)
            Text("\(count)")
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)

            // Native add button -> new-collection alert
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 24, height: 24)
                    .background(Theme.hairFill, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            }
            .buttonStyle(.plain)
            .linkCursor()
            .help("New collection")
        }
    }
}

// MARK: - CollectionsListRow
//
// One PLAIN row in the native left list: the collection's icon, its name, and a
// trailing member-count badge. A .contextMenu offers Rename (native alert + TextField)
// and Delete. The enclosing List(selection:) supplies the selection highlight.

private struct CollectionsListRow: View {
    @Environment(AppModel.self) private var model
    let collection: LibraryStore.Collection

    // Rename alert state, scoped to this row.
    @State private var showRename = false
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 10) {
            // Leading collection glyph
            Image(systemName: collection.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(collection.name)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            // Trailing member-count badge
            Pill(text: "\(model.library.memberCount(collection.id))",
                 tint: Theme.textSecondary, filled: false)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // Right-click: rename / delete
        .contextMenu {
            Button {
                renameText = collection.name
                showRename = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                model.library.deleteCollection(collection.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        // Native rename alert
        .alert("Rename Collection", isPresented: $showRename) {
            TextField("Collection name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                model.library.renameCollection(collection.id, to: name)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - CollectionDetailPane
//
// The right pane for a selected collection: a nested master/detail. The top is a
// header (collection icon + name + member count). Below it, the resolved member items
// are shown in a native List on the left and the selected member's document detail on
// the right. When the collection has no members yet, a friendly empty state is shown
// with guidance to add items via their context menu.

private struct CollectionDetailPane: View {
    @Environment(AppModel.self) private var model
    let collection: LibraryStore.Collection

    // The selected member item inside this collection (nil == none).
    @State private var selectedMemberID: ConfigItem.ID?

    // Resolve member ConfigItems from the global item set, preserving the collection's
    // stored order. Re-read live so membership changes update immediately.
    private var members: [ConfigItem] {
        let all = Dictionary(uniqueKeysWithValues: model.config.items.map { ($0.id, $0) })
        return collection.memberIDs.compactMap { all[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Collection header
            CollectionDetailHeader(collection: collection, memberCount: members.count)

            Divider().overlay(Theme.stroke)

            if members.isEmpty {
                // Empty-collection state
                CortexEmptyState(
                    icon: "tray",
                    title: "No items yet",
                    message: "Add skills, agents, commands, or rules to \"\(collection.name)\" from their context menu (right-click an item, then Collections)."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Nested member master/detail
                HStack(spacing: 0) {
                    // Member list
                    List(selection: $selectedMemberID) {
                        ForEach(members) { item in
                            CollectionMemberRow(item: item, collectionID: collection.id)
                                .tag(item.id)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .frame(width: 300)
                    .background(Theme.canvas)

                    Divider().overlay(Theme.stroke)

                    // Member detail (markdown + preview/source toggle + metadata bar)
                    Group {
                        if let item = members.first(where: { $0.id == selectedMemberID }) {
                            CollectionMemberDetail(item: item, collectionID: collection.id)
                        } else {
                            CortexEmptyState(
                                icon: "doc.text",
                                title: "No item selected",
                                message: "Select an item to preview its content."
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.canvas)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        // Reset member selection when the collection changes; auto-select first member.
        .id(collection.id)
        .onAppear { selectFirstMemberIfNeeded() }
        .onChange(of: collection.memberIDs) { _, _ in
            if let id = selectedMemberID, !members.contains(where: { $0.id == id }) {
                selectedMemberID = members.first?.id
            } else {
                selectFirstMemberIfNeeded()
            }
        }
    }

    private func selectFirstMemberIfNeeded() {
        guard selectedMemberID == nil, let first = members.first?.id else { return }
        selectedMemberID = first
    }
}

// MARK: - CollectionDetailHeader
//
// The collection's identity strip above its member list: a tinted glyph badge, the
// collection name, and a member-count subtitle.

private struct CollectionDetailHeader: View {
    let collection: LibraryStore.Collection
    let memberCount: Int

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.hairFill)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: collection.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name)
                    .font(.cortexHeadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(memberCount == 1 ? "1 item" : "\(memberCount) items")
                    .font(.cortexCaption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - CollectionMemberRow
//
// One PLAIN row for a collection member: a leading kind glyph, name over a one-line
// detail, a small favorite star.fill (when starred), and a trailing source-tool glyph.
// A .contextMenu offers the shared item actions (favorite, collection membership,
// remove from this collection, show in Finder).

private struct CollectionMemberRow: View {
    @Environment(AppModel.self) private var model
    let item: ConfigItem
    let collectionID: String

    var body: some View {
        HStack(spacing: 10) {
            // Leading kind glyph
            Image(systemName: item.kind.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18)

            // Name over single-line detail
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

            // Favorited marker
            if model.library.isFavorite(item.id) {
                Image(systemName: "star")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            // Trailing source-tool glyph
            Image(systemName: item.source.iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(0.7)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            ItemLibraryMenu(item: item, currentCollectionID: collectionID)
        }
    }
}

// MARK: - CollectionMemberDetail
//
// The document viewer for a selected member, mirroring the native detail: a
// compact toolbar (favorite/unfavorite star, a preview/source segmented toggle, and a
// Menu duplicating the item context actions) over a scrolling body that shows either
// the rendered MarkdownText (preview) or the raw monospaced source (source), with a
// pinned DetailMetadataBar at the bottom.

private struct CollectionMemberDetail: View {
    @Environment(AppModel.self) private var model
    let item: ConfigItem
    let collectionID: String

    // Preview (rendered markdown) vs. source (raw monospaced) toggle.
    @State private var showSource = false

    private var metadata: [DetailMetadataBar.Item] {
        [
            DetailMetadataBar.Item(
                icon: item.source.iconName,
                text: item.source.displayName,
                tint: Theme.textSecondary
            ),
            DetailMetadataBar.Item(icon: "doc", text: CollectionsFmt.abbreviatePath(item.path)),
            DetailMetadataBar.Item(icon: nil, text: CollectionsFmt.size(item.fileSize)),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Detail toolbar: star, preview/source toggle, actions menu
            CollectionMemberToolbar(
                item: item,
                collectionID: collectionID,
                showSource: $showSource
            )

            Divider().overlay(Theme.stroke)

            // Scrolling body: preview (markdown) or source (raw)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name)
                        .font(.cortexTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)

                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                    }

                    if item.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("This file is empty.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 8)
                    } else if showSource {
                        // Raw monospaced, selectable source
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
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Pinned bottom metadata bar
            DetailMetadataBar(leading: metadata, trailing: Fmt.relative(item.modified))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .id(item.id)
    }
}

// MARK: - CollectionMemberToolbar
//
// Top-right detail controls: a favorite star toggle, a preview/source segmented
// toggle (eye vs. code-brackets, the active one highlighted), and a Menu mirroring the
// row context menu (favorite, collection membership, remove, show in Finder).

private struct CollectionMemberToolbar: View {
    @Environment(AppModel.self) private var model
    let item: ConfigItem
    let collectionID: String
    @Binding var showSource: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Favorite star toggle
            Button {
                model.toggleFavorite(item.id)
            } label: {
                Image(systemName: "star")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.library.isFavorite(item.id) ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Theme.hairFill, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            }
            .buttonStyle(.plain)
            .linkCursor()
            .help(model.library.isFavorite(item.id) ? "Unfavorite" : "Favorite")

            Spacer(minLength: 0)

            // Preview / source toggle
            HStack(spacing: 2) {
                ToggleModeButton(icon: "eye", isActive: !showSource) { showSource = false }
                ToggleModeButton(icon: "chevron.left.forwardslash.chevron.right", isActive: showSource) { showSource = true }
            }
            .padding(3)
            .background(Theme.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            // Actions menu (matches the row context menu)
            Menu {
                ItemLibraryMenu(item: item, currentCollectionID: collectionID)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Item actions")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - ToggleModeButton
//
// One segment of the preview/source toggle: an SF Symbol that highlights (raised fill
// + primary tint) when its mode is active.

private struct ToggleModeButton: View {
    let icon: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 28, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? Theme.cardRaised : .clear)
                )
        }
        .buttonStyle(.plain)
        .linkCursor()
    }
}

// MARK: - ItemLibraryMenu
//
// The shared library action set, rendered both inside a row .contextMenu and inside a
// detail toolbar Menu (the same buttons in both places). It offers: Favorite /
// Unfavorite; a Collections submenu listing every collection as a Button toggling
// membership (checkmark when a member) with a Divider then "New Collection..." that
// posts a notification to open the create alert; "Remove from collection" for the
// current collection; and "Show in Finder".

private struct ItemLibraryMenu: View {
    @Environment(AppModel.self) private var model
    let item: ConfigItem
    // The collection currently being browsed (enables "Remove from collection").
    var currentCollectionID: String? = nil

    var body: some View {
        // Favorite / Unfavorite
        Button {
            model.toggleFavorite(item.id)
        } label: {
            Label(model.library.isFavorite(item.id) ? "Unfavorite" : "Favorite",
                  systemImage: model.library.isFavorite(item.id) ? "star.slash" : "star")
        }

        // Collections membership submenu
        Menu {
            ForEach(model.library.collections) { collection in
                Button {
                    model.toggleMember(item.id, in: collection.id)
                } label: {
                    if model.library.isMember(item.id, of: collection.id) {
                        Label(collection.name, systemImage: "checkmark")
                    } else {
                        Text(collection.name)
                    }
                }
            }
            Divider()
            Button {
                // Ask the host CollectionsView to open the new-collection alert.
                NotificationCenter.default.post(name: .cortexNewCollectionRequested, object: nil)
            } label: {
                Label("New Collection...", systemImage: "plus")
            }
        } label: {
            Label("Collections", systemImage: "rectangle.stack")
        }

        // Remove from the collection being browsed (only when a member of it)
        if let cid = currentCollectionID, model.library.isMember(item.id, of: cid) {
            Button(role: .destructive) {
                model.toggleMember(item.id, in: cid)
            } label: {
                Label("Remove from Collection", systemImage: "minus.circle")
            }
        }

        Divider()

        // Reveal the underlying file in Finder
        Button {
            NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
    }
}

// MARK: - CollectionsEmptyPane
//
// The full-pane state when there are zero collections: the standard empty state with a
// native "New Collection" button that opens the create alert.

private struct CollectionsEmptyPane: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            CortexEmptyState(
                icon: "rectangle.stack",
                title: "No collections yet",
                message: "Collections group your skills, agents, commands, and rules. Create one to start organizing."
            )
            Button(action: onCreate) {
                Label("New Collection", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.claude, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            }
            .buttonStyle(.plain)
            .linkCursor()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

// MARK: - Notification bridge
//
// The "New Collection..." entry inside the per-item Collections menu lives deep in the
// tree, so it posts this notification to ask the top-level CollectionsView to present
// its native create alert.

extension Notification.Name {
    static let cortexNewCollectionRequested = Notification.Name("cortex.newCollectionRequested")
}

// MARK: - CollectionsFmt
//
// File-size and home-relative path helpers for the member metadata bar (kept local so
// CollectionsView is self-contained and does not depend on another feature file).

enum CollectionsFmt {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB]
        return f
    }()

    static func size(_ bytes: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(bytes))
    }

    static func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
