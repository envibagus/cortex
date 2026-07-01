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
    /// Glass pills are always interactive controls, so they carry the link cursor.
    @ViewBuilder
    func glassPill() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule()).linkCursor()
        } else {
            self
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                .linkCursor()
        }
    }

    /// The pointing-hand cursor on hover, for clickable controls (macOS 15+ native).
    /// Applied through the shared affordance modifiers (`hoverHighlight`, `glassPill`)
    /// and directly on bespoke buttons / tappable rows so every clickable element in the
    /// app shows the link cursor.
    func linkCursor() -> some View { pointerStyle(.link) }
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

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = item == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) { selection = item }
                } label: {
                    Text(label(item))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        // Publish the selected segment's bounds so ONE thumb can slide to it.
                        .anchorPreference(key: SegmentThumbBounds.self, value: .bounds) {
                            selected ? $0 : nil
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
        .padding(3)
        // A single sliding thumb positioned behind the selected segment, so it physically
        // GLIDES (one view moving + resizing) instead of cross-fading between per-segment
        // backgrounds - the smooth slide the matchedGeometryEffect approach couldn't promise.
        .backgroundPreferenceValue(SegmentThumbBounds.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let rect = proxy[anchor]
                    GlassSegmentThumb()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        // Track: a faint capsule fill + hairline, matching the glass-pill chrome.
        .background(Theme.hairFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

// Carries the selected segment's bounds (in the control's space) up to the single
// sliding thumb behind the row. First non-nil wins (only the selected segment posts).
private struct SegmentThumbBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
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
            // A hover wash means the element is clickable, so it carries the link cursor.
            .linkCursor()
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

// MARK: - Page header (unified title-bar band)
//
// ONE page-title treatment for the whole app. The page name + optional count badge and a
// quiet one-line subtitle render in the window's unified toolbar band via a `.navigation`
// (leading-edge) toolbar item, NOT in the scrolling content, so the band is never an empty
// strip and the title reads a touch larger than the tiny system title - matching the
// Ports/Health pages the app is modelled on. (`.title` placement is iOS-only; on macOS
// `.navigation` items sit at the toolbar's leading edge, exactly where the system title
// would go.) Page controls (refresh, search, filters) go in `.primaryAction`. A soft
// macOS 26 scroll-edge blur frosts the band as content scrolls beneath it.

/// The custom title placed at the toolbar's leading edge: a slightly-larger bold page name
/// with an optional count badge, over a one-line secondary subtitle. Sized to sit inside the
/// unified toolbar band without clipping.
struct CortexToolbarTitle: View {
    let title: String
    var count: Int? = nil
    var subtitle: String? = nil
    /// When true the subtitle shows inline under the title (Costs keeps its blurb visible);
    /// otherwise the band stays compact (title + count only) and the subtitle is surfaced as
    /// a hover tooltip on the title.
    var subtitleInline: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                // Page name: a proper page heading, a few points over the ~13pt system title.
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                // Count badge (e.g. "27" on Ports): a quiet pill next to the title, so the
                // number rides with the heading instead of the description line.
                if let count {
                    Text(Fmt.grouped(count))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.hairFill))
                        .fixedSize()
                }
            }
            if subtitleInline, let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        // Line the title up with the page content's leading inset, not the toolbar edge.
        .padding(.leading, Theme.titleLeadingInset)
        // Subtitle-on-hover: when it isn't shown inline, reveal it as a tooltip.
        .help(subtitleInline ? "" : (subtitle ?? ""))
    }
}

extension View {
    /// Standard page chrome with trailing toolbar actions: a larger title (+ optional count
    /// badge + subtitle) placed in the toolbar band, plus the page's own `.primaryAction`
    /// controls. `navigationTitle` stays set for the accessibility / window-menu label; the
    /// `.title` toolbar item overrides only its VISUAL rendering.
    func cortexPageChrome<A: ToolbarContent>(
        _ title: String,
        subtitle: String? = nil,
        count: Int? = nil,
        subtitleInline: Bool = false,
        @ToolbarContentBuilder actions: () -> A
    ) -> some View {
        cortexTitleBand(title, subtitle: subtitle, count: count, subtitleInline: subtitleInline)
            .toolbar { actions() }
    }

    /// Standard page chrome with no trailing actions.
    func cortexPageChrome(_ title: String, subtitle: String? = nil, count: Int? = nil, subtitleInline: Bool = false) -> some View {
        cortexTitleBand(title, subtitle: subtitle, count: count, subtitleInline: subtitleInline)
    }

    /// The leading page title in the band. On macOS 26 its Liquid Glass "shared background"
    /// is hidden so the title reads as plain text on the band (same color as the content), not
    /// a tinted capsule "bubble"; older macOS draws no such background, so it's used as-is.
    @ViewBuilder
    fileprivate func cortexTitleBand(_ title: String, subtitle: String?, count: Int?, subtitleInline: Bool) -> some View {
        if #available(macOS 26.0, *) {
            toolbar {
                ToolbarItem(placement: .navigation) {
                    CortexToolbarTitle(title: title, count: count, subtitle: subtitle, subtitleInline: subtitleInline)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        } else {
            toolbar {
                ToolbarItem(placement: .navigation) {
                    CortexToolbarTitle(title: title, count: count, subtitle: subtitle, subtitleInline: subtitleInline)
                }
            }
        }
    }

    /// macOS 26 soft scroll-edge blur (Liquid Glass) at the top edge, so the toolbar band
    /// frosts as content scrolls beneath it. No-op before macOS 26.
    @ViewBuilder func cortexScrollEdge() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

// MARK: - Page scaffold
//
// Standard padded scroll container for most feature views. The title/subtitle/count live in
// the toolbar band (via `.cortexPageChrome`), NOT in the content, so the page starts flush
// under the band with no empty strip; `toolbar` is the page's trailing control (usually a
// refresh) and rides in the band's trailing edge.

struct PageScaffold<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    var count: Int? = nil
    var toolbar: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .padding(.horizontal, Theme.pageHInset)
            .padding(.top, Theme.pageTopInset)
            .padding(.bottom, Theme.pageHInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        .cortexScrollEdge()
        .cortexPageChrome(title, subtitle: subtitle, count: count) {
            if let toolbar {
                ToolbarItem(placement: .primaryAction) { toolbar }
            }
        }
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
                // Cap the line length so a long message wraps to a readable column instead
                // of stretching edge-to-edge across a wide pane.
                .frame(maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
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
    // Optional provenance (origin) filter: only the config browsers pass it, and the
    // pill only appears when more than one origin is present (so Agents/Commands, which
    // never come from plugins, never show it).
    var origin: Binding<String?>? = nil
    var origins: [String] = []
    // ⌘F focuses this field (via model.focusSearchToken).
    @FocusState private var searchFocused: Bool

    private var hasScopeFilter: Bool { scopes.count > 1 }
    private var hasOriginFilter: Bool { origin != nil && origins.count > 1 }

    var body: some View {
        if hasScopeFilter || hasOriginFilter {
            // With a scope/origin filter: search on its own row, then a filter row of
            // [scope | origin | sort] (each pill shown only when it applies).
            VStack(alignment: .leading, spacing: 9) {
                searchField
                LiquidGlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        if hasScopeFilter {
                            ScopeFilterButton(scope: $scope, scopes: scopes)
                        }
                        if hasOriginFilter, let origin {
                            OriginFilterButton(origin: origin, origins: origins)
                        }
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
struct SortFilterButton<Sort: FilterSortOption>: View {
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

// MARK: - Multi-select filter pill
//
// A glass pill showing a facet title (+ a count badge when active) that opens a
// searchable, scrollable checklist popover. Multiple values can be checked; the
// popover stays open across toggles and dismisses on click-away. Matches the scope /
// sort pill chrome. Used by the Home "By project" tables (one per facet).

struct MultiSelectFilterButton: View {
    let title: String
    let options: [String]
    @Binding var selected: Set<String>
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                if !selected.isEmpty {
                    Text("\(selected.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent.opacity(0.16)))
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(selected.isEmpty ? Theme.textSecondary : Theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: FilterControl.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassPill()
        .help(selected.isEmpty ? "Filter by \(title.lowercased())" : "\(selected.count) \(title.lowercased()) selected")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            MultiSelectPopover(title: title, options: options, selected: $selected)
        }
    }
}

// The checklist popover: a search field over a scrollable, live-filtered list of
// checkboxes, plus a Clear action. Scales to 100s of values (search + scroll).
private struct MultiSelectPopover: View {
    let title: String
    let options: [String]
    @Binding var selected: Set<String>
    @State private var query = ""
    @FocusState private var focused: Bool

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? options : options.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search + clear.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                TextField("Filter \(title.lowercased())", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focused)
                if !selected.isEmpty {
                    Button { selected.removeAll() } label: {
                        Text("Clear").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().overlay(Theme.stroke)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if filtered.isEmpty {
                        Text("No matches")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    ForEach(filtered, id: \.self) { option in
                        row(option)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 260)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } }
    }

    // One row: the genuine macOS checkbox (Toggle, system .checkbox style) shown for its
    // state but with hit-testing disabled, so the ENTIRE row is one button that toggles
    // membership. Toggling does not dismiss, so several can be picked.
    private func row(_ option: String) -> some View {
        let isOn = selected.contains(option)
        return Button {
            if isOn { selected.remove(option) } else { selected.insert(option) }
        } label: {
            HStack(spacing: 0) {
                Toggle(isOn: .constant(isOn)) {
                    Text(option).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                }
                .toggleStyle(.checkbox)
                .allowsHitTesting(false)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }
}

// One shared height for the filter-row controls (search field, scope pill, sort pill)
// so they all line up exactly.
enum FilterControl { static let height: CGFloat = 36 }

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

// MARK: - Origin (provenance) filter
//
// Sentinel labels for the provenance filter, shared by the config browser (which
// builds the origins list + filters on it) and the popover (which picks row icons):
// "Yours" = authored by you (not shipped inside a plugin), "Any plugin" = from any
// installed plugin/marketplace, and any other value is a specific plugin name.

enum OriginFilter {
    static let mine = "Yours"
    static let anyPlugin = "Any plugin"
}

// The origin pill: an ICON-ONLY compact control (origins can be long plugin names, so the
// pill shows just the glyph of the current selection + a chevron; the label lives in the
// popover and in a hover tooltip). Opens the same searchable popover (All origins / Yours /
// Any plugin / each plugin by name).
private struct OriginFilterButton: View {
    @Binding var origin: String?
    let origins: [String]
    @State private var open = false

    // Glyph reflecting the CURRENT selection.
    private var icon: String {
        switch origin {
        case .none: "square.grid.2x2"
        case OriginFilter.mine: "person.crop.circle"
        case OriginFilter.anyPlugin: "puzzlepiece.extension"
        default: "puzzlepiece"
        }
    }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: FilterControl.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassPill()
        .help(origin ?? "All origins")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            OriginPopover(origin: $origin, origins: origins) { open = false }
        }
    }
}

// The origin popover: a search field over a live-filtered list of provenance values.
// Picking one applies it and dismisses. Mirrors ScopePopover's styling.
private struct OriginPopover: View {
    @Binding var origin: String?
    let origins: [String]
    let dismiss: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? origins : origins.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    // Icon per provenance row: yours, any-plugin, or a specific plugin.
    private func icon(for value: String) -> String {
        switch value {
        case OriginFilter.mine: "person.crop.circle"
        case OriginFilter.anyPlugin: "puzzlepiece.extension"
        default: "puzzlepiece"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                TextField("Filter origins", text: $query)
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
                    originRow(label: "All origins", icon: "square.grid.2x2", value: nil)
                    ForEach(filtered, id: \.self) { value in
                        originRow(label: value, icon: icon(for: value), value: value)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 260)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } }
    }

    private func originRow(label: String, icon: String, value: String?) -> some View {
        let selected = origin == value
        return Button {
            origin = value
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
