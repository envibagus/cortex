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

    private var selectedItem: Item? { items.first { $0.id == selectedID } }

    var body: some View {
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
        .background(Theme.canvas)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: items.map(\.id)) { _, _ in selectFirstIfNeeded() }
    }

    private func selectFirstIfNeeded() {
        guard autoSelectFirst, selectedID == nil, let first = items.first?.id else { return }
        selectedID = first
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
    }
}
