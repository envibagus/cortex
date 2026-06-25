# Contributing to Cortex

Contributions are genuinely welcome, and you do not need to be a Swift expert to help.
Typo fixes, docs, bug reports, a small UI tweak, or a whole new view are all valuable. If
you are unsure about something, open an issue or a draft pull request and ask. We would
rather help you land a change than have you not try.

This is a native macOS app, so the toolchain is Apple's. Here is everything you need.

## Quick start

```bash
brew install xcodegen          # one-time, if you do not have it
xcodegen generate              # generate Cortex.xcodeproj from project.yml
open Cortex.xcodeproj          # then press Run in Xcode
```

Or build from the command line with `scripts/build.sh`. The generated `.xcodeproj` is not
committed (`project.yml` is the source of truth), so run `xcodegen generate` after pulling.

### Good to know

- macOS 15 (Sequoia) or newer, Xcode 16 or newer. The UI uses macOS 26 Liquid Glass APIs
  behind availability checks, so the full build needs the macOS 26 SDK / Xcode 26; older
  Xcode still builds the rest with the pre-26 fallbacks.
- For full functionality at runtime, the `git`, `gh`, and `claude` CLIs help, but the app
  degrades gracefully when they are missing.

## Where things live

- `Cortex/App` - entry point, `AppModel` (owns every store), navigation, the shell.
- `Cortex/Models` - data types and formatting helpers.
- `Cortex/DesignSystem` - `Theme`, reusable components, Swift Charts wrappers.
- `Cortex/Services` - the stores that read sessions, costs, ports, repos, and config.
- `Cortex/Features` - one file per view.

`CONTRACT.md` has a deeper tour of the model types, services, and design system. Handy for
larger changes, but not required reading for a small fix.

## A few gentle guidelines

These are guidelines, not gates. Do your best and we will help with the rest.

- Try to match the surrounding code: SwiftUI, `@Observable` stores, native semantic colors,
  and the `cortex`/`Cortex` design-system naming.
- Keep the core promise intact: Cortex reads your AI stack locally and does not phone
  home. The only thing it writes outside its own storage is the optional, user-enabled
  Live Activity hook (which is reversible). Please do not add other writes to user
  config, credential exfiltration, telemetry, or a network backend.
- Keep your change focused, and include a before/after screenshot for UI work if you can.
- Keep code, comments, and commit messages professional and about this project. Please do not
  reference unrelated products or internal/personal names.

## Submitting a change

1. Fork the repo and branch off `main`.
2. Make your change and check that the app still builds and runs.
3. Open a pull request describing what you changed and why. Draft PRs are welcome if you
   want early feedback.

By contributing, you agree that your contributions are licensed under the MIT License.
