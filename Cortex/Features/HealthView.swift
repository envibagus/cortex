import SwiftUI
import AppKit

// MARK: - HealthView (workspace health + hygiene control center)
//
// One page with a shared metrics header and two tabs below it, all driven by the
// SAME live Hygiene scan so the numbers always agree:
//
//   - Metrics header (always visible): the Health + Security scores (0-100 ring +
//     grade + top drag-down factors). The Health score is derived directly from the
//     Hygiene scan, so resolving any finding raises it.
//   - Tabs (under the metrics):
//       Overview - the scan findings grouped BY SEVERITY, read-only (triage).
//       Hygiene  - the SAME findings grouped BY CATEGORY, each row actionable
//                  (kill / delete branch / drop stash / pull / Trash / reveal).
//
// Everything reads live from AppModel; there is no mock data. Native semantic colors
// + the app's orange/blue accents throughout, so it adapts to light + dark.

struct HealthView: View {
    @Environment(AppModel.self) private var model
    // Which tab's breakdown is showing below the shared metrics header.
    @State private var tab: HealthTab = .overview

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Metrics header: the two scores, shared across both tabs so it's clear
                // they summarize the one underlying scan.
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

                // Tabs sit UNDER the metrics: same data, two presentations.
                GlassSegmentedControl(items: HealthTab.allCases, selection: $tab) { $0.title }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)

                tabContent
            }
            .padding(.horizontal, Theme.pageHInset)
            .padding(.top, Theme.pageTopInset)
            .padding(.bottom, Theme.pageHInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        .cortexScrollEdge()
        .cortexPageChrome("Health", subtitle: "Workspace health and hygiene, from one live scan")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HealthRefreshButton()
            }
        }
        // Load the Hygiene scan when the Health page opens (either tab), so the metrics
        // header and both tabs are all derived from the same findings.
        .task {
            if model.hygieneScanner.lastScan == nil { await model.loadHygiene() }
        }
    }

    // MARK: Tab content (loading / all-clear / the selected breakdown)

    @ViewBuilder
    private var tabContent: some View {
        let scanner = model.hygieneScanner
        if scanner.sections.isEmpty {
            if scanner.lastScan != nil {
                CortexEmptyState(
                    icon: "checkmark.seal",
                    title: "All clean",
                    message: "No hygiene issues across your workspace right now.")
            } else {
                loadingState
            }
        } else {
            switch tab {
            case .overview: overviewContent
            case .hygiene: hygieneContent
            }
        }
    }

    /// Overview: the scan findings grouped BY SEVERITY, read-only (triage). The Info
    /// group starts collapsed since it's the long tail.
    private var overviewContent: some View {
        let all = model.hygieneScanner.sections.flatMap(\.findings)
        let order: [HygieneIssue.Severity] = [.critical, .warning, .info]
        return VStack(alignment: .leading, spacing: 20) {
            ForEach(order, id: \.self) { severity in
                let group = all.filter { $0.severity == severity }
                if !group.isEmpty {
                    HygieneGroupCard(
                        title: severityTitle(severity),
                        icon: severity.icon,
                        tint: severity.tint,
                        info: nil,
                        findings: group,
                        actionable: false,
                        startExpanded: severity != .info)
                }
            }
        }
    }

    /// Hygiene: the SAME findings grouped BY CATEGORY, each row actionable.
    private var hygieneContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HygieneAssistantCTA()
            ForEach(model.hygieneScanner.sections) { section in
                HygieneGroupCard(
                    title: section.title,
                    icon: section.icon,
                    tint: section.findings.contains { $0.severity != .info } ? Theme.orange : Theme.blue,
                    info: section.info,
                    findings: section.findings,
                    actionable: true,
                    startExpanded: true)
            }
        }
    }

    private func severityTitle(_ s: HygieneIssue.Severity) -> String {
        switch s { case .critical: "Critical"; case .warning: "Warnings"; case .info: "Info" }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Scanning your workspace")
                .font(.cortexHeadline).foregroundStyle(Theme.textPrimary)
            Text("Checking branches, stashes, ports, secrets, and dead directories.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

// MARK: - Health tabs

enum HealthTab: String, CaseIterable, Identifiable, Hashable {
    case overview, hygiene
    var id: String { rawValue }
    var title: String {
        switch self { case .overview: "Overview"; case .hygiene: "Hygiene" }
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

// MARK: - Fix-with-Assistant CTA
//
// A full-width row that opens the Assistant so you can ask it to help work through the
// findings. Honestly labelled: it navigates to the chat, it doesn't auto-fix anything.

private struct HygieneAssistantCTA: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.route = .assistant
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.blue)
                Text("Ask the Assistant to help fix these")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help("Open the Assistant")
    }
}

// MARK: - Hygiene group card (collapsible group of findings)
//
// One collapsible card used by BOTH tabs: the Overview groups by severity (read-only),
// the Hygiene tab groups by category (actionable). The `actionable` flag toggles the
// per-row command preview + action button.

private struct HygieneGroupCard: View {
    let title: String
    let icon: String
    let tint: Color
    let info: String?
    let findings: [HygieneFinding]
    let actionable: Bool
    @State private var expanded: Bool

    init(title: String, icon: String, tint: Color, info: String?,
         findings: [HygieneFinding], actionable: Bool, startExpanded: Bool) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.info = info
        self.findings = findings
        self.actionable = actionable
        _expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                // Header: icon + title + count + optional info tooltip + collapse chevron.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                        Text(title)
                            .font(.cortexHeadline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(findings.count)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let info {
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .help(info)
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkCursor()
                .padding(.bottom, expanded ? 6 : 0)

                if expanded {
                    ForEach(Array(findings.enumerated()), id: \.element.id) { idx, finding in
                        if idx > 0 { Divider() }
                        HygieneFindingRow(finding: finding, actionable: actionable)
                    }
                }
            }
        }
    }
}

// MARK: - Hygiene finding row
//
// Title + badge + detail, plus (when actionable) a mono command preview and a single
// trailing action button. Destructive actions confirm via a native dialog first;
// non-destructive ones (reveal / pull) run immediately. The AppModel action methods
// own the toast + undo + re-scan.

private struct HygieneFindingRow: View {
    let finding: HygieneFinding
    let actionable: Bool
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(finding.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let badge = finding.badge, !badge.isEmpty {
                        Pill(text: badge, tint: Theme.blue)
                    }
                }
                if let detail = finding.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if actionable, let command = finding.command {
                    Text("$ \(command)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)

            if actionable { actionButton }
        }
        .padding(.vertical, 9)
        .confirmationDialog(finding.action.confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(finding.action.label, role: finding.action.isDestructive ? .destructive : nil) { perform() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(finding.action.confirmMessage)
        }
    }

    private var actionButton: some View {
        Button {
            if finding.action.needsConfirm { confirming = true } else { perform() }
        } label: {
            Label(finding.action.label, systemImage: finding.action.systemImage)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(finding.action.isDestructive ? Theme.orange : Theme.blue)
        .linkCursor()
    }

    /// Run the finding's action. Reveal happens inline (read-only); the rest route
    /// through AppModel so they get a toast + undo + re-scan.
    private func perform() {
        switch finding.action {
        case .reveal(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .kill(let pid, let name):
            model.killProcess(pid: pid, name: name, findingID: finding.id)
        case .deleteBranch(let repoPath, let branch, let repoName):
            model.deleteBranch(repoPath: repoPath, branch: branch, repoName: repoName, findingID: finding.id)
        case .dropStash(let repoPath, let ref, let sha, let repoName):
            model.dropStash(repoPath: repoPath, sha: sha, ref: ref, repoName: repoName, findingID: finding.id)
        case .pull(let repoPath, let repoName):
            model.pullRepo(repoPath: repoPath, repoName: repoName, findingID: finding.id)
        case .trash(let path):
            model.trashDirectory(path: path, findingID: finding.id)
        }
    }
}

// MARK: - Score rubric
//
// A computed score is 0-100 with a one-word grade and a short, ranked list of the
// factors dragging it down.

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
// Unified with the Hygiene tab: once the scan has run, the score is derived from the
// SAME findings the Hygiene tab lists, severity-weighted with per-severity caps so the
// long info tail can't pin it at zero. Before the scan runs it falls back to the
// lightweight HygieneEngine signals so the score is never a misleading "100".

private struct HealthScore: ScoreModel {
    let value: Int
    let factors: [ScoreFactor]
    let title = "Health"
    let icon = "heart.text.square"

    @MainActor
    init(model: AppModel) {
        let result = model.hygieneScanner.lastScan != nil
            ? Self.fromHygieneScan(model.hygieneScanner)
            : Self.fromHygieneEngine(model)
        self.value = result.value
        self.factors = result.factors
    }

    // Unified score: every finding contributes a severity-weighted penalty, capped PER
    // SEVERITY. One factor per non-empty section summarizes the biggest contributors.
    @MainActor
    private static func fromHygieneScan(_ scanner: HygieneScanner) -> (value: Int, factors: [ScoreFactor]) {
        let all = scanner.sections.flatMap(\.findings)
        let crit = all.filter { $0.severity == .critical }.count
        let warn = all.filter { $0.severity == .warning }.count
        let info = all.filter { $0.severity == .info }.count

        let penalty = min(crit * 10, 40) + min(warn * 3, 27) + Int(min(Double(info) * 0.4, 16))
        let value = max(0, min(100, 100 - penalty))

        let factors = scanner.sections.compactMap { section -> ScoreFactor? in
            let c = section.findings.filter { $0.severity == .critical }.count
            let w = section.findings.filter { $0.severity == .warning }.count
            let i = section.findings.filter { $0.severity == .info }.count
            let pts = Int((Double(c) * 10 + Double(w) * 3 + Double(i) * 0.4).rounded())
            guard pts > 0 else { return nil }
            return ScoreFactor(reason: "\(section.findings.count) \(section.title.lowercased())", points: pts)
        }
        .sorted { $0.points > $1.points }

        return (value, factors)
    }

    // Fallback (pre-scan): the lightweight HygieneEngine signals.
    @MainActor
    private static func fromHygieneEngine(_ model: AppModel) -> (value: Int, factors: [ScoreFactor]) {
        var penalties: [ScoreFactor] = []

        let warnings = model.hygiene.warnings
        let critical = model.hygiene.critical
        let notices = max(0, model.hygiene.issues.count - warnings - critical)
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

        let repos = model.repos.repos
        if let dirtiest = repos.max(by: { $0.uncommittedFiles < $1.uncommittedFiles }),
           dirtiest.uncommittedFiles >= 8 {
            penalties.append(ScoreFactor(
                reason: "\(dirtiest.name) has \(dirtiest.uncommittedFiles) uncommitted files",
                points: 10))
        }

        let behind = repos.filter { $0.behind > 0 }.count
        if behind > 0 {
            let counted = min(behind, 3)
            penalties.append(ScoreFactor(
                reason: "\(behind) repo\(behind == 1 ? "" : "s") behind remote",
                points: counted * 4))
        }

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

        if model.monthlyBudget == nil {
            penalties.append(ScoreFactor(reason: "No spending budget set", points: 6))
        }

        let total = penalties.reduce(0) { $0 + $1.points }
        return (max(0, min(100, 100 - total)), penalties.sorted { $0.points > $1.points })
    }
}

// MARK: - Security score
//
// Reads only data already in the model; it does NOT scan for secrets or do anything
// heavy:
//   - Each MCP server that needs auth but isn't configured: -10 each.
//   - 4+ hooks running shell commands: -2 per hook beyond the first 3 (capped -20).
//   - No monthly budget set: -8 (runaway cost is a financial/security risk).

private struct SecurityScore: ScoreModel {
    let value: Int
    let factors: [ScoreFactor]
    let title = "Security"
    let icon = "lock.shield"

    @MainActor
    init(model: AppModel) {
        var penalties: [ScoreFactor] = []

        let needsAuth = model.config.mcpServers.filter { $0.needsAuth }.count
        if needsAuth > 0 {
            penalties.append(ScoreFactor(
                reason: "\(needsAuth) MCP server\(needsAuth == 1 ? "" : "s") need auth",
                points: needsAuth * 10))
        }

        let shellHooks = model.config.hooks.filter { !$0.command.isEmpty }.count
        if shellHooks > 3 {
            let extra = shellHooks - 3
            let pts = min(20, extra * 2)
            penalties.append(ScoreFactor(
                reason: "\(shellHooks) hooks run shell commands",
                points: pts))
        }

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
// A prominent score: a trimmed Circle ring around the big number + grade on the left,
// the title above it, and the top 2-3 drag-down factors listed on the right.

private struct ScoreCard: View {
    let score: any ScoreModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
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

                HStack(alignment: .center, spacing: 18) {
                    ScoreRing(value: score.value, tint: score.tint)
                    factorList
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

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
// A simple trimmed-Circle gauge: a faint full track with a tinted arc proportional to
// the score, the big number centered, and "/100" beneath it.

private struct ScoreRing: View {
    let value: Int
    let tint: Color
    @State private var filled = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.hairFill, lineWidth: 8)
            Circle()
                .trim(from: 0, to: filled ? CGFloat(value) / 100 : 0)
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
        .onAppear { withAnimation(.easeOut(duration: 0.6).delay(0.3)) { filled = true } }
    }
}

// MARK: - Compact health cards (Home embed)
//
// A slim inline strip mirroring the two scores, sized to sit on the Home page. Same
// live HealthScore / SecurityScore rubric; the whole strip deep-links to the full
// Health page. Public so HomeView's StatsPanel can embed it.

struct CompactHealthCards: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let health = HealthScore(model: model)
        let security = SecurityScore(model: model)
        Button {
            model.route = .health
        } label: {
            HStack(spacing: 12) {
                ScoreInline(score: health)
                Text("·").font(.callout).foregroundStyle(.tertiary)
                ScoreInline(score: security)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help("Open the Health page")
    }
}

// MARK: - One inline score (icon + title + number + grade, no ring)

private struct ScoreInline: View {
    let score: any ScoreModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: score.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(score.tint)
            Text(score.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("\(score.value)")
                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(score.tint)
            Text(score.grade)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(score.tint)
        }
    }
}
