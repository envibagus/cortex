import SwiftUI
import AppKit

// MARK: - Directory picker
//
// Shared native folder chooser used by onboarding and Settings to add scan roots.

extension NSOpenPanel {
    /// Present a directory picker and return the chosen folder paths (empty if the
    /// user cancels). Allows selecting multiple folders at once.
    static func chooseDirectories(message: String) -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = message
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map(\.path)
    }
}

// MARK: - Liquid Glass
//
// Proper macOS 26 Liquid Glass adoption (Apple "Applying Liquid Glass to custom
// views"): capsule pills use the real `glassEffect` with an INTERACTIVE glass so the
// material responds to press/hover, and groups of pills are wrapped in a
// `GlassEffectContainer` so SwiftUI renders them together and blends adjacent shapes.
// Both degrade to a translucent material capsule before macOS 26.

extension View {
    /// An interactive Liquid Glass capsule (material-capsule fallback pre-macOS 26).
    /// Place inside a `LiquidGlassGroup` so neighboring pills render + blend together.
    @ViewBuilder
    func glassPill() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        }
    }
}

/// Groups Liquid Glass pills in a `GlassEffectContainer` so they render together
/// (better performance) and their shapes blend as they near each other. The `spacing`
/// controls when adjacent shapes start to merge. A plain passthrough before macOS 26.
struct LiquidGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Card container
//
// The base surface used everywhere: rounded fill, hairline stroke, padding.

struct Card<Content: View>: View {
    var padding: CGFloat = Theme.cardPadding
    var fill: Color = Theme.card
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
    }
}

// MARK: - Card group-box style
//
// One consistent card chrome for every native `GroupBox` in the app, so all cards
// share the SAME inner padding, fill, hairline, and corner radius (Image #4: "all
// padding should be the same, applied the entire app"). Applied once at the app root
// so it propagates to every descendant GroupBox; nearer `.groupBoxStyle(_:)` calls
// override it for special cases.
//
// Content hugs its height by default (safe in any scroll/stack layout). Pass
// `fillHeight: true` for paired cards in a `Grid` row / `HStack` that should match
// the tallest sibling's height (so their borders line up exactly).

struct CortexGroupBoxStyle: GroupBoxStyle {
    var fillHeight: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.content
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
    }
}

// MARK: - Stat tile
//
// The labelled number cell used by both the hero KPI row (Image #2) and the
// stats grid (Image #1). `dot` draws a small colored status dot next to the label.

struct StatTile: View {
    var label: String
    var value: String
    var dot: Color? = nil
    var sublabel: String? = nil
    var big: Bool = false

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if let dot {
                        Circle().fill(dot).frame(width: 7, height: 7)
                    }
                    Text(label)
                        .font(.cortexCaption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(value)
                    .font(big ? .cortexStatNumber : .system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let sublabel {
                    Text(sublabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Section header

struct SectionHeader: View {
    var icon: String
    var title: String
    var tint: Color = Theme.textSecondary
    var trailing: String? = nil
    var chevron: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.cortexHeadline)
                .foregroundStyle(Theme.textPrimary)
            if let trailing {
                Text(trailing)
                    .font(.cortexCaption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

// MARK: - Favorite toggle (id-based star)
//
// A star button that flips LibraryStore favorite state by a raw String id, for items
// that aren't ConfigItems (MCP servers, memory files). Mirrors the library StarButton
// look (filled + primary when favorited) so the affordance reads identically.

struct FavoriteToggle: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        let on = model.library.isFavorite(id)
        Button {
            model.toggleFavorite(id)
        } label: {
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? .primary : .secondary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(on ? "Remove from Favorites" : "Add to Favorites")
    }
}

// MARK: - Glass refresh button
//
// The shared "refresh all data" control: a circular Liquid Glass pill with a clockwise
// arrow that spins while a full refresh is in flight. One implementation so the Home,
// Work Graph, and any other refresh affordance look identical (the same glass chrome as
// the filter pills), instead of each page hand-rolling its own circle.

struct GlassRefreshButton: View {
    @Environment(AppModel.self) private var model
    @State private var spinning = false

    var body: some View {
        LiquidGlassGroup(spacing: 0) {
            Button {
                Task {
                    spinning = true
                    await model.refreshAll()
                    spinning = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                               value: spinning)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassPill()
            .help("Refresh all data")
            .disabled(spinning)
        }
    }
}

// MARK: - Pill / tag

struct Pill: View {
    var text: String
    var tint: Color = Theme.textSecondary
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(filled ? .white : tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(filled ? tint : tint.opacity(0.14))
            )
    }
}

// MARK: - Liquid Glass segmented control
//
// A capsule segmented control whose selection "thumb" slides between segments via
// matchedGeometryEffect. On macOS 26 the thumb is real interactive Liquid Glass
// (`glassEffect`), responding to hover/press; before macOS 26 it degrades to a
// raised fill + hairline. This replaces the system `.pickerStyle(.segmented)` so
// every tab/window switch in the app shares one polished, glassy look. Generic over
// any Hashable value with a label closure (so it drives Window/Tab/RepoTab enums).

struct GlassSegmentedControl<Value: Hashable>: View {
    let items: [Value]
    @Binding var selection: Value
    var label: (Value) -> String
    // The sliding thumb shares one geometry namespace across the segments.
    @Namespace private var thumbNS

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = item == selection
                Button {
                    withAnimation(.smooth(duration: 0.28)) { selection = item }
                } label: {
                    Text(label(item))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background {
                            // Only the selected segment carries the thumb; the shared
                            // matchedGeometryEffect id animates it across positions.
                            if selected {
                                GlassSegmentThumb()
                                    .matchedGeometryEffect(id: "glassSegThumb", in: thumbNS)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        // Track: a faint capsule fill + hairline, matching the glass-pill chrome.
        .background(Theme.hairFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// The sliding selection pill: interactive Liquid Glass on macOS 26, a raised fill
/// + hairline below it. Kept private so all segmented controls share one thumb look.
private struct GlassSegmentThumb: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            // Static glass (NOT .interactive()): the interactive variant balloons into a
            // large cursor-following circular "lens" on hover, which read as a stray
            // circle floating in the replay transport. Static keeps the calm pill look.
            Color.clear.glassEffect(.regular, in: Capsule())
        } else {
            Capsule()
                .fill(Theme.cardRaised)
                .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
        }
    }
}

// MARK: - Hover highlight
//
// A self-contained rounded hover wash for clickable controls that otherwise have no
// pointer affordance (plain icon buttons, navigable rows). Mirrors the native
// list-row hover so custom `.buttonStyle(.plain)` controls feel responsive.

extension View {
    func hoverHighlight(cornerRadius: CGFloat = Theme.radiusSmall) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}

private struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.hairFill)
                    .opacity(hovering ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Row link (list rows, recent sessions, hygiene cards)

struct RowLink<Leading: View, Trailing: View>: View {
    var action: () -> Void = {}
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                leading
                Spacer(minLength: 8)
                trailing
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(hovering ? Theme.cardRaised : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Page scaffold
//
// Standard padded scroll container with a large title used by most feature views.

struct PageScaffold<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    var toolbar: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.cortexTitle).foregroundStyle(Theme.textPrimary)
                        if let subtitle {
                            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    if let toolbar { toolbar }
                }
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }
}

// MARK: - Empty / loading states

struct CortexEmptyState: View {
    var icon: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
            Text(title).font(.cortexHeadline).foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

// MARK: - Filter sort option
//
// A small protocol the filter bar's sort button is generic over, so the same glass
// sort pill drives different sort enums (library list panes vs the Sessions list).
// Each case supplies a menu title + an SF Symbol. `LibrarySort` and `SessionSort`
// both conform; the bar/button stay one shared implementation (no copy-paste).

protocol FilterSortOption: CaseIterable, Hashable, Identifiable {
    var title: String { get }
    var icon: String { get }
}

// MARK: - Library sort
//
// The sort order applied to every library list pane. Backed only by real fields that
// every (or most) library item carries: name, last-modified date, and on-disk size.
// There is deliberately NO "Most used" option since the app has no per-item usage data.
// The raw value is what AppModel persists app-wide via @AppStorage.

enum LibrarySort: String, CaseIterable, Identifiable, FilterSortOption {
    case name
    case modified
    case size

    var id: String { rawValue }

    /// The menu display title for each order.
    var title: String {
        switch self {
        case .name: "Name"
        case .modified: "Recently modified"
        case .size: "Largest"
        }
    }

    /// An SF Symbol matching each order (shown on the compact sort button + menu rows).
    var icon: String {
        switch self {
        case .name: "textformat"
        case .modified: "clock"
        case .size: "arrow.up.arrow.down"
        }
    }
}

// MARK: - Library filter bar
//
// The search + scope filter used in library list-pane headers (Skills / Agents / MCP /
// Rules / Commands / Memory / ...). A prominent, command-palette-flavored search field
// over a row of the scope pill (All / Global / each project, flexible) and a compact
// sort button on the right (Name / Recently modified / Largest), so items that can
// exist both globally and per-project are narrowed by WHERE they live and ordered by
// HOW they're sorted. `scope == nil` means "all scopes"; the scope pill only appears
// once there's more than one scope to pick, but the sort button always shows.

struct LibraryFilterBar<Sort: FilterSortOption>: View {
    @Environment(AppModel.self) private var model
    @Binding var query: String
    var placeholder: String
    @Binding var scope: String?
    var scopes: [String]
    @Binding var sort: Sort
    // ⌘F focuses this field (via model.focusSearchToken).
    @FocusState private var searchFocused: Bool

    var body: some View {
        if scopes.count > 1 {
            // With a scope filter: search on its own row, then a [scope | sort] row.
            VStack(alignment: .leading, spacing: 9) {
                searchField
                LiquidGlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        ScopeFilterButton(scope: $scope, scopes: scopes)
                        SortFilterButton(sort: $sort)
                    }
                }
            }
        } else {
            // No scope filter: the sort pill sits inline next to the search bar (it
            // fills the row height, so it matches the taller search field exactly).
            LiquidGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    searchField
                    SortFilterButton(sort: $sort)
                }
            }
        }
    }

    // The command-palette-flavored search pill (magnifier + field + clear).
    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: FilterControl.height)
        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Theme.strokeStrong, lineWidth: 1))
        .onChange(of: model.focusSearchToken) { _, _ in searchFocused = true }
    }
}

// The sort button: a compact pill mirroring the scope pill's chrome, opening a native
// menu of the sort orders (generic over the caller's FilterSortOption) with a checkmark
// on the active one. Sized to hug its label so it sits snug at the trailing edge of the
// row. Generic so the library panes (LibrarySort) and Sessions (SessionSort) share it.
private struct SortFilterButton<Sort: FilterSortOption>: View {
    @Binding var sort: Sort
    @State private var open = false

    var body: some View {
        // A Button (NOT a Menu): the borderless Menu style rendered shorter than the
        // scope pill's Button, so the two never lined up. Built exactly like
        // ScopeFilterButton - Button + glassPill + popover - so the glass chrome and the
        // 36pt height are pixel-identical to the scope filter, just narrower (icon only).
        Button { open = true } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 52, height: FilterControl.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassPill()
        .help("Sort: \(sort.title)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SortPopover(sort: $sort) { open = false }
        }
    }
}

// The sort popover: a compact list of the sort orders (generic over FilterSortOption)
// with a checkmark on the active one. Mirrors ScopePopover's row styling.
private struct SortPopover<Sort: FilterSortOption>: View {
    @Binding var sort: Sort
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(Sort.allCases)) { option in
                Button {
                    sort = option
                    dismiss()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: option.icon)
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 16)
                        Text(option.title)
                            .font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer(minLength: 12)
                        if option == sort {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight()
            }
        }
        .padding(.vertical, 4)
        .frame(width: 220)
    }
}

// One shared height for the filter-row controls (search field, scope pill, sort pill)
// so they all line up exactly.
private enum FilterControl { static let height: CGFloat = 36 }

// The scope pill: shows the active scope and opens a searchable popover of scopes.
private struct ScopeFilterButton: View {
    @Binding var scope: String?
    let scopes: [String]
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(scope ?? "All scopes").lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: FilterControl.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Liquid Glass pill (matches the sort button + the rest of the app's glass).
        .glassPill()
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScopePopover(scope: $scope, scopes: scopes) { open = false }
        }
    }
}

// A small command-palette-style popover: a search field over a scrollable, live-
// filtered list of scopes (All scopes + Global + each project). Picking one applies
// it and dismisses. Scales to 100s of project scopes where chips/menus do not.
private struct ScopePopover: View {
    @Binding var scope: String?
    let scopes: [String]
    let dismiss: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? scopes : scopes.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field (echoes the ⌘K palette, scaled down).
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                TextField("Filter scopes", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focused)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().overlay(Theme.stroke)

            ScrollView {
                LazyVStack(spacing: 0) {
                    scopeRow(label: "All scopes", icon: "square.grid.2x2", value: nil)
                    ForEach(filtered, id: \.self) { value in
                        scopeRow(label: value, icon: value == "Global" ? "globe" : "folder", value: value)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 260)
        // Defer focus until the popover has settled, else the field opens unfocused.
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } }
    }

    private func scopeRow(label: String, icon: String, value: String?) -> some View {
        let selected = scope == value
        return Button {
            scope = value
            dismiss()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 16)
                Text(label).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }
}

// MARK: - Flow layout
//
// A simple wrapping layout: lays children left-to-right and wraps to a new line when
// the next child would overflow the proposed width. Used for short chip / CTA rows
// that may not all fit on one line (e.g. the assistant's navigation buttons inside a
// narrow bubble). macOS 13+ Layout; the app targets 15.0.

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0, totalHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x - bounds.minX + size.width > bounds.width {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Context tokens label
//
// An HONEST readout of how many tokens a session's MOST RECENT turn carried (input +
// cache), straight from the transcript. Deliberately NOT a "% of window": Claude Code
// does not persist whether a session uses the 200K or 1M window (Opus ships in both),
// so a percentage would be a guess. We show the real absolute count instead. `gauge`
// glyph + "~147K context" with an explanatory tooltip.

struct ContextTokensLabel: View {
    let tokens: Int

    private var help: String {
        "The most recent turn carried ~\(Fmt.compact(tokens)) tokens of context (input + cache), read from the transcript. Shown as a raw count, not a percent: the 200K vs 1M window size isn't recorded in the transcript, so a percentage can't be derived accurately."
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 10, weight: .semibold))
            Text("~\(Fmt.compact(tokens)) context")
                .font(.cortexCaption)
        }
        .foregroundStyle(Theme.textTertiary)
        .help(help)
    }
}

// MARK: - Responsive grid helper
//
// A responsive grid that, unlike a `LazyVGrid`, reports its TRUE wrapped height to the
// parent stack. A LazyVGrid placed in a VStack-in-ScrollView under-measures its height
// (it only lays out visible rows), so the next sibling card draws OVER its wrapped rows.
// We avoid that by measuring the available width with a GeometryReader, computing the
// column count from `minWidth + spacing`, and laying the items out NON-LAZILY as a
// VStack of HStack rows (equal-width cells via `.frame(maxWidth: .infinity)`). The
// public API (`data`, `minWidth`, `spacing`, content closure) is unchanged.

struct FlowGrid<Data: RandomAccessCollection, Content: View>: View where Data.Element: Identifiable {
    var data: Data
    var minWidth: CGFloat = 150
    var spacing: CGFloat = 12
    @ViewBuilder var content: (Data.Element) -> Content

    // The measured available width, used to derive the column count. Starts at 0 so the
    // first frame renders a single column, then settles once the GeometryReader reports.
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        // Derive the column count from the measured width (at least one column), the
        // same rule `.adaptive(minimum:)` uses: fit as many `minWidth` cells as the
        // width allows, accounting for inter-cell spacing.
        let columns = max(1, Int((availableWidth + spacing) / (minWidth + spacing)))
        let rows = chunked(Array(data), into: columns)

        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row) { element in
                        content(element)
                            .frame(maxWidth: .infinity)
                    }
                    // Pad the final (possibly short) row so its cells keep the same
                    // width as full rows instead of stretching to fill.
                    if row.count < columns {
                        ForEach(0..<(columns - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Measure the available width behind the content so the column count stays
        // responsive (more columns when the window is wider).
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { availableWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newValue in availableWidth = newValue }
            }
        )
    }

    // Split the elements into rows of `size` (the last row may be short).
    private func chunked(_ items: [Data.Element], into size: Int) -> [[Data.Element]] {
        guard size > 0 else { return items.isEmpty ? [] : [items] }
        return stride(from: 0, to: items.count, by: size).map { start in
            Array(items[start..<min(start + size, items.count)])
        }
    }
}
