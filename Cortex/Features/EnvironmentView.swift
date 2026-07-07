import SwiftUI
import AppKit

// MARK: - EnvironmentView
//
// The developer command-line tools installed on this machine (model.environment). The
// left pane is a search + filter/sort bar over a grouped, non-collapsible List; the right
// pane shows the selected tool's details (an optional on-device AI summary, path, install
// source, version, upgrade command, raw version output). Grouping and order follow the
// chosen sort (by category, name, or install source). The scan is lazy: `.task` runs it
// the first time the page appears.

// MARK: Sort

/// Row order within the (always category-grouped) list. "Last used" ranks by the most
/// recent shell-history invocation; "Name" is alphabetical.
enum EnvSort: String, CaseIterable, Identifiable, FilterSortOption {
    case name
    case lastUsed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .lastUsed: "Last used"
        }
    }

    var icon: String {
        switch self {
        case .name: "textformat"
        case .lastUsed: "clock.arrow.circlepath"
        }
    }
}

struct EnvironmentView: View {
    @Environment(AppModel.self) private var model

    // Selected tool id (a binary name).
    @State private var selectedID: String?
    // Search across name / version / path (bound to the toolbar search field).
    @State private var query = ""
    // Row order within category sections.
    @State private var sort: EnvSort = .name
    // Install-source filter (nil = all sources), single-select like the app's scope filter.
    @State private var sourceFilter: String? = nil
    // ⌘F focuses the search field.
    @FocusState private var searchFocused: Bool
    // Set when a row is CLICKED, so the selection observer skips its auto-scroll for that
    // change (a click already reveals the row; only external selections should scroll).
    @State private var suppressScrollOnce = false

    var body: some View {
        content
            .cortexScrollEdge()
            .cortexPageChrome("Environment", subtitle: subtitleText,
                              count: model.environment.hasLoaded ? model.environment.presentCount : nil)
            // Search lives in the toolbar (like the Ports page), NOT in the pane, so it's part of
            // the window chrome and can never be covered or dragged under the band by an empty list.
            .searchable(text: $query, prompt: "Search tools")
            .searchFocused($searchFocused)
            .onChange(of: model.focusSearchToken) { _, _ in searchFocused = true }
            .toolbar {
                if !sourceOptions.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        ScopeFilterButton(scope: $sourceFilter, scopes: sourceOptions,
                                          allLabel: "All sources", prompt: "Filter sources",
                                          rowIcon: Self.sourceIcon)
                            .frame(width: 150)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    SortFilterButton(sort: $sort)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.environment.load(force: true) }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.environment.isLoading)
                }
            }
            // Lazy first scan; load() no-ops once it has run.
            .task { await model.environment.load() }
    }

    // MARK: Subtitle (counts + last scan)

    private var subtitleText: String {
        guard model.environment.hasLoaded else { return "Detecting installed command-line tools" }
        var parts = ["\(model.environment.presentCount) tools detected"]
        let extra = model.environment.uncatalogued.count
        if extra > 0 { parts.append("\(extra) more on PATH") }
        if let scan = model.environment.lastScan { parts.append("scanned \(Fmt.relative(scan))") }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Body content (loading / split)

    @ViewBuilder
    private var content: some View {
        if model.environment.isLoading && model.environment.tools.isEmpty {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Scanning Your Toolchain")
                    .font(.headline)
                Text("Resolving installed command-line tools and reading their versions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        } else {
            split
        }
    }

    // MARK: Master list + detail

    private var split: some View {
        // Build the grouped list inline so search results are current on every keystroke. The
        // sort uses precomputed lowercased keys (cheap), and the List diffs rows by id, so a
        // selection change only re-renders the two affected rows - not a re-filter of the list.
        let sections = computeSections()
        let visibleIDs = Set(sections.flatMap { $0.tools.map(\.id) })
        let firstID = sections.first?.tools.first?.id
        return HStack(spacing: 0) {
            // Left: JUST the tools list (or the empty state when nothing matches). Search + the
            // Source/Sort filters live in the toolbar (like the Ports page), so there is no in-pane
            // header that could be covered or shoved under the band - matching the rest of the app.
            Group {
                if sections.isEmpty {
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        ContentUnavailableView("No matching tools", systemImage: "wrench.and.screwdriver",
                                               description: Text(sourceFilter.map { "No installed tools from \($0)." }
                                                                 ?? "No tools to show."))
                    }
                } else {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(sections) { section in
                                Section {
                                    ForEach(section.tools) { tool in
                                        EnvSplitRow(isSelected: tool.id == selectedID,
                                                    onSelect: {
                                                        // A click already reveals the row; skip the
                                                        // observer's auto-scroll so the list doesn't lurch.
                                                        if selectedID != tool.id { suppressScrollOnce = true }
                                                        selectedID = tool.id
                                                    }) {
                                            EnvToolRow(tool: tool)
                                        }
                                        .listRowInsets(EdgeInsets(top: 1, leading: Theme.splitListRowInset,
                                                                  bottom: 1, trailing: Theme.splitListRowInset))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                        .id(tool.id)
                                    }
                                } header: {
                                    if !section.title.isEmpty {
                                        EnvSectionHeader(icon: section.icon, title: section.title,
                                                         count: section.tools.count)
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .onChange(of: selectedID) { _, id in
                            guard let id else { return }
                            // Only auto-scroll for EXTERNAL selection changes; a click set the flag.
                            if suppressScrollOnce { suppressScrollOnce = false; return }
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            }
            .frame(width: 320)
            .background(Theme.canvas)

            Divider().overlay(Theme.stroke)

            // Right: detail of the selected tool, or an empty state.
            Group {
                if let tool = selectedTool {
                    EnvironmentDetail(tool: tool)
                } else {
                    CortexEmptyState(icon: "wrench.and.screwdriver",
                                     title: "No tool selected",
                                     message: "Pick a tool on the left to see its path, version, and install source.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        }
        // Keep the selection valid as the visible set changes (scan, search, filter): keep a
        // still-visible selection, otherwise fall to the first visible tool (nil when none).
        .onChange(of: visibleIDs) { _, ids in
            if let sel = selectedID, ids.contains(sel) { return }
            selectedID = firstID
        }
        .onAppear { if selectedID == nil { selectedID = firstID } }
    }

    // MARK: Filtering + grouping

    /// Distinct install sources present in the scan, in canonical order (drives the Source
    /// filter's options).
    private var sourceOptions: [String] {
        let installed = model.environment.tools.filter(\.present) + model.environment.uncatalogued
        let labels = Set(installed.map { $0.source.label })
        return ToolInstallSource.displayOrder.map(\.label).filter { labels.contains($0) }
    }

    /// SF Symbol for an install-source label (used by the Source filter's rows).
    private static func sourceIcon(_ label: String) -> String {
        ToolInstallSource.displayOrder.first { $0.label == label }?.icon ?? "shippingbox"
    }

    /// Build the category-grouped, filtered, sorted sections. The sort uses a precomputed
    /// lowercased key: a locale-aware compare per element is too slow across hundreds of tools.
    private func computeSections() -> [EnvSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func matchSource(_ t: DetectedTool) -> Bool {
            sourceFilter == nil || t.source.label == sourceFilter
        }
        func matchSearch(_ t: DetectedTool) -> Bool {
            guard !q.isEmpty else { return true }
            return t.displayName.lowercased().contains(q)
                || t.name.lowercased().contains(q)
                || (t.version?.lowercased().contains(q) ?? false)
                || (t.path?.lowercased().contains(q) ?? false)
        }
        // Installed tools only (catalogued present + uncatalogued), passing source + search.
        let tools = (model.environment.tools.filter(\.present) + model.environment.uncatalogued)
            .filter { matchSource($0) && matchSearch($0) }
        let rank = model.environment.lastUsed

        var out: [EnvSection] = []
        for category in ToolCategory.allCases {
            let inCategory = tools.filter { $0.category == category }
            guard !inCategory.isEmpty else { continue }
            // Sort keyed pairs so each name is lowercased once, not per comparison.
            let keyed = inCategory.map { (tool: $0, key: $0.displayName.lowercased()) }
            let ordered: [DetectedTool]
            switch sort {
            case .name:
                ordered = keyed.sorted { $0.key < $1.key }.map(\.tool)
            case .lastUsed:
                ordered = keyed.sorted {
                    let ra = rank[$0.tool.name] ?? -1, rb = rank[$1.tool.name] ?? -1
                    return ra != rb ? ra > rb : $0.key < $1.key
                }.map(\.tool)
            }
            out.append(EnvSection(id: category.rawValue, title: category.title,
                                  icon: category.icon, tools: ordered))
        }
        return out
    }

    private var selectedTool: DetectedTool? {
        guard let id = selectedID else { return nil }
        return model.environment.tools.first { $0.id == id }
            ?? model.environment.uncatalogued.first { $0.id == id }
    }
}

// A grouped section for the master list.
private struct EnvSection: Identifiable {
    let id: String
    let title: String
    let icon: String
    let tools: [DetectedTool]
}

// MARK: - Section header
//
// A quiet category / source header for the master list: an SF Symbol, the title, and a
// count. Non-collapsible (plain List sections), matching the flat grouped look.

private struct EnvSectionHeader: View {
    let icon: String
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Split list row (custom inset selection)
//
// A clickable master-list row whose rounded selection highlight is inset by the page
// padding on both sides (the split panes' selection chrome). Click selects into the
// shared binding; the enclosing List scrolls.

private struct EnvSplitRow<Content: View>: View {
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
                        .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor)
                                         : (hovering ? Theme.hairFill : .clear))
                )
                .contentShape(Rectangle())
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Tool row
//
// One tool in the master list: a status dot, its display name, and its version (right-
// aligned mono). Absent tools read dimmed; uncatalogued versions appear once probed.

private struct EnvToolRow: View {
    let tool: DetectedTool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.green)
                .frame(width: 7, height: 7)
            Text(tool.displayName)
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let version = tool.version {
                Text(version)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Tool detail
//
// The selected tool's dashboard: category, title, version, install source, an optional
// on-device AI summary, the description, an upgrade command, and the raw version output.
// For uncatalogued tools the version is probed and the summary generated on selection.

private struct EnvironmentDetail: View {
    @Environment(AppModel.self) private var model
    let tool: DetectedTool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                aiSummary
                if let blurb = tool.blurb, !blurb.isEmpty {
                    Text(blurb)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if tool.present { metadataCard }
                if let upgrade = tool.upgrade, !upgrade.isEmpty, tool.present {
                    commandCard(title: "Upgrade", command: upgrade)
                }
                if let raw = tool.rawVersion, !raw.isEmpty {
                    rawVersionCard(raw)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.pageHInset)
            .padding(.top, Theme.pageTopInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // On selection: read an uncatalogued tool's version, and generate the on-device
        // one-line summary (both no-op when already done / unavailable).
        .task(id: tool.id) {
            // Debounce: only probe an uncatalogued tool's version and kick off its on-device
            // summary once the selection settles, so fast navigation or typing in search
            // doesn't spawn a subprocess + model inference for every item passed through.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            model.environment.probeVersion(forID: tool.id)
            model.summaries.ensureToolSummary(for: tool)
        }
    }

    // Title, category, and the version (on its own line, above the source badge).
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: tool.category.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(tool.category.title)
                    .font(.cortexCaption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(tool.displayName)
                .font(.cortexTitle)
                .foregroundStyle(Theme.textPrimary)
            if tool.present {
                Text(tool.version ?? "installed")
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                Pill(text: tool.source.label, tint: Theme.blue)
            } else {
                Text("Not installed")
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // On-device (Apple Intelligence) one-line summary of what the tool does. Shown only
    // when a summary backend is enabled; a placeholder while it generates.
    // On-device (Apple Intelligence) one-line summary, shown SILENTLY once ready - matching
    // the library summaries in SkillsView (summary-or-nothing, no in-flight spinner), so
    // searching / selecting / clearing never reads as "loading". The catalog blurb stays
    // visible as the fallback while a summary generates in the background.
    @ViewBuilder
    private var aiSummary: some View {
        if let summary = model.summaries.toolSummary(for: tool) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.blue)
                Text(summary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help("Summarized on-device by Apple Intelligence")
        }
    }

    // Path, install source, and the underlying binary name.
    private var metadataCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                if let path = tool.displayPath {
                    detailRow(label: "Path", value: path, copy: tool.path)
                    Divider().overlay(Theme.stroke).padding(.vertical, 10)
                }
                detailRow(label: "Source", value: tool.source.label)
                Divider().overlay(Theme.stroke).padding(.vertical, 10)
                detailRow(label: "Command", value: tool.name, copy: tool.name)
            }
        }
    }

    // A copyable command (the upgrade hint).
    private func commandCard(title: String, command: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.cortexCaption)
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    Text(command)
                        .font(.cortexMono)
                        .foregroundStyle(Theme.codeText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.copyPath(command) } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy command")
                }
                .padding(10)
                .background(Theme.codeFill, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            }
        }
    }

    // The exact first line the tool's version command printed.
    private func rawVersionCard(_ raw: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Version output")
                    .font(.cortexCaption)
                    .foregroundStyle(Theme.textSecondary)
                Text(raw)
                    .font(.cortexMono)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.codeFill, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            }
        }
    }

    // A label/value row with an optional copy button (and Reveal in Finder for paths).
    private func detailRow(label: String, value: String, copy: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.cortexMono)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let copy {
                if label == "Path", let full = tool.path {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                }
                Button { model.copyPath(copy) } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Copy")
            }
        }
    }
}
