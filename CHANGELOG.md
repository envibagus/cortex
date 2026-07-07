# Changelog

All notable changes to Cortex are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] - 2026-07-08

### Added
- **Environment page.** Scans the machine for installed developer CLIs and runtimes
  (resolved through the real login-shell PATH so version-manager installs are found),
  grouped by category with version, install source, and last-used, plus search,
  filters, and optional on-device summaries. Unrecognized tools are listed under
  Uncatalogued.
- **Cursor and Antigravity usage.** The Usage page and menu bar now track Cursor and
  Antigravity alongside Claude and Codex. Antigravity reads live per-window quota from
  its local language server (no token needed) and appears whenever it is installed.
- **Tunable menu bar.** Toggle which providers appear in the dropdown panel (Claude
  always shows; at least one stays enabled), and the panel lists every window a
  provider reports, including per-model weekly limits like Fable and Claude Design.

### Changed
- Usage page shows only the providers you have (with the rest noted and an empty state
  for none), reports used and left with both a countdown and a reset date, and the Home
  usage card lists every window Claude reports.
- Session transcripts are streamed line-by-line and unchanged files are reused across
  scans, cutting peak memory and rescan time on large histories.
- Rate-limit responses back off instead of fast-retrying, and every external tool the
  app runs is bounded by a watchdog so a misbehaving binary cannot hang a scan.
- Library pages show intentional zero-data states instead of blank panes.

## [1.0.0] - 2026-06-20

First public release.

### Added
- First-run onboarding that lets you choose the folders Cortex scans for local git
  repositories, with an editable Scan Roots list in Settings.
- Home dashboard, Sessions stats, Costs with optional monthly budget and alerts.
- Assistant backed by Claude Code, seeded with a live snapshot of your stack.
- Ports (lsof), Repos (git + GitHub via gh), and discovery of skills, agents,
  commands, rules, plugins, hooks, memory, and MCP servers across your AI tools.
- Work Graph, Command palette (cmd+K), and per-entity dashboards.
