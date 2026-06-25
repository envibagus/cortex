import SwiftUI

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
    @AppStorage("summaryBackend") private var summaryBackendRaw = SummaryBackend.claude.rawValue
    // Assistant engine (CLI) + model, shared with ChatService / the composer via these keys.
    @AppStorage("assistantEngine") private var assistantEngineRaw = ChatEngine.claude.rawValue
    @AppStorage("assistantModel") private var assistantModelRaw = ChatModel.sonnet.rawValue

    // Local mirror of the UserDefaults-backed budget so the TextField can edit a
    // draft and commit on submit / blur. Seeded from the model on appear.
    @State private var budgetDraft = ""
    // Local mirror of the editable display name, committed into
    // `model.userNameOverride` on submit / blur. Seeded from the model on appear.
    @State private var nameDraft = ""
    // Tracks the in-flight "Refresh all data" action to disable the button.
    @State private var isRefreshing = false
    // The selected settings tab, persisted so it survives leaving and reopening Settings
    // (and across launches), driven by the Liquid Glass segmented control below.
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
        case budget = "Budget"
        case data = "Data"
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
        .navigationTitle("Settings")
        .frame(minWidth: 520, idealWidth: 600, minHeight: 520)
        .onAppear { syncDraftFromModel(); applyTabHint() }
        .onChange(of: model.settingsTabHint) { _, _ in applyTabHint() }
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
                appearanceSection
                identitySection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        case .menuBar:
            Form {
                menuBarIconSection
                menuBarUsageSection
                menuBarResetSection
                menuBarRefreshSection
                menuBarLiveActivitySection
                menuBarBehaviorSection
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
        case .budget:
            Form {
                budgetSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        case .data:
            Form {
                dataSection
                scanRootsSection
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
            shortcutRow("Back", ["\u{2318}", "["])
            shortcutRow("Forward", ["\u{2318}", "]"])
            shortcutRow("Assistant", ["\u{2318}", "L"])
            shortcutRow("Toggle sidebar", ["\u{2318}", "\\"])
            shortcutRow("New item (Library pages)", ["\u{2318}", "N"])
        } header: {
            Text("Navigation")
        } footer: {
            Text("\u{2318}1 through \u{2318}9 follow the sidebar top to bottom, so they adapt when you pin or hide pages.")
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

    private var appearanceSection: some View {
        Section {
            // Liquid Glass segmented control (matches the rest of the app), bridged to
            // the String-backed @AppStorage key via a typed binding.
            choiceRow("Appearance") {
                GlassSegmentedControl(items: AppAppearance.allCases,
                                      selection: appearanceSelection) { $0.label }
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("System follows your macOS appearance; Light and Dark force a fixed theme.")
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
            Text("The chat Assistant runs on your chosen CLI - only installed engines are selectable. The model applies to Claude Code and can also be changed per-chat in the composer.")
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
            LabeledContent("Backend") {
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
            Text("Claude (Haiku) summarizes via your local Claude Code CLI - cheap and uses your existing login. Apple Intelligence runs on-device (macOS 26, Apple silicon). Off falls back to the raw description.")
                .foregroundStyle(.secondary)
        }
    }

    /// The currently selected backend (typed).
    private var summaryBackend: SummaryBackend {
        SummaryBackend(rawValue: summaryBackendRaw) ?? .claude
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
                Text("Turn a destination off to hide it from the sidebar (everything is shown by default). Use the Pin button to lift a destination into a \u{201C}Pinned\u{201D} group at the top of the sidebar. Home and Settings can't be hidden.")
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
                    .onSubmit(commitName)
            }
            LabeledContent("Login") {
                Text("@\(model.userLogin)")
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Identity")
        } footer: {
            Text("Defaults to your macOS account name. Type to set a custom name, or clear it to fall back to the GitHub CLI name.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Spending budget section
    //
    // A dollar TextField bound to a draft string, committed into
    // `model.monthlyBudget`. Drives the budget alerts shown in Costs and Health.

    private var budgetSection: some View {
        Section {
            // Editable monthly amount: a labelled TextField with a leading $ and
            // a trailing "/ month" suffix, committed on submit.
            LabeledContent("Monthly budget") {
                HStack(spacing: 4) {
                    Text("$").foregroundStyle(.secondary)
                    TextField("0.00", text: $budgetDraft)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 96)
                        .onSubmit(commitBudget)
                    Text("/ month").foregroundStyle(.secondary)
                }
            }

            // Live status row, shown only when a budget is set.
            if let budget = model.monthlyBudget {
                LabeledContent("Status") {
                    Label("Alerting at \(Fmt.money(budget)) per month", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.blue)
                        .labelStyle(.titleAndIcon)
                }
            }

            // Commit + clear controls.
            HStack {
                Button("Set Budget", action: commitBudget)
                    .buttonStyle(.borderedProminent)
                Button("Clear", action: clearBudget)
                    .disabled(model.monthlyBudget == nil)
                Spacer()
            }
        } header: {
            Text("Spending Budget")
        } footer: {
            Text("Sets the monthly spend ceiling. When your 30-day cost approaches or passes it, Cortex raises a budget alert in Costs and Health.")
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
                Text("No scan roots configured. Add a folder to scan for local repositories.")
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
        } header: {
            Text("Scan Roots")
        } footer: {
            Text("Cortex looks for git repositories directly inside these directories.")
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
                } else {
                    Button("Check for Updates") { model.checkForUpdates(manual: true) }
                }
            }
        } header: {
            Text("About")
        } footer: {
            Text("Cortex checks GitHub for a newer release on launch. Updates are installed manually (download and replace) until the app is notarized.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Budget actions

    /// Mirror the persisted budget + display name into their editable drafts.
    private func syncDraftFromModel() {
        if let budget = model.monthlyBudget {
            budgetDraft = String(format: "%.2f", budget)
        } else {
            budgetDraft = ""
        }
        nameDraft = model.userName
    }

    /// Commit the edited display name as the user override (empty clears it).
    private func commitName() {
        model.userNameOverride = nameDraft
        nameDraft = model.userName
    }

    /// Parse the draft, persist it, and recompute stats so alerts react live.
    private func commitBudget() {
        let cleaned = budgetDraft
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty {
            model.monthlyBudget = nil
        } else if let value = Double(cleaned), value > 0 {
            model.monthlyBudget = value
        }
        model.recomputeStats()
        syncDraftFromModel()
    }

    /// Remove the budget entirely and refresh hygiene/alerts.
    private func clearBudget() {
        model.monthlyBudget = nil
        budgetDraft = ""
        model.recomputeStats()
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
            Text("Number shows the percent, Ring draws a progress ring, Bars stacks Session over Weekly. Track picks which limit the number / ring follows.")
                .foregroundStyle(.secondary)
        }
    }

    private var menuBarUsageSection: some View {
        Section {
            choiceRow("Show") {
                GlassSegmentedControl(items: UsageDisplayMode.allCases, selection: usageModeBinding) { $0.label }
            }
        } header: {
            Text("Usage")
        } footer: {
            Text("Glass half full or half empty: read percentages as the amount used or the amount left. Applies to the menu bar, the home card, and the Usage page.")
                .foregroundStyle(.secondary)
        }
    }

    private var menuBarResetSection: some View {
        Section {
            choiceRow("Reset times") {
                GlassSegmentedControl(items: ResetTimerStyle.allCases, selection: resetStyleBinding) { $0.label }
            }
            if model.menuBarResetStyle == .absolute {
                choiceRow("Clock") {
                    GlassSegmentedControl(items: MenuBarTimeFormat.allCases, selection: timeFormatBinding) { $0.label }
                }
            }
        } header: {
            Text("Reset Timers")
        } footer: {
            Text("Relative shows a countdown (\u{201C}Resets in 1h 44m\u{201D}); Absolute shows the clock time (\u{201C}Resets today at 11:04\u{201D}).")
                .foregroundStyle(.secondary)
        }
    }

    private var menuBarRefreshSection: some View {
        Section {
            choiceRow("Auto refresh") {
                GlassSegmentedControl(items: MenuBarRefreshInterval.allCases, selection: refreshIntervalBinding) { $0.label }
            }
        } header: {
            Text("Refresh")
        } footer: {
            Text("How often Cortex re-checks your limits while it is running.")
                .foregroundStyle(.secondary)
        }
    }

    private var menuBarLiveActivitySection: some View {
        Section {
            Toggle("Show live activity", isOn: liveActivityBinding)
            if model.menuBarLiveActivityEnabled {
                Toggle("Play completion sound", isOn: completionSoundBinding)
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
            Text("Shows what Claude Code is doing right now (Editing, Running command, Awaiting permission) with a turn timer. This installs Claude Code hooks in ~/.claude/settings.json - Cortex backs the file up first and removes its entries cleanly when you turn this off. It is the only file Cortex writes; everything else stays read-only.")
                .foregroundStyle(.secondary)
        }
    }

    private var menuBarBehaviorSection: some View {
        Section {
            Toggle("Show in menu bar", isOn: showMenuBarItemBinding)
            Toggle("Launch at login", isOn: launchAtLoginBinding)
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

            if combo != nil && !recording {
                Button { combo = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
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
