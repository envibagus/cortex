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

    // What's selected in the tree: a collection (-> its metadata in the right pane) or a
    // member item (-> that item's document). One selection drives the whole right pane.
    enum Selection: Hashable {
        case collection(String)
        case member(item: String, collection: String)
    }
    @State private var selection: Selection?
    // Collection ids whose tree is expanded (members shown nested beneath them).
    @State private var expanded: Set<String> = []

    // New-collection alert state (native .alert with a TextField).
    @State private var showNewCollection = false
    @State private var newCollectionName = ""

    var body: some View {
        Group {
            if model.library.collections.isEmpty {
                CollectionsEmptyPane(onCreate: beginNewCollection)
            } else {
                HStack(spacing: 0) {
                    tree
                        .frame(width: 340)
                        .background(Theme.canvas)
                    Divider().overlay(Theme.stroke)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.canvas)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .cortexPageChrome("Collections",
                          subtitle: "Group skills, agents, commands, and rules",
                          count: model.library.collections.count) {
            ToolbarItem(placement: .primaryAction) {
                Button(action: beginNewCollection) {
                    Label("New Collection", systemImage: "plus")
                }
                .help("New collection")
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
        // A "New Collection..." item nested in a member's Collections menu posts this.
        .onReceive(NotificationCenter.default.publisher(for: .cortexNewCollectionRequested)) { _ in
            beginNewCollection()
        }
        .onAppear(perform: autoSelectFirst)
    }

    // MARK: Tree (left pane) - collections, each expandable to its members

    private var tree: some View {
        // A native `.plain` List (the SAME proven pattern as SplitDetailView's left pane): a
        // plain list respects the top safe area, so rows always sit BELOW the toolbar band
        // (unlike a `.sidebar` list, which extends up under the title and scrolls rows over
        // it), and because selection is driven by each row's own Button action - NOT
        // `List(selection:)` - the list never auto-scrolls a selected row up over the band.
        // Custom rows draw the inset-rounded selection; `.cortexScrollEdge` frosts the band as
        // rows scroll under it. Members render as extra rows beneath an expanded collection.
        List {
            ForEach(model.library.collections) { collection in
                CollectionTreeRow(
                    collection: collection,
                    memberCount: model.library.memberCount(collection.id),
                    isSelected: selection == .collection(collection.id),
                    isExpanded: expanded.contains(collection.id),
                    // Clicking a collection selects it AND opens it (if closed); it never
                    // collapses on click - the caret is the only way to collapse.
                    onSelect: {
                        selection = .collection(collection.id)
                        expanded.insert(collection.id)
                    },
                    onToggle: { toggleExpanded(collection.id) }
                )
                .listRowInsets(EdgeInsets(top: 1, leading: Theme.splitListRowInset,
                                          bottom: 1, trailing: Theme.splitListRowInset))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                // Members nested beneath an expanded collection.
                if expanded.contains(collection.id) {
                    ForEach(members(of: collection)) { item in
                        CollectionMemberTreeRow(
                            item: item,
                            collectionID: collection.id,
                            isSelected: selection == .member(item: item.id, collection: collection.id),
                            onTap: { selection = .member(item: item.id, collection: collection.id) }
                        )
                        .listRowInsets(EdgeInsets(top: 1, leading: Theme.splitListRowInset,
                                                  bottom: 1, trailing: Theme.splitListRowInset))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .cortexScrollEdge()
    }

    // MARK: Detail (right pane) - collection metadata, or a member's document

    @ViewBuilder private var detail: some View {
        switch selection {
        case let .member(itemID, cid):
            // Resolve from library items OR mapped MCP servers (a member can be either), so
            // clicking an MCP server / plugin in a collection opens its detail instead of a
            // blank pane.
            if let item = resolveMember(itemID) {
                CollectionMemberDetail(item: item, collectionID: cid)
            } else {
                detailEmpty
            }
        case let .collection(cid):
            if let collection = model.library.collections.first(where: { $0.id == cid }) {
                CollectionMetadataPane(collection: collection)
            } else {
                detailEmpty
            }
        case nil:
            detailEmpty
        }
    }

    private var detailEmpty: some View {
        CortexEmptyState(icon: "rectangle.stack",
                         title: "No collection selected",
                         message: "Select a collection on the left to see what's inside.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Helpers

    /// Resolve a collection's members in stored order (live). Members can be library items
    /// (skills/agents/rules/commands/plugins/instructions - already ConfigItems) OR MCP
    /// servers (mapped to a ConfigItem for display), so one collection can mix anything the
    /// user wants to keep or share together.
    private func members(of collection: LibraryStore.Collection) -> [ConfigItem] {
        let itemsByID = Dictionary(model.config.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mcpByID = Dictionary(model.config.mcpServers.map { ($0.id, Self.mcpConfigItem($0)) }, uniquingKeysWith: { a, _ in a })
        return collection.memberIDs.compactMap { itemsByID[$0] ?? mcpByID[$0] }
    }

    /// Map an MCP server to a ConfigItem so it can be shown as a collection member (mirrors
    /// how the Favorites page surfaces MCP servers).
    static func mcpConfigItem(_ server: MCPServer) -> ConfigItem {
        ConfigItem(
            id: server.id, name: server.name,
            detail: "MCP \u{00B7} \(server.transport.uppercased()) \u{00B7} \(server.scope)",
            path: server.command ?? server.url ?? "",
            kind: .mcp, source: .claude, isGlobal: server.scope == "user",
            projectName: server.scope == "user" ? nil : server.scope,
            fileSize: 0, modified: Date(),
            content: "**Transport:** \(server.transport)\n\n**Scope:** \(server.scope)\n\n`\(server.command ?? server.url ?? "unknown")`",
            frontmatter: [:]
        )
    }

    /// Resolve a single member id to a ConfigItem from library items OR mapped MCP servers (a
    /// member can be either), so the detail pane can open MCP servers and plugins too.
    private func resolveMember(_ id: String) -> ConfigItem? {
        if let item = model.config.items.first(where: { $0.id == id }) { return item }
        if let server = model.config.mcpServers.first(where: { $0.id == id }) { return Self.mcpConfigItem(server) }
        return nil
    }

    /// Toggle a collection's expanded state (its members show/hide beneath it).
    private func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func autoSelectFirst() {
        // Every collection auto-shows its members: expand them all on open.
        expanded = Set(model.library.collections.map(\.id))
        guard selection == nil, let first = model.library.collections.first else { return }
        selection = .collection(first.id)
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
        selection = .collection(created.id)
    }
}

// MARK: - CollectionTreeRow
//
// A collection node in the left tree: a caret (a SEPARATE hit target that only toggles the
// members open/closed), the collection glyph, its name, and a member-count badge. Clicking
// the icon/name SELECTS the collection (right pane shows its metadata) without collapsing the
// tree. Right-click renames or deletes. The rounded selection is inset on both sides to match
// SplitDetailView's SplitRow.

private struct CollectionTreeRow: View {
    @Environment(AppModel.self) private var model
    let collection: LibraryStore.Collection
    let memberCount: Int
    let isSelected: Bool
    let isExpanded: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void

    @State private var hovering = false
    @State private var showRename = false
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 8) {
            // Caret ONLY toggles expand/collapse (a separate hit target from the name). An
            // empty collection has nothing to expand, so its caret is dimmed and disabled
            // (kept in place so names stay aligned with populated rows).
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : Theme.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(memberCount == 0 ? 0.2 : 1)
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(memberCount == 0)
            .help(isExpanded ? "Collapse" : "Expand")

            // Clicking the icon/name selects the collection (shows its metadata on the right).
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: collection.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                        .frame(width: 18)
                    Text(collection.name)
                        .font(.body)
                        .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(memberCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
            .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor)
                             : (hovering ? Theme.hairFill : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button { renameText = collection.name; showRename = true } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                model.library.deleteCollection(collection.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
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

// MARK: - CollectionMemberTreeRow
//
// A member item nested (indented) under its collection: a kind glyph, the item name, and a
// favorite marker. Clicking selects it (right pane shows the item's document). Right-click
// exposes the shared library actions (favorite, collections, remove, reveal).

private struct CollectionMemberTreeRow: View {
    @Environment(AppModel.self) private var model
    let item: ConfigItem
    let collectionID: String
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: item.kind.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                    .frame(width: 16)
                Text(item.name)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if model.library.isFavorite(item.id) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor)
                                 : (hovering ? Theme.hairFill : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Indent members further so they nest clearly beneath their collection's name.
        .padding(.leading, 40)
        .onHover { hovering = $0 }
        .contextMenu { ItemLibraryMenu(item: item, currentCollectionID: collectionID) }
    }
}

// MARK: - CollectionMetadataPane
//
// The right pane when a COLLECTION (not a member) is selected: the collection's identity
// (glyph + name + total) over a "Contents" breakdown of how many of each kind it holds
// (Skills / Agents / …), showing ONLY the kinds actually present. An empty collection
// shows a friendly empty state instead. Selecting a member in the tree swaps this pane for
// that item's document.

private struct CollectionMetadataPane: View {
    @Environment(AppModel.self) private var model
    let collection: LibraryStore.Collection

    private var members: [ConfigItem] {
        // Resolve from library items AND mapped MCP servers, so the "N items" count and the
        // per-kind breakdown match the tree's member count (which also includes MCP servers).
        let itemsByID = Dictionary(model.config.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mcpByID = Dictionary(model.config.mcpServers.map { ($0.id, CollectionsView.mcpConfigItem($0)) }, uniquingKeysWith: { a, _ in a })
        return collection.memberIDs.compactMap { itemsByID[$0] ?? mcpByID[$0] }
    }

    /// Non-zero counts per kind, in ConfigKind's canonical order (nothing shown for kinds
    /// the collection doesn't contain).
    private var breakdown: [(kind: ConfigKind, count: Int)] {
        let byKind = Dictionary(grouping: members, by: \.kind).mapValues(\.count)
        return ConfigKind.allCases.compactMap { kind in
            let n = byKind[kind] ?? 0
            return n > 0 ? (kind, n) : nil
        }
    }

    var body: some View {
        let members = members
        // Empty AND populated collections share the SAME wrapper (a top-aligned ScrollView with
        // the identity header + a "Contents" GroupBox), so selecting one never changes the
        // pane's layout shape. Only the card's body differs: a per-kind breakdown when
        // populated, or an inline empty note when the collection has no members. (An earlier
        // full-height CENTERED empty state here is what made the whole window jump/scroll.)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Identity
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .fill(Theme.hairFill)
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: collection.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.secondary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(collection.name)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        Text(members.count == 1 ? "1 item" : "\(members.count) items")
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }

                // Contents card: per-kind breakdown when populated, or an inline empty note.
                GroupBox {
                    if members.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.system(size: 26, weight: .regular))
                                .foregroundStyle(Theme.textTertiary)
                            Text("No items yet")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Text("Right-click any skill, agent, command, or rule and choose Collections to add it here.")
                                .font(.callout)
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(breakdown.enumerated()), id: \.element.kind) { idx, entry in
                                HStack(spacing: 10) {
                                    Image(systemName: entry.kind.icon)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.textSecondary)
                                        .frame(width: 20)
                                    Text(entry.kind.plural)
                                        .font(.body)
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer(minLength: 8)
                                    Text("\(entry.count)")
                                        .font(.body.monospacedDigit())
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .padding(.vertical, 9)
                                if idx < breakdown.count - 1 { Divider() }
                            }
                        }
                    }
                } label: {
                    Label("Contents", systemImage: "square.stack.3d.up")
                        .font(.headline)
                }
            }
            .padding(Theme.pageHInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(collection.id)
    }
}

// MARK: - CollectionMemberDetail
//
// The viewer for a selected member. To stay consistent with the rest of the app it uses NO
// bespoke viewer: it dispatches on the item's kind and shows the SAME default detail view the
// item's own home page uses - Plugins -> PluginDetail, MCP -> MCPServerDetail, Instructions ->
// InstructionDetail, and skills / agents / commands / rules (and other markdown kinds) ->
// ConfigItemDetail. "New Collection…" from any of those viewers' menus opens this page's modal.

private struct CollectionMemberDetail: View {
    @Environment(AppModel.self) private var model
    let item: ConfigItem
    let collectionID: String

    // Opening the create-collection modal is requested by posting the shared notification (the
    // host CollectionsView listens for it), so a nested viewer's menu can still create one.
    private func requestNewCollection(_: String) {
        NotificationCenter.default.post(name: .cortexNewCollectionRequested, object: nil)
    }

    var body: some View {
        switch item.kind {
        case .plugin:
            PluginDetail(item: item)
        case .mcp:
            // MCP servers keep their own detail; resolve the real server behind the mapped id.
            if let server = model.config.mcpServers.first(where: { $0.id == item.id }) {
                MCPServerDetail(server: server)
            } else {
                ConfigItemDetail(item: item, tint: item.source.tint, requestNewCollection: requestNewCollection)
            }
        case .instruction:
            InstructionDetail(item: item, requestNewCollection: requestNewCollection)
        default:
            // skills / agents / commands / rules (and any other markdown-backed kind) use the
            // shared library document viewer, exactly as the Skills/Agents pages do.
            ConfigItemDetail(item: item, tint: item.source.tint, requestNewCollection: requestNewCollection)
        }
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

// MARK: - AddToCollectionMenu
//
// A reusable "Add to Collection" control, keyed by a plain item id, so ANY library entity
// can join a collection - library items (ConfigItem.id), MCP servers (server.id), plugins -
// since membership is stored as ids. Renders as a submenu inside a row `.contextMenu`, or,
// with `compact: true`, as a small icon menu button for a detail toolbar. Each collection
// toggles membership (checkmark when a member); "New Collection…" opens the create modal.

struct AddToCollectionMenu: View {
    @Environment(AppModel.self) private var model
    let itemID: String
    var compact: Bool = false

    var body: some View {
        Menu {
            if model.library.collections.isEmpty {
                Text("No collections yet")
            }
            ForEach(model.library.collections) { collection in
                Button {
                    model.toggleMember(itemID, in: collection.id)
                } label: {
                    if model.library.isMember(itemID, of: collection.id) {
                        Label(collection.name, systemImage: "checkmark")
                    } else {
                        Text(collection.name)
                    }
                }
            }
            Divider()
            Button {
                // Create a new collection on the Collections page (opens its name modal).
                model.route = .collections
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    NotificationCenter.default.post(name: .cortexNewCollectionRequested, object: nil)
                }
            } label: {
                Label("New Collection\u{2026}", systemImage: "plus")
            }
        } label: {
            if compact {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            } else {
                Label("Add to Collection", systemImage: "rectangle.stack.badge.plus")
            }
        }
        .menuIndicator(.hidden)
        .help("Add to a collection")
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
