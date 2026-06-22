import SwiftUI
import AppKit

// MARK: - ContentView
//
// Two-column shell: a grouped sidebar (Overview / Monitor / Workspace / Config /
// Health) and the routed detail view. The ⌘K command palette overlays the whole
// window.

struct ContentView: View {
    @Environment(AppModel.self) private var model
    // Sidebar column visibility, toggled by ⌘\ (via model.sidebarToggleToken). The
    // system toolbar toggle still drives it too.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        ZStack {
            // First-run onboarding is shown INSTEAD of the main shell (not over it),
            // so the shell's toolbar/header is never mounted during onboarding and the
            // real app header is left exactly as it is.
            if model.hasCompletedOnboarding {
                mainShell
            } else {
                OnboardingView()
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.hasCompletedOnboarding)
    }

    // The main two-column shell plus the ⌘K command palette overlay.
    private var mainShell: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 280)
        } detail: {
            DetailRouter(route: model.route)
                .background(Theme.canvas)
                // NOTE: do NOT add .ignoresSafeArea(.container, edges: .top) here to get a
                // "frosted" header. It pulls content under the macOS title bar, whose drag
                // region then eats clicks on the top-right action buttons (eye/pencil/star)
                // and the bar bleeds whatever window sits behind Cortex. Keep content below
                // the bar so every top control stays clickable.
                // Keep the toolbar title EMPTY: the page name already shows as the list
                // header, so a toolbar title just duplicates it (and the old "Cortex" text
                // is unwanted). The "+" lives in the sidebar toolbar (see SidebarView).
                .navigationTitle("")
                .toolbarTitleDisplayMode(.inline)
                // Keep the unified title bar TRANSLUCENT (the blurred vibrancy) even on
                // pages whose toolbar carries controls (e.g. Costs' window picker), which
                // otherwise rendered an opaque band. SwiftUI-only - does not touch the
                // NSWindow chrome, so the flush sidebar is unaffected.
                .toolbarBackground(.hidden, for: .windowToolbar)
                // New-item creation modal: selecting "New Skill / Agent / Rule / Command"
                // in the sidebar's NewItemMenu sets model.newItemKind, which presents this
                // sheet over the routed page.
                .sheet(item: Binding(
                    get: { model.newItemKind },
                    set: { model.newItemKind = $0 }
                )) { kind in
                    NewItemSheet(kind: kind)
                }
                // One card chrome for the whole app: every native GroupBox in any
                // detail view inherits the same padding / fill / hairline / radius.
                // Views that need a variant (e.g. equal-height grid cards) apply a
                // nearer .groupBoxStyle(_:) that overrides this.
                .groupBoxStyle(CortexGroupBoxStyle())
                // Keep data fresh as you move around: navigating to any page kicks off a
                // stale-guarded refresh (sessions + local repos + config), so each page
                // reflects current disk state without a manual refresh. The 45s throttle
                // inside refreshIfStale means rapid tab-hopping won't re-scan on every click.
                .onChange(of: model.route) { _, _ in
                    Task { await model.refreshIfStale() }
                }
        }
        .overlay {
            if model.showCommandPalette {
                CommandPaletteView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        // Bottom-right transient toast (e.g. "Path copied"), optionally with an action
        // button (e.g. "Undo" after a delete).
        .overlay(alignment: .bottomTrailing) {
            if let toast = model.toast {
                ToastView(text: toast, action: model.toastAction) { model.runToastAction() }
                    .padding(18)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.showCommandPalette)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.toast)
        // Hide only the "Cortex" title text (keeps the standard window style so the
        // sidebar stays flush; the title-bar height itself is unchanged).
        .background(WindowConfigurator())
        // ⌘\ toggles the sidebar column.
        .onChange(of: model.sidebarToggleToken) { _, _ in
            columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
        }
        // Keep the live usage limits fresh while the app is open: re-probe every 5
        // minutes, but only once usage has been loaded at least once (so the first,
        // deferred Keychain prompt still waits until the user opens a usage view).
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if model.usage.hasLoaded { await model.usage.refresh() }
            }
        }
        // Poll running `claude` windows so the Live "active" state + sidebar badge track
        // open windows. Fast (8s) while the Live page is open; slow (30s) elsewhere so we
        // aren't spawning pgrep/lsof every few seconds for just the sidebar badge.
        .task {
            while !Task.isCancelled {
                model.refreshRunningClaude()
                try? await Task.sleep(for: .seconds(model.route == .live ? 8 : 30))
            }
        }
    }
}

// MARK: - Toast
//
// A small transient capsule shown bottom-right (a copied-path confirmation, etc.).

private struct ToastView: View {
    let text: String
    var action: AppModel.ToastAction? = nil
    var onAction: () -> Void = {}

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.green)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)

            // Optional trailing action (e.g. Undo): a divider then a tinted button.
            if let action {
                Rectangle().fill(Theme.stroke).frame(width: 1, height: 14).padding(.horizontal, 2)
                Button(action: onAction) {
                    Text(action.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

// MARK: - Sidebar
//
// Native macOS sidebar: a plain List(.sidebar) with grouped Sections, SF Symbol
// Labels, right-aligned count badges, and the SYSTEM selection highlight +
// vibrancy. The native list is what gives the beautiful macOS 26 look, so there is
// no custom row/material here.

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Single-selection List takes an optional binding; bridge it to model.route.
        let selection = Binding<Route?>(
            get: { model.route },
            set: { if let route = $0 { model.route = route } }
        )

        List(selection: selection) {
            // Pinned: user-curated shortcuts mirrored from their home sections. Shown
            // only when at least one route is pinned AND not hidden (a hidden route
            // shows nowhere, even if it is also pinned).
            let pinned = model.pinnedRouteList.filter { !model.isHidden($0) }
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { route in
                        SidebarRow(route: route, badge: badge(for: route))
                    }
                }
            }

            ForEach(Sidebar.sections) { section in
                // Pinned routes move up into the Pinned group, so drop them from their
                // home section. Showing the same route twice means two rows with the
                // same selection tag, which makes the List flicker when pinning. Hidden
                // routes are dropped entirely (the Settings Show toggle controls this).
                let routes = section.routes.filter { !model.isPinned($0) && !model.isHidden($0) }
                if !routes.isEmpty {
                    Section(section.title) {
                        ForEach(routes) { route in
                            SidebarRow(route: route, badge: badge(for: route))
                        }
                    }
                }
            }

            // Settings in its OWN titled group (not lumped under "Health"): a normal
            // titled Section reads as a distinct group, unlike a bare row (looks like
            // part of Health) or a headerless Section (an oversized empty gap).
            Section("App") {
                SidebarRow(route: .settings, badge: nil)
            }
        }
        .listStyle(.sidebar)
        // No sidebar title (the page name shows as each page's list header).
        .navigationTitle("")
        // If the currently-routed page gets hidden (its Show toggle turned off), fall
        // back to Home so the detail pane never strands on a page with no sidebar row.
        .onChange(of: model.hiddenRoutes) { _, _ in
            if model.isHidden(model.route) { model.route = .readout }
        }
        // The "+" lives in the SIDEBAR toolbar (next to the system sidebar toggle), on
        // every page. It opens the new-item modal (model.newItemKind) and the page-level
        // sheet presents it.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NewItemMenu()
            }
        }
    }

    /// Right-aligned live count for countable destinations (nil hides the badge).
    private func badge(for route: Route) -> Text? {
        // Live shows the number of OPEN Claude windows across your projects (running
        // `claude` processes), not just sessions that wrote recently - so two idle-but-
        // open windows still count. nil when none so the badge hides on a quiet workspace.
        if route == .live {
            let active = model.activeClaudeCount
            return active > 0 ? Text("\(active)") : nil
        }
        let count: Int? = switch route {
        case .sessions: model.sessions.sessions.count
        case .ports: model.ports.ports.count
        case .tools: model.config.mcpServers.count
        case .repos: model.repos.repos.count
        case .skills: model.config.skills.count
        case .agents: model.config.agents.count
        case .rules: model.config.rules.count
        case .commands: model.config.commands.count
        case .plugins: model.config.plugins.count
        case .instructions: model.config.instructions.count
        case .favorites: model.library.favorites.count
        case .collections: model.library.collections.count
        case .memory: model.config.memories.count
        case .hooks: model.config.hooks.count
        default: nil
        }
        guard let count, count > 0 else { return nil }
        return Text("\(count)")
    }
}

// MARK: - Sidebar row
//
// One navigable destination: the native Label + count badge, plus a custom hover
// wash (a stock sidebar only highlights selection, not hover) and a right-click
// context menu to pin / unpin the route. The hover background is suppressed on the
// selected row so it never fights the system selection highlight.

private struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let route: Route
    let badge: Text?
    @State private var hovering = false

    var body: some View {
        let isSelected = model.route == route
        // Match the system selection capsule's geometry (measured from the native blue
        // highlight: ~8pt radius, ~10pt horizontal inset, full row height). The wash
        // fades in/out via opacity so the hover has a subtle transition. The selected
        // row keeps a nil background so the system selection highlight wins.
        let hoverWash = RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.hairFill)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .opacity(hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.13), value: hovering)
        let hoverBackground: AnyView? = isSelected ? nil : AnyView(hoverWash)

        Label(route.title, systemImage: route.icon)
            .badge(badge)
            .tag(route)
            .listRowBackground(hoverBackground)
            .onHover { hovering = $0 }
        // Right-click pin/unpin is hidden for now; pins are managed in Settings → Sidebar.
    }
}

// MARK: - Detail router

struct DetailRouter: View {
    var route: Route

    var body: some View {
        switch route {
        case .readout: ReadoutView()
        case .assistant: AssistantView()
        case .usage: UsageView()
        case .live: LiveView()
        case .sessions: SessionsView()
        case .tools: ToolsView()
        case .costs: CostsView()
        case .ports: PortsView()
        case .repos: ReposView()
        case .workGraph: WorkGraphView()
        case .repoPulse: RepoPulseView()
        case .diffs: DiffsView()
        case .snapshots: SnapshotsView()
        case .skills: SkillsView()
        case .agents: AgentsView()
        case .rules: RulesView()
        case .commands: CommandsView()
        case .plugins: PluginsView()
        case .instructions: InstructionsView()
        case .favorites: FavoritesView()
        case .collections: CollectionsView()
        case .memory: MemoryView()
        case .hooks: HooksView()
        case .settings: SettingsView()
        case .health: HealthView()
        }
    }
}
