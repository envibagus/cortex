# Cortex - agent & contributor guide

Context for AI coding agents (and humans) working in this repo. Read this before making
changes. Cortex is a native SwiftUI macOS app: a control center for your local AI stack
(Claude Code sessions, costs, skills, agents, MCP servers, hooks, memory, repos, ports).

## Build & run

```bash
xcodegen generate   # regenerate Cortex.xcodeproj from project.yml (run after ADDING or REMOVING a .swift file)
xcodebuild -project Cortex.xcodeproj -scheme Cortex -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/Cortex-*/Build/Products/Debug/Cortex.app
```

Or open `Cortex.xcodeproj` in Xcode and Run. The `.xcodeproj` is generated and gitignored;
`project.yml` is the source of truth. Requirements: macOS 15+, Xcode 16+. The UI uses
macOS 26 Liquid Glass APIs behind availability checks, so the full build wants the macOS 26
SDK / Xcode 26; older Xcode builds the rest with pre-26 fallbacks. Dependency-light:
SwiftUI + Swift Charts + MarkdownUI + SwiftDraw only.

## Architecture map

- **`Cortex/App`** - `AppModel` is the single `@Observable` source of truth (current route,
  every store, settings, and the refresh orchestration). `ContentView` is the
  `NavigationSplitView` shell + the cmd-K command palette + toasts. `Navigation` holds the
  `Route` enum and sidebar sections. `CortexApp` owns window config + menu-bar commands.
- **`Cortex/Services`** (all read REAL data, locally, read-only):
  - `SessionStore` parses `~/.claude/projects/**/*.jsonl` into sessions + day buckets.
  - `ConfigScanner` discovers skills/agents/commands/rules/MCP/hooks/memory/instructions from
    `~/.claude` and the configured scan roots.
  - `RepoService` (git + `gh`), `PortService` (`lsof`), `CostService` (pricing),
    `UsageService` (live limits), `SummaryService` (on-device summaries),
    `HygieneEngine` (health/security scores), `LibraryStore` (favorites/collections).
  - `ChatService` is the Assistant: drives the `claude` (or `agy`) CLI as a transport.
  - `Shell` runs subprocesses and resolves binaries (see gotchas).
- **`Cortex/DesignSystem`** - `Theme`, `Components` (Card, GlassSegmentedControl,
  CortexGroupBoxStyle, Pill, hoverHighlight, PageScaffold, FlowLayout), `Charts`, `MarkdownText`.
- **`Cortex/Features`** - one file per route (ReadoutView, AssistantView, SessionsView, ...).
- **`Cortex/Models`** - shared value types (`ClaudeSession`, `ConfigItem`, `ChatMessage`, ...).

## Conventions

- **All data is real and live.** No mock data; everything is read from disk / the CLIs.
- **Read-only, with one opt-in write.** Cortex reads the local AI stack and never phones
  home. The single exception is the optional Live Activity feature (`ActivityService`),
  which installs reversible Claude Code hooks in `~/.claude/settings.json`. Do not add
  other writes to user config, telemetry, or a network backend.
- **No em-dash characters** anywhere (code, comments, docs, UI strings). Use a hyphen, colon,
  or parentheses.
- **Design system:** Liquid Glass where appropriate (`GlassSegmentedControl`, `.glassPill()`);
  one uniform card padding app-wide via `CortexGroupBoxStyle` (do not add ad-hoc per-card
  padding); a hover affordance on every clickable row (`.hoverHighlight()`); every top page
  title is a big `.cortexTitle` with no leading icon.
- **Intentional naming:** a short descriptive comment above each major section/component, and
  `// MARK:` headers throughout.
- **Professional, self-contained writing.** Code, comments, and commit messages stay
  professional and describe *this* project only. Do not reference a private dev repo, internal
  codenames, personal names/handles, or unrelated/competitor products. Naming the tools Cortex
  integrates with (Claude Code, `git`, `gh`) is fine where it is accurate and relevant.
- Swift 5 language mode, `@Observable` stores.

## Critical gotchas (hard-won - do not regress)

- **Window chrome is locked.** `.windowStyle(.titleBar)` + `.windowToolbarStyle(.unified)` is
  final. Do NOT use `.hiddenTitleBar`/`.unifiedCompact` (the sidebar renders as a detached
  floating inset panel), sidebar translucency (the framework paints it opaque), or
  `.ignoresSafeArea(.container, edges: .top)` for a "frosted" header (it pulls content under
  the title bar's drag region, breaking top-right buttons, and bleeds behind-window vibrancy).
  Keep the system sidebar toggle. The thin toolbar band is the price of a flush, solid sidebar.
- **GroupBox nesting:** a `GroupBox` inside another custom-styled `GroupBox` silently loses its
  padding (reverts to the tight default style). Don't nest cards; use a plain `VStack` or
  re-assert `.groupBoxStyle(CortexGroupBoxStyle())` on the inner content.
- **`Shell.which`** consults the user's login-shell PATH (cached) so CLIs installed by node
  version managers (Herd/fnm/nvm) resolve - a GUI app doesn't inherit the shell PATH. Don't
  narrow it back to a hardcoded dir list.
- **Context-window size is not in transcripts.** The 200K vs 1M window is a runtime setting
  Claude Code does not persist (the model is logged as a plain id, no `[1m]` marker). Show the
  raw last-turn token count, never a fabricated percentage.

## UI verification

Build, run, and screenshot the window; compare against the design rather than trusting the
diff. The app reads live local data, so most views need real `~/.claude` content to populate.

## Known limitations

- `claude -p` cold start is ~3-5s to first token; streaming helps after that but can't remove
  the startup wait.
- Full Liquid Glass needs the macOS 26 SDK; older toolchains use fallbacks.
- Distributed as source (build from source). A signed/notarized DMG needs a paid Apple
  Developer account, which the project does not assume.
