# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security problems.

Report vulnerabilities privately through GitHub:

1. Go to the repository's **Security** tab.
2. Choose **Report a vulnerability** (GitHub private vulnerability reporting).

Include what you found, the impact, and steps to reproduce. You can expect an initial
response within a few days. Once a fix is available, the advisory is published with credit
to the reporter unless you prefer to stay anonymous.

## Scope and threat model

Cortex is a local-first macOS app. It reads your AI stack on-device and, apart from one
feature you explicitly opt into, does not write to it. It is worth being clear about what
it does and does not touch:

- It reads on-device files (Claude Code sessions and transcripts, AI tool config
  directories, local git repositories) and runs the `git`, `gh`, `lsof`, and `claude`
  CLIs already on your machine.
- The usage view reads the local Claude Code / Codex OAuth token only to call those
  tools' own usage endpoints (the same requests the CLIs make) so it can show your
  remaining limits. Nothing else leaves your machine: there is no telemetry and no
  network backend.
- The one thing Cortex writes outside its own storage is the optional Live Activity
  feature. When you enable it, Cortex installs Claude Code hooks in
  `~/.claude/settings.json` (backing the file up first) plus a small hook script under
  `~/.claude/cortex/`, and removes exactly those entries when you disable it. It is off
  by default and fully reversible.

In-scope reports include: any path where Cortex reads outside the directories described
above, exfiltrates data, writes to user config beyond the opt-in Live Activity hook,
executes untrusted input, or mishandles the CLIs it shells out to. Out of scope:
vulnerabilities in the third-party CLIs themselves (`git`, `gh`, `claude`), which should
be reported to their respective projects.
