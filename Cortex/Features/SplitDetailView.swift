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
    // When set, the split renders the app's standard page chrome (title + count badge +
    // subtitle in the toolbar band, via `.cortexPageChrome`) so the left pane keeps only its
    // filter bar. Pages with a bespoke full-width header (Repos, Diffs) leave these nil and
    // apply `.cortexPageChrome` at their own root instead.
    var title: String? = nil
    var subtitle: String? = nil
    var count: Int? = nil
    var emptyIcon: String = "square.dashed"
    var emptyTitle: String = "Nothing selected"
    var emptyMessage: String = "Select an item on the left to see its details."
    // Optional custom empty-state view (shown when nothing is selected). When nil the
    // default CortexEmptyState (icon/title/message) is used, so existing call sites are
    // unchanged. Used by Sessions to show its aggregate dashboard as the default pane.
    var emptyContent: (() -> AnyView)? = nil
    // Builds the keyboard selection actions (⌘E / ⌘C / ⌫) for the selected item. Only the
    // config/library pages pass it; when nil the list publishes no focused actions.
    var actions: ((Item) -> PageActions)? = nil
    @ViewBuilder var listHeader: () -> ListHeader
    @ViewBuilder var row: (Item, Bool) -> Row
    @ViewBuilder var detail: (Item) -> Detail

    @Environment(AppModel.self) private var model

    // Gates the heavy List + detail behind a brief skeleton so the page's scale-in stays
    // smooth (scaling the skeleton is cheap, unlike a live AppKit List) and the page feels
    // instant. Resets every time the page is opened (the route gives it a fresh identity).
    @State private var ready = false
    // Set when the user CLICKS a row, so the selection observer skips its auto-scroll for that
    // one change (clicks shouldn't move the list; only external selections should).
    @State private var suppressScrollOnce = false

    private var selectedItem: Item? { items.first { $0.id == selectedID } }

    var body: some View {
        // Apply the shared page chrome (title in the band) only when a title is provided,
        // and the soft top scroll-edge blur so the band frosts as the list scrolls under it.
        if let title {
            core
                .cortexScrollEdge()
                .cortexPageChrome(title, subtitle: subtitle, count: count)
        } else {
            core
        }
    }

    private var core: some View {
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
        // ⌘R (refreshAll) bumps refreshToken: replay the skeleton while the data reloads,
        // then crossfade back so any newly-scanned items appear behind the shimmer.
        .onChange(of: model.refreshToken) { _, _ in
            guard showSkeleton else { return }
            withAnimation(.easeOut(duration: 0.15)) { ready = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                withAnimation(.easeOut(duration: 0.2)) { ready = true }
            }
        }
    }

    // The real master/detail content, built once `ready` flips (after the transition).
    private var listAndDetail: some View {
        HStack(spacing: 0) {
            // Left pane: header + NATIVE selectable list (system selection + macOS 26
            // look, mirroring the native middle column). Row builders should return
            // plain content; the List draws the selection highlight.
            VStack(spacing: 0) {
                listHeader()
                    .padding(.horizontal, Theme.pageHInset)
                    // Breathing room between the title-bar band and the left-pane filter.
                    .padding(.top, Theme.pageTopInset)
                    .padding(.bottom, 12)

                // Wrapped in a ScrollViewReader so a programmatic selection (⌘K deep-link, or
                // any external `selectedID` change) reveals the row instead of leaving it
                // off-screen in a long list. Scroll-only: NO `.focusable()`/`.onMoveCommand`
                // here, since those are what beach-balled the app before.
                ScrollViewReader { proxy in
                    List {
                        ForEach(items) { item in
                            // Custom selection so the rounded highlight respects `pageHInset` on
                            // BOTH sides (native list styles either overhang far left `.inset` or
                            // run full-width `.plain`). Click-selects into the shared binding.
                            SplitRow(isSelected: item.id == selectedID,
                                     onSelect: {
                                         // A click already puts the row under the cursor; suppress
                                         // the auto-scroll for this change so the list doesn't jump
                                         // (auto-scroll is only for external selections: deep-link / refresh).
                                         if selectedID != item.id { suppressScrollOnce = true }
                                         selectedID = item.id
                                     }) {
                                row(item, item.id == selectedID)
                            }
                            // The highlight's outer edge lands exactly on pageHInset (the inset
                            // compensates the List's own built-in row indent), flush with the
                            // filter bar's search field above.
                            .listRowInsets(EdgeInsets(top: 1, leading: Theme.splitListRowInset,
                                                      bottom: 1, trailing: Theme.splitListRowInset))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            // Explicit id so `proxy.scrollTo(selectedID)` can target this row.
                            .id(item.id)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    // Reveal the selected row when the selection changes EXTERNALLY (deep-link,
                    // refresh) - centered so a long list doesn't hide it at an edge. A plain
                    // click sets `suppressScrollOnce`, so clicking a partially-visible row selects
                    // it without yanking the list under the cursor.
                    .onChange(of: selectedID) { _, id in
                        guard let id else { return }
                        if suppressScrollOnce { suppressScrollOnce = false; return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    // The list is built behind the skeleton gate, so a selection set DURING that
                    // gate (a ⌘K deep-link) fired onChange before these rows existed. Once the
                    // real list appears, jump to the already-selected row (next runloop, so the
                    // rows are laid out first).
                    .onAppear {
                        guard let id = selectedID else { return }
                        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                    }
                }
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
                    // No title block: the page title now lives in the toolbar band, so the
                    // left pane's skeleton is just the filter-bar placeholder.
                    SkeletonBlock(height: 34, cornerRadius: 11)
                }
                .padding(.horizontal, Theme.pageHInset)
                .padding(.top, Theme.pageTopInset)
                .padding(.bottom, 12)

                VStack(spacing: 8) {
                    ForEach(0..<12, id: \.self) { _ in
                        SkeletonBlock(height: 38, cornerRadius: Theme.radiusSmall)
                    }
                }
                .padding(.horizontal, Theme.pageHInset)
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
            .padding(Theme.pageHInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.canvas)
        }
    }
}

// MARK: - Split list row (custom inset selection)
//
// One clickable list row whose rounded selection/hover highlight is inset by the page
// padding on BOTH sides (native list styles can't: `.inset` overhangs far left, `.plain`
// runs edge-to-edge). The highlight's outer edge lands on `pageHInset` (via
// `Theme.splitListRowInset` in `.listRowInsets`), flush with the header's search field;
// the 10pt inner pad keeps row content inside the highlight, mirroring the search
// field's own inner padding. Click selects; the enclosing List scrolls.

private struct SplitRow<Content: View>: View {
    let isSelected: Bool
    let onSelect: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                        // Prominent, on-brand selection: the native list-selection blue (the
                        // same accent macOS uses for selected rows), so the active item clearly
                        // stands out; a faint wash on hover.
                        .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor)
                                         : (hovering ? Theme.hairFill : .clear))
                )
                .contentShape(Rectangle())
                // White text on the selection fill so the row stays legible when active.
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
