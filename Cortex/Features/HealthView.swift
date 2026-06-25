import SwiftUI

// MARK: - HealthView (consolidated health + setup control center)
//
// One tabbed page that merges the old Health and Setup views into a single,
// most-important-first surface. A centered Liquid Glass segmented control (the
// app-wide tab idiom, same as SettingsView) switches between three panes:
//
//   1. Overview  - two big scores at the very top (a Health score and a Security
//      score, each 0-100 with a ring + grade and its top drag-down factors),
//      followed by a prioritized, actionable Suggestions list.
//   2. Issues    - the full HygieneEngine issue list grouped by severity, as
//      native grouped-Form Sections that deep-link into the relevant view.
//   3. Setup     - the Environment + Discovered counts (from the old Health view)
//      plus the Core Tools / AI Tools / What Cortex Reads checklist (moved over
//      from the now-removed SetupView).
//
// Everything reads live from AppModel; there is no mock data. Scores are derived
// from real signals (hygiene issues, dirty/behind repos, CLAUDE.md coverage, the
// spend budget, MCP auth gaps, shell-running hooks) using the rubric documented
// on HealthScore / SecurityScore below. Native semantic colors + system text
// styles throughout, so it adapts to light + dark.

struct HealthView: View {
    @Environment(AppModel.self) private var model

    // The selected pane, driven by the glass segmented control below.
    @State private var tab: HealthTab = .overview

    // The page's three panes, important-first.
    enum HealthTab: String, CaseIterable, Identifiable, Hashable {
        case overview = "Overview"
        case issues = "Issues"
        case setup = "Setup"
        var id: String { rawValue }
        var title: String { rawValue }
    }

    var body: some View {
        // Centered glass tab selector over the active pane, matching the app's
        // SettingsView layout (selector near the top, pane fills below).
        VStack(spacing: 0) {
            // Glass tab selector.
            GlassSegmentedControl(items: HealthTab.allCases, selection: $tab) { $0.title }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 18)
                .padding(.bottom, 12)

            // The active pane.
            selectedPane
        }
        .background(Theme.canvas)
        .navigationTitle("Health")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HealthRefreshButton()
            }
        }
    }

    /// The view for the active tab. Overview is a scrolling card layout (scores +
    /// suggestions); Issues and Setup are grouped Forms matching the stock Settings
    /// look, with their scroll background hidden so the canvas shows through.
    @ViewBuilder
    private var selectedPane: some View {
        switch tab {
        case .overview:
            OverviewPane()
        case .issues:
            Form {
                StatusSummarySection()
                IssuesSections()
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
        }
    }
}

// MARK: - Toolbar refresh button
//
// Re-runs the full data load so every health signal reflects current disk state.

private struct HealthRefreshButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            Task { await model.refreshAll() }
        } label: {
            Label("Re-scan", systemImage: "arrow.clockwise")
        }
        .help("Re-scan the stack")
    }
}

// MARK: - Overview pane (scores + suggestions)
//
// The most-important-first landing tab: the two scores side by side at the very
// top, then a prioritized list of actionable suggestions. Laid out as a scrolling
// VStack of cards (the ReadoutView idiom), so it reads as the dark-aesthetic
// dashboard rather than a settings form.

private struct OverviewPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Two scores, side by side: Health first (most important), then Security.
                let health = HealthScore(model: model)
                let security = SecurityScore(model: model)

                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        ScoreCard(score: health)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        ScoreCard(score: security)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                // Prioritized, actionable suggestions (reuses hygiene action text).
                SuggestionsCard()
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }
}

// MARK: - Score rubric
//
// A computed score is 0-100 with a one-word grade and a short, ranked list of the
// factors dragging it down. Both scores start at 100 and subtract weighted
// penalties from live model state. The factors list surfaces the biggest
// contributors so the Overview can explain "why" without re-deriving anything.

/// One penalty applied to a score: a human-readable reason and the points it cost.
private struct ScoreFactor: Identifiable {
    let id = UUID()
    let reason: String
    let points: Int
}

/// Shared shape of a computed score so a single ScoreCard renders either one.
private protocol ScoreModel {
    var title: String { get }
    var icon: String { get }
    var value: Int { get }          // 0...100
    var factors: [ScoreFactor] { get } // ranked, biggest penalty first
}

extension ScoreModel {
    /// One-word grade from the numeric score.
    var grade: String {
        switch value {
        case 90...100: "Great"
        case 75..<90:  "Good"
        case 50..<75:  "Fair"
        default:       "Poor"
        }
    }

    /// Ring + number tint. Blue when healthy, orange once it slips (the app's only
    /// two accents; we never introduce a third color like red/green).
    var tint: Color { value >= 75 ? Theme.blue : Theme.orange }
}

// MARK: - Health score
//
// Rubric (start 100, clamp to 0...100):
//   - Each hygiene WARNING:        -8  (heavier than info)
//   - Each hygiene INFO/notice:    -3
//   - Dirtiest repo >= 8 uncommitted files:  -10 (a large uncommitted pile)
//   - Each repo behind remote:     -4 (capped at 3 repos => max -12)
//   - Missing CLAUDE.md coverage:  up to -15, scaled by the share of scanned
//     repos that have no CLAUDE.md (full penalty when none have one)
//   - No spending budget set:      -6 (no cost guardrail)
// The factors list keeps the largest non-zero contributors, ranked.

private struct HealthScore: ScoreModel {
    let value: Int
    let factors: [ScoreFactor]
    let title = "Health"
    let icon = "heart.text.square"

    @MainActor
    init(model: AppModel) {
        var penalties: [ScoreFactor] = []

        // Hygiene issues, weighting warnings over notices.
        let warnings = model.hygiene.warnings
        let critical = model.hygiene.critical
        let notices = max(0, model.hygiene.issues.count - warnings - critical)
        // Criticals (none today) count as warnings for scoring purposes.
        let warningLike = warnings + critical
        if warningLike > 0 {
            penalties.append(ScoreFactor(
                reason: "\(warningLike) warning\(warningLike == 1 ? "" : "s") to resolve",
                points: warningLike * 8))
        }
        if notices > 0 {
            penalties.append(ScoreFactor(
                reason: "\(notices) notice\(notices == 1 ? "" : "s") worth a look",
                points: notices * 3))
        }

        // Dirtiest working tree (matches the hygiene >= 8 threshold).
        let repos = model.repos.repos
        if let dirtiest = repos.max(by: { $0.uncommittedFiles < $1.uncommittedFiles }),
           dirtiest.uncommittedFiles >= 8 {
            penalties.append(ScoreFactor(
                reason: "\(dirtiest.name) has \(dirtiest.uncommittedFiles) uncommitted files",
                points: 10))
        }

        // Repos behind their remote (capped at 3, mirroring the hygiene rule).
        let behind = repos.filter { $0.behind > 0 }.count
        if behind > 0 {
            let counted = min(behind, 3)
            penalties.append(ScoreFactor(
                reason: "\(behind) repo\(behind == 1 ? "" : "s") behind remote",
                points: counted * 4))
        }

        // CLAUDE.md coverage across scanned repos (scaled penalty, max 15).
        if !repos.isEmpty {
            let missing = repos.filter { !$0.hasClaudeMd }.count
            if missing > 0 {
                let share = Double(missing) / Double(repos.count)
                let pts = Int((share * 15).rounded())
                if pts > 0 {
                    penalties.append(ScoreFactor(
                        reason: "\(missing) project\(missing == 1 ? "" : "s") without CLAUDE.md",
                        points: pts))
                }
            }
        }

        // No spending budget configured (a cost guardrail is missing).
        if model.monthlyBudget == nil {
            penalties.append(ScoreFactor(reason: "No spending budget set", points: 6))
        }

        let total = penalties.reduce(0) { $0 + $1.points }
        self.value = max(0, min(100, 100 - total))
        self.factors = penalties.sorted { $0.points > $1.points }
    }
}

// MARK: - Security score
//
// Rubric (start 100, clamp to 0...100). Reads only data already in the model; it
// does NOT scan for secrets or do anything heavy:
//   - Each MCP server that needs auth but isn't configured (MCPServer.needsAuth):
//     -10 each. An unconfigured-auth server can fail open or expose a connection.
//   - Many hooks running shell commands (arbitrary command execution): hooks run
//     unattended, so 4+ shell hooks => -2 per hook beyond the first 3 (capped -20).
//   - No budget alerts (runaway cost is a security/financial risk): -8 when no
//     monthly budget is set.
// The factors list keeps the largest non-zero contributors, ranked.

private struct SecurityScore: ScoreModel {
    let value: Int
    let factors: [ScoreFactor]
    let title = "Security"
    let icon = "lock.shield"

    @MainActor
    init(model: AppModel) {
        var penalties: [ScoreFactor] = []

        // MCP servers that need auth but aren't configured for it.
        let needsAuth = model.config.mcpServers.filter { $0.needsAuth }.count
        if needsAuth > 0 {
            penalties.append(ScoreFactor(
                reason: "\(needsAuth) MCP server\(needsAuth == 1 ? "" : "s") need auth",
                points: needsAuth * 10))
        }

        // Hooks that execute shell commands (arbitrary command execution surface).
        let shellHooks = model.config.hooks.filter { !$0.command.isEmpty }.count
        if shellHooks > 3 {
            let extra = shellHooks - 3
            let pts = min(20, extra * 2)
            penalties.append(ScoreFactor(
                reason: "\(shellHooks) hooks run shell commands",
                points: pts))
        }

        // No budget alerts: runaway cost goes unnoticed.
        if model.monthlyBudget == nil {
            penalties.append(ScoreFactor(reason: "No budget alerts configured", points: 8))
        }

        let total = penalties.reduce(0) { $0 + $1.points }
        self.value = max(0, min(100, 100 - total))
        self.factors = penalties.sorted { $0.points > $1.points }
    }
}

// MARK: - Score card
//
// A prominent score: a trimmed Circle ring around the big number + grade on the
// left, the title above it, and the top 2-3 drag-down factors listed on the
// right. When nothing is dragging the score down, a single "all clear" line shows.

private struct ScoreCard: View {
    let score: any ScoreModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                // Title row.
                HStack(spacing: 8) {
                    Image(systemName: score.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(score.tint)
                    Text(score.title)
                        .font(.cortexHeadline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(score.grade)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(score.tint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(score.tint.opacity(0.14)))
                }

                // Ring + number, then the ranked factors below it.
                HStack(alignment: .center, spacing: 18) {
                    ScoreRing(value: score.value, tint: score.tint)
                    factorList
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Top 2-3 factors dragging the score down (most points first), or an all-clear
    /// line when the score is unblemished.
    @ViewBuilder
    private var factorList: some View {
        let top = Array(score.factors.prefix(3))
        if top.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.blue)
                Text("Nothing dragging this down.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(top) { factor in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(Theme.orange)
                            .frame(width: 5, height: 5)
                            .padding(.top, 5)
                        Text(factor.reason)
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Text("-\(factor.points)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Score ring
//
// A simple trimmed-Circle gauge: a faint full track with a tinted arc proportional
// to the score, the big number centered, and "/100" beneath it.

private struct ScoreRing: View {
    let value: Int
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.hairFill, lineWidth: 8)
            Circle()
                .trim(from: 0, to: CGFloat(value) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(value)")
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                Text("/100")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: 92, height: 92)
    }
}

// MARK: - Compact health cards (Home embed)
//
// A smaller mirror of the Overview's two ScoreCards, sized to sit on the Home page
// under the activity heatmap. Same live HealthScore / SecurityScore rubric, but a
// trimmed ring + grade + the single top factor, and the whole card deep-links to the
// full Health page. Public (not private) so ReadoutView's StatsPanel can embed it.

struct CompactHealthCards: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let health = HealthScore(model: model)
        let security = SecurityScore(model: model)
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                CompactScoreCard(score: health)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                CompactScoreCard(score: security)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - One compact score card
//
// A small ring + score on the left, title + grade + the single biggest drag-down
// factor on the right. The whole card is a button into the Health page.

private struct CompactScoreCard: View {
    @Environment(AppModel.self) private var model
    let score: any ScoreModel
    @State private var hovering = false

    var body: some View {
        Button {
            model.route = .health
        } label: {
            Card(padding: 16) {
                HStack(spacing: 14) {
                    // Compact ring + number.
                    CompactScoreRing(value: score.value, tint: score.tint)

                    VStack(alignment: .leading, spacing: 6) {
                        // Title + grade pill.
                        HStack(spacing: 7) {
                            Image(systemName: score.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(score.tint)
                            Text(score.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer(minLength: 6)
                            Text(score.grade)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(score.tint)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(score.tint.opacity(0.14)))
                        }
                        // The single biggest drag-down factor, or an all-clear line.
                        if let top = score.factors.first {
                            Text(top.reason)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.seal")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.blue)
                                Text("Nothing dragging this down.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(score.tint.opacity(hovering ? 0.5 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open the Health page")
    }
}

// MARK: - Compact score ring (smaller gauge for the Home embed)

private struct CompactScoreRing: View {
    let value: Int
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.hairFill, lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(value) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(value)")
                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(width: 60, height: 60)
    }
}

// MARK: - Suggestions card
//
// A prioritized, actionable to-do list built from the live hygiene issues (their
// existing title/detail/route are already action-oriented), ordered most severe
// first. Each row deep-links to where the fix lives. When there are no issues, a
// single all-clear line shows.

private struct SuggestionsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(icon: "checklist", title: "Suggestions")

                let issues = model.hygiene.issues
                if issues.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal")
                            .foregroundStyle(Theme.blue)
                        Text("All clear: nothing needs attention right now.")
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                            if index > 0 { Divider() }
                            SuggestionRow(issue: issue)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - One suggestion row
//
// Severity glyph + action title + detail, an optional trailing badge, and a
// disclosure chevron when it links somewhere. Tapping navigates to the issue's
// route (e.g. Settings to set a budget, Repos to commit / add CLAUDE.md).

private struct SuggestionRow: View {
    let issue: HygieneIssue

    // Informational only: Health suggestions describe what to look at, they do not
    // navigate (a generic page jump that didn't land on the specific item read as
    // broken). No button, no chevron.
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: issue.severity.icon)
                .foregroundStyle(issue.severity.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(issue.detail)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let badge = issue.badge {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(issue.badgeTint ?? Theme.textSecondary)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Status summary section (severity counts)
//
// Critical and warning counts straight from the hygiene engine, plus a derived
// "Notices" count of everything that is neither, as native LabeledContent rows.
// Heads the Issues tab.

private struct StatusSummarySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hygiene = model.hygiene
        let total = hygiene.issues.count
        let info = max(0, total - hygiene.critical - hygiene.warnings)

        Section {
            // Critical count
            LabeledContent {
                Text("\(hygiene.critical)").font(.body.weight(.semibold).monospacedDigit())
            } label: {
                Label("Critical", systemImage: HygieneIssue.Severity.critical.icon)
                    .foregroundStyle(HygieneIssue.Severity.critical.tint)
            }
            // Warning count
            LabeledContent {
                Text("\(hygiene.warnings)").font(.body.weight(.semibold).monospacedDigit())
            } label: {
                Label("Warnings", systemImage: HygieneIssue.Severity.warning.icon)
                    .foregroundStyle(HygieneIssue.Severity.warning.tint)
            }
            // Notice count
            LabeledContent {
                Text("\(info)").font(.body.weight(.semibold).monospacedDigit())
            } label: {
                Label("Notices", systemImage: HygieneIssue.Severity.info.icon)
                    .foregroundStyle(HygieneIssue.Severity.info.tint)
            }
        } header: {
            Text("Status")
        } footer: {
            Text(total == 0
                 ? "All clear: nothing needs attention right now."
                 : "\(total) hygiene \(total == 1 ? "issue" : "issues") detected across your stack.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Environment section
//
// Pass/fail tooling checks describing the discovered environment. Each row is a
// LabeledContent with a green check / gray x glyph, a label, and a detail value.
// Heads the Setup tab.

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

// MARK: - Core tools section (moved from SetupView)
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

// MARK: - AI tools section (moved from SetupView)
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
            Text("\(checks.filter(\.isReady).count) of \(checks.count) configured. Cortex is built around Claude Code, but it notes which other tools you have set up so the picture is complete.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - What Cortex reads section (moved from SetupView)
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

// MARK: - Checklist row (moved from SetupView)
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

// MARK: - Setup check model (moved from SetupView)
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

// MARK: - Issues sections (grouped hygiene list)
//
// The full HygieneEngine issue list as native Sections, partitioned into
// critical / warning / info groups (most severe first). Each section's rows are
// tappable and navigate to the issue's route when set. Heads the Issues tab body.

private struct IssuesSections: View {
    @Environment(AppModel.self) private var model

    /// Display order for the severity groups (most urgent first).
    private let severityOrder: [HygieneIssue.Severity] = [.critical, .warning, .info]

    var body: some View {
        let issues = model.hygiene.issues

        if issues.isEmpty {
            // Everything is clean: a single all-clear section
            Section {
                Label("No hygiene issues need attention right now.",
                      systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Hygiene")
            }
        } else {
            // One Section per non-empty severity bucket, most severe first
            ForEach(severityOrder, id: \.self) { severity in
                let group = issues.filter { $0.severity == severity }
                if !group.isEmpty {
                    Section {
                        ForEach(group) { issue in
                            IssueRow(issue: issue)
                        }
                    } header: {
                        // Tinted severity header with a trailing count
                        HStack(spacing: 6) {
                            Image(systemName: severity.icon)
                                .foregroundStyle(severity.tint)
                            Text(groupTitle(severity))
                            Spacer()
                            Text("\(group.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// Human-readable group label for a severity bucket.
    private func groupTitle(_ severity: HygieneIssue.Severity) -> String {
        switch severity {
        case .critical: "Critical"
        case .warning: "Warnings"
        case .info: "Notices"
        }
    }
}

// MARK: - One issue row
//
// Severity glyph + title + detail on the left, an optional badge on the right.
// Informational only (no navigation): a generic page jump that didn't land on the
// specific item read as broken, so the rows just describe the issue.

private struct IssueRow: View {
    let issue: HygieneIssue

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Severity glyph
            Image(systemName: issue.severity.icon)
                .foregroundStyle(issue.severity.tint)
                .frame(width: 18)

            // Title + detail
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(issue.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // Optional trailing badge
            if let badge = issue.badge {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(issue.badgeTint ?? .secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
