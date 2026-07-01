import SwiftUI
import AVFoundation

// MARK: - SettingsView
//
// Native macOS System Settings pane. Built as a single `Form` with
// `.formStyle(.grouped)` so it reads exactly like a stock Settings window:
// grouped sections, native pickers, LabeledContent key/value rows, and a real
// TextField for the budget. Used in two places at once: the `.settings` sidebar
// route inside the main window AND the dedicated macOS Settings scene.
//
// It reads live identity, lets the user set a monthly spending budget (which
// powers the budget alerts in Costs and Health), refresh all data on demand,
// and inspect the scan roots and last-scan timestamps. It also exposes the app
// appearance (System / Light / Dark). Native semantic colors throughout, so it
// adapts to light + dark automatically.

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    // Persisted appearance preference shared with the app entry. Default mirrors
    // the dark-first entry default so the control reads correctly on first launch.
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.dark.rawValue

    // Persisted AI-summary backend (Claude CLI / Apple Intelligence / Off), read by
    // SummaryService via the same key. Defaults to Claude (this app targets Claude Code).
    @AppStorage("summaryBackend") private var summaryBackendRaw = SummaryBackend.apple.rawValue
    // Assistant engine (CLI) + model, shared with ChatService / the composer via these keys.
    @AppStorage("assistantEngine") private var assistantEngineRaw = ChatEngine.claude.rawValue
    @AppStorage("assistantModel") private var assistantModelRaw = ChatModel.sonnet.rawValue

    // Local mirror of the editable display name, committed into
    // `model.userNameOverride` on submit / blur. Seeded from the model on appear.
    @State private var nameDraft = ""
    // Tracks focus on the name field so the edit commits when focus leaves (clicking
    // away), not only on Return. Without this, typing a new name and clicking elsewhere
    // silently discarded it - it read as "the name can't be changed".
    @FocusState private var nameFieldFocused: Bool
    // Tracks the in-flight "Refresh all data" action to disable the button.
    @State private var isRefreshing = false
    // Retains the AVAudioPlayer while a completion-sound preview plays in Settings.
    @State private var soundPreviewPlayer: AVAudioPlayer?
    // The selected settings tab, driven by the Liquid Glass segmented control below. Opening
    // Settings always starts on General (in-app button / cmd-,) unless a hint deep-links a
    // specific tab (the menu bar opens straight to Menu Bar) - see `applyInitialTab()`. Stored
    // so the control has a stable backing value; the initial tab is decided on each open.
    @AppStorage("settingsSelectedTab") private var selectedTabRaw = SettingsTab.general.rawValue
    private var selectedTab: SettingsTab { SettingsTab(rawValue: selectedTabRaw) ?? .general }
    private var selectedTabBinding: Binding<SettingsTab> {
        Binding(get: { SettingsTab(rawValue: selectedTabRaw) ?? .general },
                set: { selectedTabRaw = $0.rawValue })
    }

    // The functional settings tabs, each a grouped Form pane below the glass selector.
    enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
        case general = "General"
        case menuBar = "Menu Bar"
        case ai = "AI"
        case sidebar = "Sidebar"
        case setup = "Setup"
        case shortcuts = "Shortcuts"
        case about = "About"
        var id: String { rawValue }
        var title: String { rawValue }
    }

    var body: some View {
        // Functional tabs, like a standard macOS settings window, but driven by the
        // app's Liquid Glass segmented control instead of native TabView chrome. The
        // selector sits centered near the top; the selected pane's grouped Form shows
        // below it (General / Sidebar / Budget / Data / About).
        VStack(spacing: 0) {
            // Centered glass tab selector.
            GlassSegmentedControl(items: SettingsTab.allCases, selection: selectedTabBinding) { $0.title }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 18)
                .padding(.bottom, 12)

            // Selected pane: each its own grouped Form, matching the stock Settings look.
            selectedPane
        }
        // Match the app's canvas so the Settings background reads identically to the
        // rest of the app (the grouped section cards still sit on top).
        .background(Theme.canvas)
        .cortexScrollEdge()
        .cortexPageChrome("Settings")
        .frame(minWidth: 520, idealWidth: 600, minHeight: 520)
        .onAppear { syncDraftFromModel(); applyInitialTab() }
        // A hint set WHILE Settings is already open (menu bar re-triggers) deep-links its tab.
        // Ignore the nil that `applyTabHint` writes when it clears the hint, so it doesn't
        // bounce an applied Menu Bar selection back to General.
        .onChange(of: model.settingsTabHint) { _, hint in
            if hint != nil { applyTabHint() }
        }
        // Esc leaves Settings: go back to the previous page (or Home if there's no history).
        .onExitCommand {
            if model.canGoBack { model.goBack() } else { model.route = .readout }
        }
    }

    /// The grouped Form for the active tab. Each pane keeps its existing sections and
    /// the `.formStyle(.grouped)` / hidden-background chrome from the old TabView panes.
    @ViewBuilder
    private var selectedPane: some View {
        switch selectedTab {
        case .general:
            Form {
                generalSection
                identitySection
                dataSection
                scanRootsSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        case .menuBar:
            Form {
                menuBarBehaviorSection
                menuBarIconSection
                menuBarUsageSection
                menuBarLiveActivitySection
                menuBarCompletionSoundSection
                menuBarShortcutSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        case .ai:
            Form {
                assistantSection
                summariesSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        case .sidebar:
            Form {
                sidebarSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        case .setup:
            Form {
                EnvironmentSection()
                DiscoveredCountsSection()
                CoreToolsSection()
                AIToolsSection()
                WhatCortexReadsSection()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        case .shortcuts:
            Form {
                shortcutsNavSection
                shortcutsGlobalSection
                shortcutsPaletteSection
                shortcutsEditorSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        case .about:
            Form {
                aboutSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Keyboard shortcuts (reference)
    //
    // A read-only reference of every shortcut the app responds to, grouped by where it
    // applies. Each row pairs a plain-language action with its key caps. Update this
    // when shortcuts change (see the keyboard-shortcuts plan in memory for planned adds).

    private var shortcutsNavSection: some View {
        Section {
            shortcutRow("Jump to a sidebar page", ["\u{2318}", "1-9"])
            shortcutRow("Move selection (sidebar or list)", ["\u{2191}", "\u{2193}"])
            shortcutRow("Switch focus between sidebar and list", ["\u{21E5}"])
            shortcutRow("Back", ["\u{2318}", "["])
            shortcutRow("Forward", ["\u{2318}", "]"])
            shortcutRow("Assistant", ["\u{2318}", "L"])
            shortcutRow("Toggle sidebar", ["\u{2318}", "B"])
            shortcutRow("New item (Library pages)", ["\u{2318}", "N"])
        } header: {
            Text("Navigation")
        } footer: {
            Text("\u{2318}1 through \u{2318}9 follow the sidebar top to bottom, so they adapt when you pin or hide pages. \u{2318}\\ also toggles the sidebar.")
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutsGlobalSection: some View {
        Section {
            shortcutRow("Command palette", ["\u{2318}", "K"])
            shortcutRow("Find (focus the page's search)", ["\u{2318}", "F"])
            shortcutRow("Refresh all data", ["\u{2318}", "R"])
            shortcutRow("Rescan the current page", ["\u{2318}", "\u{21E7}", "R"])
            shortcutRow("Settings", ["\u{2318}", ","])
        } header: {
            Text("Global")
        } footer: {
            Text("Work anywhere in the app.").foregroundStyle(.secondary)
        }
    }

    private var shortcutsPaletteSection: some View {
        Section {
            shortcutRow("Move selection", ["\u{2191}", "\u{2193}"])
            shortcutRow("Open selection", ["\u{21A9}"])
            shortcutRow("Dismiss", ["esc"])
        } header: {
            Text("Command Palette (\u{2318}K)")
        }
    }

    private var shortcutsEditorSection: some View {
        Section {
            shortcutRow("Save changes", ["\u{2318}", "S"])
            shortcutRow("Cancel editing", ["esc"])
        } header: {
            Text("Markdown Editor")
        } footer: {
            Text("When editing a skill, agent, rule, or command.").foregroundStyle(.secondary)
        }
    }

    /// One shortcut row: a plain-language action label with its key caps on the right.
    private func shortcutRow(_ label: String, _ keys: [String]) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.hairFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Theme.stroke, lineWidth: 1)
                        )
                }
            }
        }
    }

    // MARK: - Appearance section
    //
    // System / Light / Dark, bound directly to the @AppStorage("appearance") key
    // the app entry reads, so flipping it instantly re-applies preferredColorScheme.

    private var generalSection: some View {
        Section {
            // Liquid Glass segmented control (matches the rest of the app), bridged to
            // the String-backed @AppStorage key via a typed binding.
            choiceRow("Appearance") {
                GlassSegmentedControl(items: AppAppearance.allCases,
                                      selection: appearanceSelection) { $0.label }
            }
            // Launch at login lives here (an app-level preference), not under Menu Bar.
            Toggle("Launch at login", isOn: launchAtLoginBinding)
        } header: {
            Text("General")
        } footer: {
            Text("System follows macOS; Light and Dark force a theme.")
                .foregroundStyle(.secondary)
        }
    }

    /// Bridge the String-backed @AppStorage("appearance") key to a typed binding so
    /// the glass segmented control can drive it directly.
    private var appearanceSelection: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceRaw) ?? .dark },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    // MARK: - Assistant section (engine + model)
    //
    // The chat Assistant's backing CLI and model. Only installed CLIs can be selected;
    // the model applies to Claude Code (and is also switchable per-chat in the composer).

    private var assistantSection: some View {
        Section {
            // Engine: a menu of every CLI, with uninstalled ones disabled + labeled.
            LabeledContent("Engine") {
                Menu {
                    ForEach(ChatEngine.allCases) { e in
                        Button {
                            model.chat.engine = e
                            assistantEngineRaw = e.rawValue
                        } label: {
                            if e == assistantEngine {
                                Label(e.label, systemImage: "checkmark")
                            } else {
                                Text(e.isInstalled ? e.label : "\(e.label) (not installed)")
                            }
                        }
                        .disabled(!e.isInstalled)
                    }
                } label: {
                    Text(assistantEngine.label)
                }
                .fixedSize()
            }

            // Model (Claude models): also switchable per-chat in the composer.
            LabeledContent("Model") {
                Menu {
                    ForEach(ChatModel.allCases) { m in
                        Button {
                            model.chat.model = m
                            assistantModelRaw = m.rawValue
                        } label: {
                            if m == assistantModel {
                                Label("\(m.label) \u{2013} \(m.blurb)", systemImage: "checkmark")
                            } else {
                                Text("\(m.label) \u{2013} \(m.blurb)")
                            }
                        }
                    }
                } label: {
                    Text(assistantModel.label)
                }
                .fixedSize()
            }
        } header: {
            Text("Assistant")
        } footer: {
            Text("Only installed engines are selectable. The model can also be changed per chat.")
                .foregroundStyle(.secondary)
        }
    }

    private var assistantEngine: ChatEngine {
        // Migrate the retired "gemini" preference to its Antigravity successor.
        let raw = assistantEngineRaw == "gemini" ? ChatEngine.antigravity.rawValue : assistantEngineRaw
        return ChatEngine(rawValue: raw) ?? .claude
    }
    private var assistantModel: ChatModel { ChatModel(rawValue: assistantModelRaw) ?? .sonnet }

    // MARK: - AI summaries section
    //
    // Chooses the engine that writes the short agent subtitles + session summaries:
    // the local Claude Code CLI (Haiku), Apple's on-device model, or Off. Exposed so an
    // open-source user can pick whichever they have set up.

    private var summariesSection: some View {
        Section {
            // Right-floated pop-up, identical to the Engine / Model rows above so the
            // whole AI tab uses ONE control style.
            LabeledContent("Summarize with") {
                Menu {
                    ForEach(SummaryBackend.allCases) { b in
                        Button {
                            summaryBackendRaw = b.rawValue
                        } label: {
                            if b == summaryBackend {
                                Label(b.label, systemImage: "checkmark")
                            } else {
                                Text(b.label)
                            }
                        }
                    }
                } label: {
                    Text(summaryBackend.label)
                }
                .fixedSize()
            }

            // Availability hint for the active choice, so a missing CLI / model is obvious.
            if !model.summaries.isAvailable && summaryBackend != .off {
                Label(unavailableHint, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Theme.orange)
                    .labelStyle(.titleAndIcon)
            }
        } header: {
            Text("AI Summaries")
        } footer: {
            Text("Writes the short agent and session summaries. Apple Intelligence runs on-device; Off uses the raw description.")
                .foregroundStyle(.secondary)
        }
    }

    /// The currently selected backend (typed).
    private var summaryBackend: SummaryBackend {
        SummaryBackend(rawValue: summaryBackendRaw) ?? .apple
    }

    /// Why the active backend can't generate, so the user knows what to fix.
    private var unavailableHint: String {
        switch summaryBackend {
        case .claude: "The `claude` CLI wasn't found. Install Claude Code to enable summaries."
        case .apple: "Apple Intelligence isn't available (needs macOS 26 on Apple silicon, enabled in Settings)."
        case .off: ""
        }
    }

    // MARK: - Sidebar section (show / hide + pin management)
    //
    // Each destination row carries two independent controls: a "Pinned" button that
    // pins the route to the top "Pinned" group (mirrors model.pinnedRoutes), and a
    // Show toggle that decides whether the route appears in the sidebar at all (mirrors
    // model.hiddenRoutes). Everything is shown by default; a couple of routes (Home /
    // Settings) can never be hidden so the app stays navigable, and their Show toggle
    // is forced on + disabled.

    private var sidebarSection: some View {
        Group {
            Section {
                Text("Hide destinations, or pin them to a group at the top. Home and Settings always stay.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(Sidebar.sections) { section in
                Section(section.title) {
                    ForEach(section.routes) { route in
                        sidebarRow(route)
                    }
                }
            }
        }
    }

    /// One destination row: [icon + name] ... [Pin button] [Show toggle]. The Pin
    /// button sits BEFORE the toggle and reflects/flips the route's pin state; the
    /// toggle shows/hides the route (forced on + disabled when it can't be hidden).
    @ViewBuilder
    private func sidebarRow(_ route: Route) -> some View {
        let pinned = model.isPinned(route)
        let canHide = model.canHide(route)
        LabeledContent {
            HStack(spacing: 10) {
                // Pin / Pinned button (before the toggle): filled star when pinned.
                Button {
                    model.togglePin(route)
                } label: {
                    Label(pinned ? "Pinned" : "Pin", systemImage: pinned ? "pin.fill" : "pin")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .linkCursor()
                .tint(pinned ? Theme.accent : nil)
                .help(pinned ? "Unpin from the top of the sidebar" : "Pin to the top of the sidebar")

                // Show toggle: hides/shows the route. Forced on + disabled for routes
                // that must always stay reachable (Home / Settings).
                Toggle("Show in sidebar", isOn: showBinding(route))
                    .labelsHidden()
                    .disabled(!canHide)
            }
        } label: {
            Label(route.title, systemImage: route.icon)
        }
    }

    /// Two-way binding between a route's Show state and a Settings toggle. Reads
    /// model.isShown (true by default); toggling off hides the route, on shows it.
    /// Always-shown routes report true and ignore writes (the toggle is also disabled).
    private func showBinding(_ route: Route) -> Binding<Bool> {
        Binding(
            get: { model.isShown(route) },
            set: { isOn in
                if isOn != model.isShown(route) { model.toggleHidden(route) }
            }
        )
    }

    // MARK: - Identity section
    //
    // Editable display name (defaults to the macOS account name, refined from `gh`)
    // plus the read-only GitHub login resolved at bootstrap.

    private var identitySection: some View {
        Section {
            // Editable display name. Empty commits clear the override and fall back
            // to the macOS account name + gh-resolved name.
            LabeledContent("Name") {
                TextField("Your name", text: $nameDraft)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 200)
                    .focused($nameFieldFocused)
                    .onSubmit(commitName)
                    // Commit on focus loss too, so clicking away saves the edit.
                    .onChange(of: nameFieldFocused) { _, focused in
                        if !focused { commitName() }
                    }
            }
            LabeledContent("Login") {
                Text("@\(model.userLogin)")
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Identity")
        } footer: {
            Text("Defaults to your macOS account name; clear to reset.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Data section
    //
    // Manual full refresh plus the last-scan timestamps for sessions, ports, repos.

    private var dataSection: some View {
        Section {
            // Refresh control.
            HStack {
                Button(action: refreshAll) {
                    Label(
                        isRefreshing ? "Refreshing\u{2026}" : "Refresh All Data",
                        systemImage: "arrow.clockwise"
                    )
                }
                .linkCursor()
                .disabled(isRefreshing)
                if isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            // Last-scan timestamps as native key/value rows.
            scanRow("Sessions", date: model.sessions.lastScan, busy: model.sessions.isLoading)
            scanRow("Ports", date: model.ports.lastScan, busy: model.ports.isLoading)
            scanRow("Repos", date: model.repos.lastScan, busy: model.repos.isLoading)
        } header: {
            Text("Data")
        } footer: {
            Text("Rescans sessions, ports, config, and local repositories.")
                .foregroundStyle(.secondary)
        }
    }

    /// One "what / when last scanned" LabeledContent row used inside the Data section.
    @ViewBuilder
    private func scanRow(_ label: String, date: Date?, busy: Bool) -> some View {
        LabeledContent(label) {
            if busy {
                Text("scanning\u{2026}").foregroundStyle(.blue)
            } else {
                Text(date == nil ? "never" : "scanned \(Fmt.relative(date))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Scan roots section
    //
    // Editable list of the directories scanned for local git repositories and
    // project-level AI config. Add via a native open panel, remove with the trailing
    // button; each change persists and triggers a workspace rescan.

    private var scanRootsSection: some View {
        Section {
            if model.scanRoots.isEmpty {
                Text("No directories added yet. Add a folder that holds your projects and Cortex will scan it for git repositories.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.scanRoots, id: \.self) { root in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(root.tildeAbbreviated)
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button(role: .destructive) {
                                removeScanRoot(root)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .linkCursor()
                            .help("Remove this scan root")
                        }
                    } label: {
                        Label("Folder", systemImage: "folder")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }

            // Add-folder control opening a native directory picker.
            Button(action: addScanRoot) {
                Label("Add Folder\u{2026}", systemImage: "plus")
            }
            .linkCursor()
        } header: {
            Text("Scanned Directories")
        } footer: {
            Text("Folders Cortex scans for git repositories, one level deep. Repos found here appear in Repos, Work Graph, and Diffs.")
                .foregroundStyle(.secondary)
        }
    }

    /// Open a native directory picker and add any newly chosen folders.
    private func addScanRoot() {
        let chosen = NSOpenPanel.chooseDirectories(
            message: "Choose folders that contain your git repositories.")
        guard !chosen.isEmpty else { return }
        Task { await model.addScanRoots(chosen) }
    }

    /// Remove a scan root (the model persists and rescans).
    private func removeScanRoot(_ root: String) {
        Task { await model.removeScanRoot(root) }
    }

    // MARK: - About section
    //
    // App identity and build target.

    private var aboutSection: some View {
        Section {
            LabeledContent("Application", value: "Cortex")
            LabeledContent("Version", value: model.updates.currentVersion)
            LabeledContent("Built for", value: model.userName)
            LabeledContent("Updates") {
                if model.updates.isChecking {
                    ProgressView().controlSize(.small)
                } else if model.updates.updateAvailable, let url = model.updates.releaseURL {
                    Button("Download \(model.updates.latestTag ?? "update")") { NSWorkspace.shared.open(url) }
                        .linkCursor()
                } else {
                    Button("Check for Updates") { model.checkForUpdates(manual: true) }
                        .linkCursor()
                }
            }
        } header: {
            Text("About")
        } footer: {
            Text("Checks GitHub for updates on launch. Install manually (download and replace).")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Budget actions

    /// Mirror the persisted display name into its editable draft.
    private func syncDraftFromModel() {
        nameDraft = model.userName
    }

    /// Commit the edited display name as the user override (empty clears it).
    private func commitName() {
        model.userNameOverride = nameDraft
        nameDraft = model.userName
    }

    // MARK: - Data actions

    private func refreshAll() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await model.refreshAll()
            isRefreshing = false
        }
    }

    // MARK: - Menu Bar tab
    //
    // Mirrors the menu-bar preferences on AppModel through the same glass segmented
    // controls / toggles the rest of Settings uses. Live activity is the one switch that
    // writes outside Cortex (it installs Claude Code hooks), so its footer says so.

    /// Decide the tab on each open: a hint (e.g. the menu bar deep-links Menu Bar) wins,
    /// otherwise always start on General so the in-app button / cmd-, entry is predictable
    /// rather than reopening whatever tab was last viewed.
    private func applyInitialTab() {
        if model.settingsTabHint != nil { applyTabHint() }
        else { selectedTabRaw = SettingsTab.general.rawValue }
    }

    /// Land on a specific tab when Settings is opened with a hint (clears the hint).
    private func applyTabHint() {
        guard let raw = model.settingsTabHint, let tab = SettingsTab(rawValue: raw) else { return }
        selectedTabRaw = tab.rawValue
        model.settingsTabHint = nil
    }

    /// A native-Form row with the label vertically centered against a taller trailing
    /// control (used by the Appearance row). `LabeledContent` baseline-aligns a short
    /// label to the top of a tall control, which reads as off-center; an HStack centers it.
    private func choiceRow<Control: View>(_ title: String, @ViewBuilder _ control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            control()
        }
    }

    private var menuBarIconSection: some View {
        Section {
            choiceRow("Icon") {
                GlassSegmentedControl(items: MenuBarIconMode.allCases, selection: iconModeBinding) { $0.label }
            }
            choiceRow("Track") {
                GlassSegmentedControl(items: UsageWindow.allCases, selection: primaryWindowBinding) { $0.label }
            }
        } header: {
            Text("Menu Bar Icon")
        } footer: {
            Text("Pick the icon style and which limit it tracks.")
                .foregroundStyle(.secondary)
        }
    }

    // One "Usage" group for everything about the usage readout: how percentages read,
    // whether spend shows, how reset timers display, and how often limits re-check. Kept
    // together so the Menu Bar tab isn't a long stack of one-row cards.
    private var menuBarUsageSection: some View {
        Section {
            choiceRow("Show") {
                GlassSegmentedControl(items: UsageDisplayMode.allCases, selection: usageModeBinding) { $0.label }
            }
            Toggle("Show spend in panel", isOn: showSpendBinding)
            choiceRow("Reset times") {
                GlassSegmentedControl(items: ResetTimerStyle.allCases, selection: resetStyleBinding) { $0.label }
            }
            if model.menuBarResetStyle == .absolute {
                choiceRow("Clock") {
                    GlassSegmentedControl(items: MenuBarTimeFormat.allCases, selection: timeFormatBinding) { $0.label }
                }
            }
            choiceRow("Auto refresh") {
                GlassSegmentedControl(items: MenuBarRefreshInterval.allCases, selection: refreshIntervalBinding) { $0.label }
            }
        } header: {
            Text("Usage")
        } footer: {
            Text("Show percentages as used or left. Reset times show a countdown or a clock time. Auto refresh sets how often limits re-check.")
                .foregroundStyle(.secondary)
        }
    }

    private var menuBarLiveActivitySection: some View {
        Section {
            Toggle("Show live activity", isOn: liveActivityBinding)
            // Confetti only fires while live activity is on, so the toggle is only relevant then.
            if model.menuBarLiveActivityEnabled {
                Toggle("Show confetti when a turn finishes", isOn: confettiBinding)
            }
            if let error = model.activity.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Theme.orange)
                    .labelStyle(.titleAndIcon)
            }
        } header: {
            Text("Live Activity")
        } footer: {
            Text("Shows running sessions and a turn timer in the menu bar. Installs Claude Code hooks in ~/.claude/settings.json (backed up first, removed cleanly when off) - the only file Cortex writes.")
                .foregroundStyle(.secondary)
        }
    }

    // Completion sound stands on its own: it can be on even when the live-activity display is
    // off (both share the same turn-detection hooks under the hood).
    private var menuBarCompletionSoundSection: some View {
        Section {
            Toggle("Play completion sound", isOn: completionSoundBinding)
            if model.menuBarCompletionSound {
                LabeledContent("Sound") {
                    HStack(spacing: 8) {
                        // Small play button to preview the chosen sound on demand.
                        Button {
                            previewCompletionSound(model.menuBarCompletionSoundName)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Preview sound")

                        Picker("", selection: completionSoundNameBinding) {
                            ForEach(Self.completionSoundPacks, id: \.file) { pack in
                                Text(pack.label).tag(pack.file)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                // Also preview the moment the selection changes, so picking is audible.
                .onChange(of: model.menuBarCompletionSoundName) { _, name in
                    previewCompletionSound(name)
                }
            }
        } header: {
            Text("Completion Sound")
        } footer: {
            Text("Chimes when a turn finishes, even with live activity off. Quick turns stay silent. Uses the same hooks as live activity.")
                .foregroundStyle(.secondary)
        }
    }

    private var menuBarBehaviorSection: some View {
        Section {
            Toggle("Show in menu bar", isOn: showMenuBarItemBinding)
        } header: {
            Text("Behavior")
        } footer: {
            Text("The dock icon and the main window stay available either way.")
                .foregroundStyle(.secondary)
        }
    }

    private var menuBarShortcutSection: some View {
        Section {
            LabeledContent("Open panel") {
                HotKeyRecorder(combo: hotKeyBinding)
            }
        } header: {
            Text("Global Shortcut")
        } footer: {
            Text("Pop the panel open from anywhere. Click, then press your shortcut (it needs a modifier). Press Escape while recording to clear it.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Menu-bar bindings (bridge model properties to typed controls)

    private var iconModeBinding: Binding<MenuBarIconMode> {
        Binding(get: { model.menuBarIconMode }, set: { model.menuBarIconMode = $0 })
    }
    private var primaryWindowBinding: Binding<UsageWindow> {
        Binding(get: { model.menuBarPrimaryWindow }, set: { model.menuBarPrimaryWindow = $0 })
    }
    private var usageModeBinding: Binding<UsageDisplayMode> {
        Binding(get: { model.menuBarUsageMode }, set: { model.menuBarUsageMode = $0 })
    }
    private var resetStyleBinding: Binding<ResetTimerStyle> {
        Binding(get: { model.menuBarResetStyle }, set: { model.menuBarResetStyle = $0 })
    }
    private var timeFormatBinding: Binding<MenuBarTimeFormat> {
        Binding(get: { model.menuBarTimeFormat }, set: { model.menuBarTimeFormat = $0 })
    }
    private var refreshIntervalBinding: Binding<MenuBarRefreshInterval> {
        Binding(get: { model.menuBarRefreshInterval }, set: { model.menuBarRefreshInterval = $0 })
    }
    private var liveActivityBinding: Binding<Bool> {
        Binding(get: { model.menuBarLiveActivityEnabled }, set: { model.setLiveActivity($0) })
    }
    private var completionSoundBinding: Binding<Bool> {
        Binding(get: { model.menuBarCompletionSound }, set: { model.menuBarCompletionSound = $0 })
    }
    private var confettiBinding: Binding<Bool> {
        Binding(get: { model.menuBarConfetti }, set: { model.menuBarConfetti = $0 })
    }
    private var completionSoundNameBinding: Binding<String> {
        Binding(get: { model.menuBarCompletionSoundName }, set: { model.menuBarCompletionSoundName = $0 })
    }

    // The nine completion-sound packs (bundled hero-complete-<file>.caf), by friendly name.
    private static let completionSoundPacks: [(file: String, label: String)] = [
        ("hero-complete-soft", "Soft"),
        ("hero-complete-aero", "Aero"),
        ("hero-complete-arcade", "Arcade"),
        ("hero-complete-organic", "Organic"),
        ("hero-complete-glass", "Glass"),
        ("hero-complete-industrial", "Industrial"),
        ("hero-complete-minimal", "Minimal"),
        ("hero-complete-retro", "Retro"),
        ("hero-complete-crisp", "Crisp"),
    ]

    /// Preview a completion sound when the user picks it, so the choice is audible at once.
    private func previewCompletionSound(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.prepareToPlay()
        player.play()
        soundPreviewPlayer = player
    }
    private var showSpendBinding: Binding<Bool> {
        Binding(get: { model.menuBarShowSpend }, set: { model.menuBarShowSpend = $0 })
    }
    private var showMenuBarItemBinding: Binding<Bool> {
        Binding(get: { model.showMenuBarItem }, set: { model.showMenuBarItem = $0 })
    }
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { model.menuBarLaunchAtLogin }, set: { model.menuBarLaunchAtLogin = $0 })
    }
    private var hotKeyBinding: Binding<HotKeyCombo?> {
        Binding(get: { model.menuBarHotKey }, set: { model.menuBarHotKey = $0 })
    }
}

// MARK: - Hot-key recorder
//
// A small capture control: click to record, then the next modifier+key press becomes the
// global shortcut. While recording, a local key monitor swallows the event so it doesn't
// type. Escape clears the binding. Shows the current combo as "⌘⌥U".

private struct HotKeyRecorder: View {
    @Binding var combo: HotKeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press keys\u{2026}" : (combo?.displayString ?? "Click to set"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(recording ? Theme.accent : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(minWidth: 96)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.hairFill))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(recording ? Theme.accent : Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .linkCursor()

            if combo != nil && !recording {
                Button { combo = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .linkCursor()
                .help("Clear shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape clears + stops
                combo = nil; stop(); return nil
            }
            if let recorded = HotKeyCombo(event: event) {
                combo = recorded; stop()
            }
            return nil // swallow the key while recording so it never types
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Setup pane sections (the Setup tab, moved here from the Health page)
//
// Environment + discovered counts + tooling checklists describing what Cortex found
// on disk. Read-only diagnostics, so they belong in Settings rather than the Health
// dashboard. All read live from AppModel + `Shell.which`.

// MARK: - Environment section
//
// Pass/fail tooling checks describing the discovered environment. Each row is a
// LabeledContent with a green check / gray x glyph, a label, and a detail value.

private struct EnvironmentSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let repos = model.repos

        Section {
            // Claude CLI availability (true pass/fail)
            CheckRow(
                label: "Claude CLI available",
                detail: model.chat.isAvailable ? "Ready" : "Not found",
                passed: model.chat.isAvailable
            )
            // GitHub authentication (true pass/fail)
            CheckRow(
                label: "GitHub authenticated",
                detail: repos.userLogin.isEmpty ? "Signed out" : "@\(repos.userLogin)",
                passed: !repos.userLogin.isEmpty
            )
        } header: {
            Text("Environment")
        } footer: {
            Text("Core tooling Cortex relies on to read your stack.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Discovered counts section
//
// Live counts of each config surface, as pass/fail check rows (passed == at
// least one discovered). Mirrors the discovery side of the old environment card.

private struct DiscoveredCountsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let config = model.config
        let repoCount = model.repos.repos.count
        let skillCount = config.skills.count
        let agentCount = config.agents.count
        let mcpCount = config.mcpServers.count
        let hookCount = config.hooks.count
        let memoryCount = config.memories.count
        let portCount = model.ports.ports.count

        Section {
            CheckRow(label: "Local repos", detail: "\(repoCount)", passed: repoCount > 0)
            CheckRow(label: "Skills", detail: "\(skillCount)", passed: skillCount > 0)
            CheckRow(label: "Agents", detail: "\(agentCount)", passed: agentCount > 0)
            CheckRow(label: "MCP servers", detail: "\(mcpCount)", passed: mcpCount > 0)
            CheckRow(label: "Hooks", detail: "\(hookCount)", passed: hookCount > 0)
            CheckRow(label: "Memory files", detail: "\(memoryCount)", passed: memoryCount > 0)
            CheckRow(label: "Listening ports", detail: "\(portCount)", passed: portCount > 0)
        } header: {
            Text("Discovered")
        } footer: {
            Text("What Cortex found on disk and across your running processes.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - One environment / counts check row
//
// A native LabeledContent: status glyph + label on the left, the detail value on
// the right. Green check when passed, gray x when not.

private struct CheckRow: View {
    let label: String
    let detail: String
    let passed: Bool

    var body: some View {
        LabeledContent {
            Text(detail)
                .font(passed ? .body.monospaced() : .body)
                .foregroundStyle(passed ? .secondary : .tertiary)
        } label: {
            Label {
                Text(label).foregroundStyle(.primary)
            } icon: {
                Image(systemName: passed ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(passed ? .primary : .secondary)
            }
        }
    }
}

// MARK: - Core tools section
//
// The essential tooling Cortex drives: the Claude CLI (powers the Assistant), gh
// (GitHub repos + identity), git (local repo signals), and lsof (port scanning).
// Each is a native LabeledContent checklist row resolved live from the model and
// `Shell.which`.

private struct CoreToolsSection: View {
    @Environment(AppModel.self) private var model

    private var coreChecks: [SetupCheck] {
        // Claude CLI: availability is owned by ChatService; show its resolved path.
        let claudePath = Shell.which("claude")?.path
        let claudeOK = model.chat.isAvailable
        let claude = SetupCheck(
            title: "Claude Code CLI",
            isReady: claudeOK,
            detail: claudeOK ? (claudePath ?? "Resolved on PATH") : nil,
            note: "Not found. Install from claude.ai/download to power the Assistant."
        )

        // gh: treat an empty userLogin as unauthenticated even when the binary exists.
        let ghPath = Shell.which("gh")?.path
        let ghAuthed = !model.repos.userLogin.isEmpty
        let gh = SetupCheck(
            title: "GitHub CLI (gh)",
            isReady: ghPath != nil && ghAuthed,
            detail: (ghPath != nil && ghAuthed) ? "Authenticated as @\(model.repos.userLogin)" : nil,
            note: ghPath == nil
                ? "Not found. Install with: brew install gh"
                : "Found, but not authenticated. Run: gh auth login"
        )

        // git: a pure binary presence check.
        let gitPath = Shell.which("git")?.path
        let git = SetupCheck(
            title: "git",
            isReady: gitPath != nil,
            detail: gitPath,
            note: "Not found. Install the Xcode command-line tools: xcode-select --install"
        )

        // lsof: powers the Ports view.
        let lsofPath = Shell.which("lsof")?.path
        let lsof = SetupCheck(
            title: "lsof",
            isReady: lsofPath != nil,
            detail: lsofPath,
            note: "Not found. lsof ships with macOS; check your PATH if this is empty."
        )

        return [claude, gh, git, lsof]
    }

    var body: some View {
        let checks = coreChecks
        Section {
            ForEach(checks) { check in
                ChecklistRow(check: check)
            }
        } header: {
            Text("Core Tools")
        } footer: {
            Text("\(checks.filter(\.isReady).count) of \(checks.count) ready. These power the Assistant, GitHub, local repo signals, and the Ports view.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - AI tools section
//
// Scans the home folder for each known AI coding tool's config directory and
// reports which are present. Detection maps a `ToolKind` to its conventional
// dot-directory (e.g. ~/.claude, ~/.codex, ~/.cursor). Presence is honest: a row
// is "ready" only when the directory actually exists on disk.

private struct AIToolsSection: View {
    // Conventional home config directory for each tool we can detect.
    private static let configDirs: [(kind: ToolKind, dir: String)] = [
        (.claude, ".claude"),
        (.codex, ".codex"),
        (.cursor, ".cursor"),
        (.windsurf, ".windsurf"),
        (.copilot, ".copilot"),
        (.amp, ".amp"),
        (.opencode, ".opencode"),
        (.antigravity, ".gemini"),
    ]

    // Resolve presence for each tool against the user's home directory.
    private var aiChecks: [SetupCheck] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        return Self.configDirs.map { entry in
            let path = home.appendingPathComponent(entry.dir).path
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            return SetupCheck(
                title: entry.kind.displayName,
                isReady: exists,
                detail: exists ? "~/\(entry.dir)" : nil,
                note: "No config directory at ~/\(entry.dir)."
            )
        }
    }

    var body: some View {
        let checks = aiChecks
        Section {
            ForEach(checks) { check in
                ChecklistRow(check: check)
            }
        } header: {
            Text("AI Tools Detected")
        } footer: {
            Text("\(checks.filter(\.isReady).count) of \(checks.count) configured. Cortex is built around Claude Code and notes the other tools it finds.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - What Cortex reads section
//
// A short, honest explainer of the on-disk locations Cortex reads from as native
// LabeledContent rows. No credentials are ever read: only structural config and
// transcripts.

private struct WhatCortexReadsSection: View {
    @Environment(AppModel.self) private var model

    // Each line: a label and the path / source it describes. The local-repos source
    // reflects the user's configured scan roots (or a Settings hint when none are set).
    private var readsLines: [(label: String, source: String)] {
        let roots = model.scanRoots
        let reposSource = roots.isEmpty
            ? "Configure scan roots in Settings"
            : roots.map(\.tildeAbbreviated).joined(separator: ", ")
        return [
            ("Sessions & transcripts", "~/.claude/projects/**/*.jsonl"),
            ("Skills, agents, commands, rules", "~/.claude/skills, agents, commands, rules"),
            ("MCP servers & hooks", "~/.claude.json, ~/.claude/settings.json"),
            ("Memory files", "~/.claude/memory"),
            ("Local repos", reposSource),
            ("Listening ports", "lsof -iTCP -sTCP:LISTEN"),
        ]
    }

    var body: some View {
        Section {
            ForEach(readsLines, id: \.label) { line in
                LabeledContent(line.label) {
                    Text(line.source)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } header: {
            Text("What Cortex Reads")
        } footer: {
            Text("Everything is read locally and read-only. Cortex never reads credentials or tokens, and never sends your data anywhere.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Checklist row
//
// A single native check row: the title as the LabeledContent label with the
// resolved path / fix note underneath in secondary text, and a trailing status
// indicator (green checkmark.circle.fill when ready, gray xmark.circle otherwise).

private struct ChecklistRow: View {
    let check: SetupCheck

    var body: some View {
        LabeledContent {
            // Trailing status glyph: a "ready" check in the app's success accent
            // (Theme.green resolves to blue in the orange/blue palette), gray x otherwise.
            Image(systemName: check.isReady ? "checkmark.circle" : "xmark.circle")
                .font(.title3)
                .foregroundStyle(check.isReady ? Theme.green : Color.secondary)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(check.title)
                Text(check.isReady ? (check.detail ?? "Ready") : check.note)
                    .font(check.isReady ? .caption.monospaced() : .caption)
                    .foregroundStyle(check.isReady ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Setup check model
//
// A single resolved checklist entry. `detail` shows when ready (usually a path);
// `note` shows the fix instruction when not.

private struct SetupCheck: Identifiable {
    let id = UUID()
    let title: String
    let isReady: Bool
    let detail: String?
    let note: String
}
