import SwiftUI

// MARK: - SplitDetailView
//
// Reusable in-page master/detail layout used by list feature views INSTEAD of a
// modal sheet: a header + selectable list on the left, and the selected item's
// detail on the right (an empty state when nothing is selected). Generic over the
// item, the list header, the row view, and the detail view.
//
// Usage:
//   SplitDetailView(items: items, selectedID: $selectedID,
//       emptyIcon: "bolt", emptyTitle: "No skill selected",
//       emptyMessage: "Pick a skill to see its dashboard.",
//       listHeader: { Header(...) },
//       row: { item, isSelected in RowView(item, isSelected) },
//       detail: { item in DetailView(item) })

struct SplitDetailView<Item: Identifiable, ListHeader: View, Row: View, Detail: View>: View {
    let items: [Item]
    @Binding var selectedID: Item.ID?
    var listWidth: CGFloat = 340
    var autoSelectFirst: Bool = true
    // When false, the heavy content shows immediately with no skeleton (used for in-page
    // tab switches, where the page is already on screen and a skeleton flash reads wrong).
    var showSkeleton: Bool = true
    var emptyIcon: String = "square.dashed"
    var emptyTitle: String = "Nothing selected"
    var emptyMessage: String = "Select an item on the left to see its details."
    // Optional custom empty-state view (shown when nothing is selected). When nil the
    // default CortexEmptyState (icon/title/message) is used, so existing call sites are
    // unchanged. Used by Sessions to show its aggregate dashboard as the default pane.
    var emptyContent: (() -> AnyView)? = nil
    @ViewBuilder var listHeader: () -> ListHeader
    @ViewBuilder var row: (Item, Bool) -> Row
    @ViewBuilder var detail: (Item) -> Detail

    // Gates the heavy List + detail behind a brief skeleton so the page's scale-in stays
    // smooth (scaling the skeleton is cheap, unlike a live AppKit List) and the page feels
    // instant. Resets every time the page is opened (the route gives it a fresh identity).
    @State private var ready = false

    private var selectedItem: Item? { items.first { $0.id == selectedID } }

    var body: some View {
        ZStack {
            if ready || !showSkeleton {
                listAndDetail.transition(.opacity)
            } else {
                SplitDetailSkeleton(listWidth: listWidth).transition(.opacity)
            }
        }
        .background(Theme.canvas)
        .onAppear {
            selectFirstIfNeeded()
            // Build the real content only after the page transition settles, so the scale
            // animates the cheap skeleton (smooth) and the heavy table builds off the
            // animation's critical path. Skipped when showSkeleton is false (tab switches).
            guard showSkeleton else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeOut(duration: 0.2)) { ready = true }
            }
        }
        .onChange(of: items.map(\.id)) { _, _ in selectFirstIfNeeded() }
    }

    // The real master/detail content, built once `ready` flips (after the transition).
    private var listAndDetail: some View {
        HStack(spacing: 0) {
            // Left pane: header + NATIVE selectable list (system selection + macOS 26
            // look, mirroring the native middle column). Row builders should return
            // plain content; the List draws the selection highlight.
            VStack(spacing: 0) {
                listHeader()
                    .padding(.horizontal, 16)
                    // Real breathing room between the title-bar band and the page title.
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                List(selection: $selectedID) {
                    ForEach(items) { item in
                        row(item, item.id == selectedID)
                            .tag(item.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            .frame(width: listWidth)
            .background(Theme.canvas)

            Divider().overlay(Theme.stroke)

            // Right pane: detail of the selection, or an empty state
            Group {
                if let item = selectedItem {
                    detail(item)
                } else if let emptyContent {
                    emptyContent()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CortexEmptyState(icon: emptyIcon, title: emptyTitle, message: emptyMessage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        }
    }

    private func selectFirstIfNeeded() {
        guard autoSelectFirst else { return }
        // Drop a stale selection: when the data reloads (or we arrive on a tab whose items
        // don't include the carried-over id), the selected id may no longer exist. Clearing
        // it lets the auto-select below recover instead of stranding the empty state.
        if let sel = selectedID, !items.contains(where: { $0.id == sel }) {
            selectedID = nil
        }
        if selectedID == nil, let first = items.first?.id {
            selectedID = first
        }
    }
}

// MARK: - Split-detail skeleton
//
// A lightweight shimmer stand-in for the master/detail layout, shown during the page's
// scale-in transition (cheap to scale) while the real List + detail build behind it.
// Mirrors the real layout's geometry so the crossfade to real content is not jarring.

private struct SplitDetailSkeleton: View {
    let listWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            // Master list: a title + filter bar over a column of row placeholders.
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock(width: 120, height: 22, cornerRadius: 6)
                    SkeletonBlock(height: 34, cornerRadius: 11)
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 12)

                VStack(spacing: 8) {
                    ForEach(0..<12, id: \.self) { _ in
                        SkeletonBlock(height: 38, cornerRadius: Theme.radiusSmall)
                    }
                }
                .padding(.horizontal, 12)
                Spacer(minLength: 0)
            }
            .frame(width: listWidth)
            .background(Theme.canvas)

            Divider().overlay(Theme.stroke)

            // Detail: a title + subtitle over a couple of card placeholders.
            VStack(alignment: .leading, spacing: 16) {
                SkeletonBlock(width: 220, height: 28, cornerRadius: 6)
                SkeletonBlock(width: 320, height: 13, cornerRadius: 5)
                SkeletonCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonBlock(width: 140, height: 14, cornerRadius: 5)
                        SkeletonBlock(height: 12, cornerRadius: 4)
                        SkeletonBlock(width: 260, height: 12, cornerRadius: 4)
                    }
                }
                SkeletonCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonBlock(width: 120, height: 14, cornerRadius: 5)
                        SkeletonBlock(height: 80, cornerRadius: 8)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.canvas)
        }
    }
}

// MARK: - Selectable list row chrome
//
// Shared rounded row background used by split-view list rows so selection looks
// consistent (selected = elevated fill, hover = faint wash).

struct SelectableRow<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .fill(isSelected ? Theme.cardRaised : (hovering ? Theme.hairFill : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .strokeBorder(isSelected ? Theme.strokeStrong : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .linkCursor()
    }
}
