# Cortex

**Your local AI stack, in one beautiful native Mac app.**

If you live in Claude Code, your Mac is quietly full of signal: every session, every dollar,
every skill, agent, MCP server, repo, and listening port. Cortex reads all of it (locally,
read-only) and turns it into live dashboards, monitoring, and an assistant that actually knows
your setup. Native SwiftUI, fast, dependency-light, and nothing ever leaves your machine.

## Download (beta)

Grab the latest **[beta DMG from Releases](https://github.com/envibagus/cortex/releases)**, or
[build from source](#build-from-source).

> [!IMPORTANT]
> **The beta build is unsigned** (notarization needs a paid Apple Developer account, which this
> project does not yet have). After dragging Cortex into your Applications folder, **open the
> Terminal app and run this command once**:
>
> ```bash
> xattr -cr /Applications/Cortex.app
> ```
>
> To open Terminal: press `cmd`+`Space`, type `Terminal`, press Return, then paste the line
> above and press Return. Without this step, macOS Gatekeeper warns that Cortex "cannot be
> verified" or "is damaged" - it is safe, just unsigned. (GUI alternative: System Settings >
> Privacy & Security > scroll down > "Open Anyway".)

## Screenshots

<!-- Add screenshots from a throwaway demo dataset with NO personal data.
     Suggested: docs/screenshots/home.png, sessions.png, costs.png, live.png -->

_Screenshots coming soon._

## What it does

### See everything at a glance
- **Home** - your daily dashboard: a personal greeting, headline KPIs (repos, commits,
  sessions, spend), a GitHub-style activity heatmap, a "When You Work" rhythm chart, cost by
  model, your most recent sessions, and a health/insights list.
- **Work Graph** - your whole stack charted on one screen: contributions, sessions by project,
  token share, and your busiest repos.

### Know exactly what you are spending
- **Costs** - a real spend dashboard: all-time, this-month, and this-week totals, cost by
  model, a daily-spend chart, and a per-model token + cost breakdown. Set a monthly budget and
  get a burn-down with alerts.
- **Usage** - your live subscription limits, when your providers expose them.

### Watch it happen, live
- **Live** - what is running right now, grouped by project, with a green "running" badge for
  open Claude windows and one-click Open in Terminal, Reveal, or Stop.
- **Sessions** - browse every Claude Code session with search, sort, and per-session stats
  (messages, tokens, cost, models, context), plus a full message-by-message **replay**.
- **Ports** - every listening TCP port mapped to its owning process, with one-click Open and
  Copy for anything on localhost.

### Your whole Claude config, organized
- **Library** - Skills, Agents, Rules, Commands, MCP servers, Hooks, Memory, Instructions, and
  Plugins, all discovered from `~/.claude` and your projects, each rendered beautifully and
  fully searchable.
- **Favorites & Collections** - star what matters and group it your way.

### An assistant that knows your stack
- **Assistant** - a chat backed by Claude Code, seeded with a live snapshot of your sessions,
  costs, config, and repos. It streams its reply, shows what it is doing, and can drop in
  buttons that jump you straight to the right page. Reopen past conversations anytime.

### Keep it healthy
- **Health** - a Health score and a Security score, each with the top factors dragging it down,
  plus a prioritized suggestions list.
- **Repos** - your local git repos and GitHub at a glance: branch, commits today, uncommitted
  files, behind/ahead, and CLAUDE.md coverage (create one in a click).

### Built for the keyboard
- **Command palette (cmd+K)** - jump to any page, repo, skill, agent, MCP server, or port in a
  couple of keystrokes.

## Tool support

Cortex is built around **Claude Code** and is most powerful there, with lighter awareness of
other AI coding tools:

- **Claude Code (full):** sessions, costs, live activity, usage, the activity heatmap, Work
  Graph, and the stack-aware Assistant all read Claude Code's transcripts in `~/.claude/projects`.
  This is the core.
- **Cursor, Codex, Windsurf, Amp, OpenCode, Gemini / Antigravity (discovery):** the Library
  finds their skills, agents, and rules from their config folders, and Health flags which ones
  you have set up.
- **Assistant engine:** runs on the Claude, Antigravity (`agy`), or Codex CLI.
- **Usage limits:** read for Claude, Codex, and Cursor where each one exposes them.

Sessions and spend are Claude Code only - the other tools do not keep comparable transcripts,
so they do not appear in those views.

## Private by design

Everything is read **locally and read-only**. Cortex never reads your credentials or tokens,
and **never sends your data anywhere**. Every number is real, pulled straight from `~/.claude`,
`git` / `gh`, and `lsof` on your own machine.

## Requirements

- macOS 15 (Sequoia) or newer.
- The `claude` CLI for the assistant; `git` / `gh` for repo + GitHub features. The app degrades
  gracefully when they are missing.
- To build: Xcode 16+ (full Liquid Glass uses the macOS 26 SDK; older toolchains fall back) and
  [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Build from source

Clone and build in about a minute:

```bash
brew install xcodegen          # one-time
xcodegen generate              # generate Cortex.xcodeproj from project.yml
open Cortex.xcodeproj          # then press Run in Xcode
```

Or from the command line:

```bash
xcodegen generate
xcodebuild -project Cortex.xcodeproj -scheme Cortex -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/Cortex-*/Build/Products/Debug/Cortex.app
```

On first launch, pick the folders Cortex should scan for local git repos (changeable anytime in
Settings). macOS asks permission the first time those folders are read: click Allow for full
repo data. Session and cost data comes from `~/.claude/projects` regardless of scan roots.

## Contributing

Contributions are genuinely welcome, from typo fixes to whole new views. See
[CONTRIBUTING.md](CONTRIBUTING.md) to build and get oriented, and [AGENTS.md](AGENTS.md) if you
are working with an AI coding agent. Be kind ([Code of Conduct](CODE_OF_CONDUCT.md)); report
security issues privately via [SECURITY.md](SECURITY.md). Architecture details live in
[CONTRACT.md](CONTRACT.md).

## License

[MIT](LICENSE).
