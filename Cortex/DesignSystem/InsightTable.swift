import SwiftUI

// MARK: - InsightTable
//
// A small, reusable native table: a caption header row over divider-separated data
// rows, modeled on StatsModelTable. Each column is either flexible (leading, fills
// remaining width) or fixed-width (trailing by default). The caller supplies a cell
// builder keyed by (row, columnIndex). Wrap it in a GroupBox under a section Label so
// it inherits the app's CortexGroupBoxStyle padding.

struct InsightColumn: Identifiable {
    let id = UUID()
    var title: String
    var width: CGFloat?            // nil => flexible, leading-aligned
    var alignment: Alignment = .trailing
}

struct InsightTable<Row: Identifiable, Cell: View>: View {
    let columns: [InsightColumn]
    let rows: [Row]
    // When set, each row becomes a button (with a hover wash) that calls this on tap.
    var onRowTap: ((Row) -> Void)? = nil
    @ViewBuilder var cell: (Row, Int) -> Cell

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header captions.
            HStack(spacing: 12) {
                ForEach(Array(columns.enumerated()), id: \.element.id) { _, column in
                    Text(column.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .modifier(ColumnWidth(column))
                }
            }
            .padding(.bottom, 8)

            // Data rows.
            ForEach(Array(rows.enumerated()), id: \.element.id) { _, row in
                rowContent(row)
                if row.id != rows.last?.id { Divider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // One data row: plain, or a tappable button row (with a hover wash) when
    // `onRowTap` is set.
    @ViewBuilder
    private func rowContent(_ row: Row) -> some View {
        let inner = HStack(spacing: 12) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                cell(row, index)
                    .modifier(ColumnWidth(column))
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)

        if let onRowTap {
            // Pad the row content +8 horizontally so the hover wash has breathing room
            // around the text, then pull the whole row back -8 so the columns still line
            // up with the header (the wash bleeds into the card's padding, not the text).
            Button { onRowTap(row) } label: {
                inner
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 8)
            .padding(.horizontal, -8)
        } else {
            inner
        }
    }
}

// Apply a column's width + alignment: fixed columns get an exact width, flexible ones
// fill the remaining space and align leading.
private struct ColumnWidth: ViewModifier {
    let column: InsightColumn
    init(_ column: InsightColumn) { self.column = column }

    func body(content: Content) -> some View {
        if let width = column.width {
            content.frame(width: width, alignment: column.alignment)
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - List cell
//
// A comma-joined, truncating text cell for "many values" columns (models, languages,
// frameworks): shows the first few items, then a "+N" overflow hint.

struct InsightListCell: View {
    var items: [String]
    var maxShown: Int = 2

    var body: some View {
        Text(display)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var display: String {
        guard !items.isEmpty else { return "-" }
        let shown = items.prefix(maxShown)
        let extra = items.count - shown.count
        return shown.joined(separator: ", ") + (extra > 0 ? " +\(extra)" : "")
    }
}
