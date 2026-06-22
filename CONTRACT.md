# Cortex - Build Contract

Cortex is a native SwiftUI macOS app (macOS 15+, Swift 5 language mode, dependency-free:
only SwiftUI + Swift Charts). It is your personal control center for your on-device AI
stack: Claude Code sessions, costs, skills, agents, MCP servers, hooks, memory, repos,
and ports. All data is REAL and read live from disk / CLIs. The app is dark-first.

This file is the single source of truth for everyone building feature views and services.
ALWAYS read the foundation files before writing code:
- `Cortex/Models/Models.swift` (all data types)
- `Cortex/App/Navigation.swift` (Route enum, Sidebar sections)
- `Cortex/App/AppModel.swift` (the shared @Observable model in the environment)
- `Cortex/DesignSystem/Theme.swift`, `Components.swift`, `Charts.swift`
- The relevant service in `Cortex/Services/`

## Hard rules

1. NEVER use the em-dash character. Use a hyphen, colon, parentheses, or two sentences.
2. Dark-first. Use `Theme.*` colors and the design-system components. Never hardcode hex.
3. Use REAL data from `AppModel` / the services. No mock/placeholder arrays in shipped views.
4. NO new Swift packages or imports beyond `SwiftUI`, `Charts`, `Foundation`, `AppKit`.
5. Do NOT run `xcodebuild` or `xcodegen`. A dedicated build step handles compilation.
   Just write correct Swift. New files are auto-added to the target on regen.
6. Add a `data`-style intent via comments: put a short `// MARK:` / section comment above
   every major block, component, and subview. Name things by purpose, not appearance.
7. Every view reads the model with `@Environment(AppModel.self) private var model`.
8. Keep files focused and readable. Prefer small private subviews over giant bodies.
9. Access the model's stores: `model.sessions`, `model.cost`, `model.ports`, `model.repos`,
   `model.config`, `model.chat`, `model.hygiene`, plus `model.stats`, `model.userName`,
   `model.userLogin`, `model.monthlyBudget`, `model.route`, `model.showCommandPalette`.

## Key model types (see Models.swift for full definitions)

- `ClaudeSession` { id, projectName, projectPath, startedAt, endedAt, messageCount,
  userMessageCount, assistantMessageCount, models:[String], usage:TokenUsage, cost:Double,
  gitBranch?, lastPrompt?, primaryModel? }
- `TokenUsage` { input, output, cacheRead, cacheWrite, total }
- `UsageStats` { sessions, messages, totalTokens, totalCost, activeDays, currentStreak,
  longestStreak, peakHour:Int?, favoriteModel:String?, dailyActivity:[DayActivity],
  hourly:[HourBucket], heatmap:[HeatCell], costByModel:[ModelCost] }; nested `Window` enum
  `.all/.days30/.days7`.
- `DayActivity` { date, sessions, messages, tokens, cost }
- `HourBucket` { hour, weight (0...1), messages }
- `HeatCell` { date, count, level (0...4) }
- `ModelCost` { modelKey, display, cost, tokens, tint }
- `RepoInfo` { name, path, currentBranch?, commitsToday, uncommittedFiles, behind, ahead,
  lastCommit?, remoteURL?, isGitHub, skillCount, agentCount, hasClaudeMd, claudeMdLines,
  hasSkills, hasAgents, isDirty }
- `GitHubRepo` { nameWithOwner, name, owner, description?, isPrivate, isFork, stars,
  language?, updatedAt?, url }
- `PortInfo` { port, pid, command, processName, family, user, project?, url? }
- `ConfigItem` { id, name, detail, path, kind:ConfigKind, source:ToolKind, isGlobal,
  projectName?, fileSize, modified, content, frontmatter, scopeLabel }
- `ConfigKind` .skill/.agent/.command/.rule/.mcp/.hook/.memory/.plugin (has .plural,.singular,.icon)
- `ToolKind` .claude/.codex/... (has .displayName,.iconName,.tint)
- `MCPServer` { name, transport, command?, url?, scope, needsAuth, toolCount }
- `HookItem` { event, matcher?, command, source }
- `MemoryItem` { name, hook, path, scope, modified, sizeBytes }
- `HygieneIssue` { title, detail, severity(.info/.warning/.critical), category, badge?,
  badgeTint?, route? }; `severity.tint`, `severity.icon`.
- `ChatMessage` { role(.user/.assistant), text, createdAt, isStreaming, cost? }
- Helpers: `Fmt.compact`, `Fmt.grouped`, `Fmt.money`, `Fmt.relative`, `Fmt.hourLabel`.

## Service APIs (read the files; do not change public signatures)

- `SessionStore`: `sessions:[ClaudeSession]`, `isLoading`, `stats(window:) -> UsageStats`.
- `CostService`: `pricing`, `cost(for:model:)`, `price(for:)`, static `displayName(_:)`.
- `PortService`: `ports:[PortInfo]`, `isLoading`, `load()`.
- `RepoService`: `repos:[RepoInfo]`, `gitHubRepos:[GitHubRepo]`, `userLogin`, `userName`,
  `reposWithSkills`, `reposWithAgents`, `commitsToday`, `richestConfig`.
- `ConfigScanner`: `items:[ConfigItem]`, `mcpServers`, `hooks`, `memories`,
  `items(of:)`, `skills`, `agents`, `commands`.
- `ChatService`: `messages:[ChatMessage]`, `isResponding`, `lastError`, `isAvailable`,
  `send(_:) async`, `reset()`.
- `HygieneEngine`: `issues:[HygieneIssue]`, `critical`, `warnings`.

## Design system (DesignSystem/*.swift)

- `Card { content }` - base surface. `StatTile(label:value:dot:sublabel:big:)`.
- `SectionHeader(icon:title:tint:trailing:chevron:)`, `Pill(text:tint:filled:)`,
  `CortexSegmented(selection:options:)`, `RowLink { leading } trailing: { ... }`,
  `PageScaffold(title:subtitle:toolbar:) { content }`, `CortexEmptyState(icon:title:message:)`,
  `FlowGrid(data:minWidth:) { item in ... }`.
- Charts: `ActivityBarChart(days:tint:height:metric:)`, `HourlyBarChart(buckets:)`,
  `HorizontalBars(rows:[HBarRow])` where `HBarRow{id,label,value,valueText,tint}`,
  `ContributionHeatmap(cells:)`, `Sparkline(values:tint:)`, `DonutChart(slices:)`.
- `Theme`: canvas, card, cardRaised, stroke, textPrimary/Secondary/Tertiary, claude/accent,
  blue/green/yellow/orange/purple/warn, radius, heatColor(level), hourColor(hour), palette.
- Fonts: `.cortexTitle .cortexHeadline .cortexStatNumber .cortexCaption .cortexMono`.

## Shared component to build (Phase A): EntityDetailView

A reusable per-entity dashboard panel used by Tools/Skills/Agents/Repos detail. Create file
`Cortex/Features/EntityDetailView.swift` with EXACTLY this public API:

```swift
struct EntityStat: Identifiable { let id = UUID(); let label: String; let value: String; var tint: Color = Theme.textSecondary }

struct EntityDetailView<Extra: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let stats: [EntityStat]
    let activity: [DayActivity]            // empty -> hide the chart
    @ViewBuilder var extra: () -> Extra
    // body: header (icon+title+subtitle), a wrapping grid of StatTiles from `stats`,
    //       an "Activity" Card with ActivityBarChart(days: activity) when non-empty,
    //       then the `extra` content (metadata, content preview, etc.)
}
```

Consumers present it in a `.sheet` or `.inspector` or a `NavigationStack` push. Keep it
self-contained and scrollable.

## Reference dashboard #1 - the "What's up next" stats panel (lives in SessionsView)

A `Card`-framed panel at the top of Sessions:
- Header row: an `asterisk` SF Symbol in `Theme.claude` + bold title `"What's up next, \(model.userName)?"`.
  Right side: `CortexSegmented` time window `All / 30d / 7d` bound to local `@State`.
- Optional sub-tabs `Overview | Models` (CortexSegmented). Overview shows the grid+heatmap;
  Models shows a `DonutChart` of token share by model + a small table of `ModelCost`.
- Compute `let s = model.sessions.stats(window: window)`.
- Stat grid (4 columns, 2 rows) of `StatTile`s:
  Sessions = s.sessions; Messages = Fmt.grouped(s.messages); Total tokens = Fmt.compact(s.totalTokens);
  Active days = s.activeDays; Current streak = "\(s.currentStreak)d"; Longest streak = "\(s.longestStreak)d";
  Peak hour = s.peakHour.map(Fmt.hourLabel) ?? "-"; Favorite model = s.favoriteModel ?? "-".
- Below the grid: `ContributionHeatmap(cells: s.heatmap)` inside the panel (horizontally scrollable).
- A subtle footnote line in Theme.textTertiary: a fun fact comparing tokens, e.g.
  `"You've used ~\(Int(Double(s.totalTokens)/770_000))x more tokens than The Lord of the Rings."`
  (The Lord of the Rings ~= 770K tokens. Only show when the multiple >= 1.)
- Under the panel: the session list (see SessionsView spec).

## Reference dashboard #2 - the Home dashboard (ReadoutView)

Scrolling page (use `PageScaffold` or a custom scroll). Top to bottom:
1. Greeting `"Hey, \(model.userName)"` as the large title.
2. A prose summary line in Theme.textSecondary, with key numbers bolded/tinted:
   "You have **\(repos.count)** repos set up, **\(reposWithSkills)** with skills and
   **\(reposWithAgents)** with agents. **\(richestConfig?.name)** has the richest config.
   You've pushed **\(commitsToday)** commits today." (Use real values; gracefully omit the
   richest-config clause if nil.)
3. KPI row: 4 `StatTile(big:true)` in an HStack/grid:
   - Repos = repos count (dot: Theme.blue)
   - Commits Today = commitsToday (dot: Theme.green)
   - Sessions = stats.sessions (dot: Theme.blue)
   - Est. Cost = Fmt.money(stats.totalCost) (dot: Theme.yellow)
4. Two equal cards side by side:
   - "Activity" with trailing "30d" + chevron (SectionHeader chevron:true): `ActivityBarChart`
     over the last 30 `DayActivity` (messages metric), tint Theme.blue.
   - "When You Work" (clock icon, green tint) + chevron: `HourlyBarChart(buckets: stats.hourly)`.
5. Two cards side by side:
   - "Cost by Model" ($ icon, yellow): `HorizontalBars` from `stats.costByModel`
     (label=display, value=cost, valueText=Fmt.money(cost), tint=model.tint). Bottom-right
     bold "Total: \(Fmt.money(stats.totalCost))".
   - "Recent Sessions" (chat bubble icon): list of the 4 most recent `model.sessions.sessions`,
     each row: an asterisk glyph + the session's lastPrompt (or "session") truncated, then the
     projectName tinted Theme.blue + Fmt.relative(endedAt). Tapping selects/opens it.
6. Hygiene list: full-width stacked `RowLink`s, one per `model.hygiene.issues`:
   leading = severity icon (issue.severity.icon, colored issue.severity.tint) + VStack(title bold,
   detail in secondary). trailing = optional `Pill(badge, tint: badgeTint, filled:false)`.
   Tapping navigates to `issue.route` if set (set `model.route = route`). If there are issues,
   prepend a summary `RowLink` "\(issues.count) hygiene issues need attention".

## Per-entity dashboards

The user wants every MCP server / skill / agent / repo to have its own dashboard tab. Implement
by letting list rows open `EntityDetailView` (sheet or inspector) populated with that entity's
real stats and, where available, an activity series. For skills/agents use file size, modified
date, source tool, scope, and a content preview in `extra`. For MCP show transport, scope,
toolCount, needsAuth. For repos show commitsToday, uncommitted, behind/ahead, skillCount,
agentCount, claudeMdLines, and a Sparkline if you can derive one.
