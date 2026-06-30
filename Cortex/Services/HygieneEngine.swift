import SwiftUI
import Foundation

// MARK: - HygieneEngine
//
// Derives the "needs attention" insight cards shown on the Readout and Health
// views from live state: dirty repos, repos behind remote, oversized CLAUDE.md
// files, missing spend budget, and approaching budget. Every rule reads live
// inputs and is skipped when its inputs are empty, so an unscanned stack never
// produces noise.

@MainActor
@Observable
final class HygieneEngine {
    private(set) var issues: [HygieneIssue] = []

    var critical: Int { issues.filter { $0.severity == .critical }.count }
    var warnings: Int { issues.filter { $0.severity == .warning }.count }

    // MARK: Recompute entry point
    //
    // Builds the full issue list from the current repos, config, usage stats, and
    // budget, then sorts critical-first and assigns on the main actor.

    func recompute(repos: RepoService, config: ConfigScanner, stats: UsageStats, monthSpend: Double, monthlyBudget: Double?) {
        var built: [HygieneIssue] = []

        built.append(contentsOf: dirtyRepoIssue(repos: repos))
        built.append(contentsOf: behindRemoteIssues(repos: repos))
        built.append(contentsOf: unpushedIssues(repos: repos))
        built.append(contentsOf: largeClaudeMdIssues(repos: repos))
        built.append(contentsOf: budgetIssues(monthSpend: monthSpend, monthlyBudget: monthlyBudget))
        built.append(contentsOf: missingClaudeMdIssue(repos: repos))
        built.append(contentsOf: mcpAuthIssue(config: config))
        built.append(contentsOf: shellHooksIssue(config: config))

        // Stable ordering: most severe first, then grouped by category.
        let ordered = built.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.category.rawValue < rhs.category.rawValue
        }

        issues = ordered
    }

    // MARK: Git - dirtiest repo
    //
    // The single repo with the most uncommitted files, flagged once it crosses a
    // meaningful threshold (>= 8).

    private func dirtyRepoIssue(repos: RepoService) -> [HygieneIssue] {
        let all = repos.repos
        guard !all.isEmpty else { return [] }
        guard let dirtiest = all.max(by: { $0.uncommittedFiles < $1.uncommittedFiles }),
              dirtiest.uncommittedFiles >= 8 else { return [] }

        return [HygieneIssue(
            id: "git-dirty-\(dirtiest.path)",
            title: "\(dirtiest.name) has \(dirtiest.uncommittedFiles) uncommitted files",
            detail: "Commit or stash to keep this working tree reviewable.",
            severity: .warning,
            category: .git,
            badge: nil,
            badgeTint: nil,
            route: .repos
        )]
    }

    // MARK: Git - behind remote
    //
    // Repos with unpulled commits on their upstream, capped at the three most
    // behind so the list stays focused.

    private func behindRemoteIssues(repos: RepoService) -> [HygieneIssue] {
        let behind = repos.repos
            .filter { $0.behind > 0 }
            .sorted { $0.behind > $1.behind }
            .prefix(3)
        guard !behind.isEmpty else { return [] }

        return behind.map { repo in
            HygieneIssue(
                id: "git-behind-\(repo.path)",
                title: "\(repo.name) is \(repo.behind) commits behind remote",
                detail: "Pull the latest changes before you start new work.",
                severity: .info,
                category: .git,
                badge: nil,
                badgeTint: nil,
                route: .repos
            )
        }
    }

    // MARK: Git - unpushed commits
    //
    // Repos with local commits not yet on their upstream, capped at the three most
    // ahead. The mirror of behind-remote: surface work that isn't backed up yet.

    private func unpushedIssues(repos: RepoService) -> [HygieneIssue] {
        let ahead = repos.repos
            .filter { $0.ahead > 0 }
            .sorted { $0.ahead > $1.ahead }
            .prefix(3)
        guard !ahead.isEmpty else { return [] }

        return ahead.map { repo in
            HygieneIssue(
                id: "git-ahead-\(repo.path)",
                title: "\(repo.name) has \(repo.ahead) unpushed \(repo.ahead == 1 ? "commit" : "commits")",
                detail: "Push to back up your work and keep the remote in sync.",
                severity: .info,
                category: .git,
                badge: nil,
                badgeTint: nil,
                route: .repos
            )
        }
    }

    // MARK: Security - MCP servers needing auth
    //
    // MCP servers that declare they need auth but aren't configured for it can fail
    // open or expose a connection, so surface them as a warning. Mirrors the security
    // score's MCP-auth factor.

    private func mcpAuthIssue(config: ConfigScanner) -> [HygieneIssue] {
        let needs = config.mcpServers.filter { $0.needsAuth }.count
        guard needs > 0 else { return [] }
        return [HygieneIssue(
            id: "security-mcp-auth",
            title: "\(needs) MCP \(needs == 1 ? "server needs" : "servers need") authentication",
            detail: "Configure auth so these connections don't fail open or expose access.",
            severity: .warning,
            category: .config,
            badge: "Security",
            badgeTint: Theme.orange,
            route: .tools
        )]
    }

    // MARK: Security - shell-running hooks
    //
    // Hooks run unattended, so a large pile of shell-executing hooks is worth a
    // periodic review. Surfaced once past a small threshold. Mirrors the security
    // score's shell-hooks factor.

    private func shellHooksIssue(config: ConfigScanner) -> [HygieneIssue] {
        let shellHooks = config.hooks.filter { !$0.command.isEmpty }.count
        guard shellHooks > 3 else { return [] }
        return [HygieneIssue(
            id: "security-shell-hooks",
            title: "\(shellHooks) hooks run shell commands",
            detail: "Hooks run unattended. Review them so nothing unexpected executes.",
            severity: .info,
            category: .config,
            badge: "Security",
            badgeTint: Theme.orange,
            route: .hooks
        )]
    }

    // MARK: Config - oversized CLAUDE.md
    //
    // CLAUDE.md files are loaded into every session's context, so very large ones
    // quietly add cache cost. Surface the two biggest offenders with an estimate.

    private func largeClaudeMdIssues(repos: RepoService) -> [HygieneIssue] {
        let large = repos.repos
            .filter { $0.claudeMdLines > 400 }
            .sorted { $0.claudeMdLines > $1.claudeMdLines }
            .prefix(2)
        guard !large.isEmpty else { return [] }

        return large.map { repo in
            let lines = repo.claudeMdLines
            let estimate = Double(lines) * 0.003
            return HygieneIssue(
                id: "config-claudemd-\(repo.path)",
                title: "\(repo.name) has a large CLAUDE.md",
                detail: "\(lines) lines - loaded into every session's context, adding cache cost.",
                severity: .info,
                category: .config,
                badge: String(format: "~$%.2f/mo", estimate),
                badgeTint: Theme.green,
                route: .repos
            )
        }
    }

    // MARK: Cost - budget guidance
    //
    // Either nudge the user to set a budget, or warn them when this month's spend
    // is approaching the configured budget (> 80%).

    private func budgetIssues(monthSpend: Double, monthlyBudget: Double?) -> [HygieneIssue] {
        guard let budget = monthlyBudget else {
            // No budget configured: offer to set one.
            return [HygieneIssue(
                id: "cost-no-budget",
                title: "Set a spending budget",
                detail: "You've spent \(Fmt.money(monthSpend)) this month with no budget alerts configured.",
                severity: .info,
                category: .cost,
                badge: "Cost control",
                badgeTint: Theme.green,
                route: .settings
            )]
        }

        // Budget configured: warn when nearing the limit.
        guard monthSpend > budget * 0.8 else { return [] }
        return [HygieneIssue(
            id: "cost-near-budget",
            title: "Approaching monthly budget",
            detail: "You've spent \(Fmt.money(monthSpend)) of your \(Fmt.money(budget)) monthly budget.",
            severity: .warning,
            category: .cost,
            badge: nil,
            badgeTint: nil,
            route: .costs
        )]
    }

    // MARK: Config - missing CLAUDE.md
    //
    // Projects without a CLAUDE.md miss out on per-repo guidance, so encourage
    // adding one when any are missing.

    private func missingClaudeMdIssue(repos: RepoService) -> [HygieneIssue] {
        let all = repos.repos
        guard !all.isEmpty else { return [] }
        let missing = all.filter { !$0.hasClaudeMd }.count
        guard missing > 0 else { return [] }

        return [HygieneIssue(
            id: "config-missing-claudemd",
            title: "Add CLAUDE.md to \(missing) projects",
            detail: "Better results",
            severity: .info,
            category: .config,
            badge: "Better results",
            badgeTint: Theme.blue,
            route: .repos
        )]
    }
}
