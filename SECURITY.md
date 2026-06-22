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

Cortex is a local, read-only macOS app. It is worth being clear about what it does and
does not touch:

- It reads on-device files (Claude Code sessions and transcripts, AI tool config
  directories, local git repositories) and runs the `git`, `gh`, `lsof`, and `claude`
  CLIs already on your machine.
- It never reads credentials, tokens, or secrets, and it never sends your data to any
  remote server. There is no telemetry and no network backend.

In-scope reports include: any path where Cortex reads outside the directories described
above, exfiltrates data, executes untrusted input, or mishandles the CLIs it shells out
to. Out of scope: vulnerabilities in the third-party CLIs themselves (`git`, `gh`,
`claude`), which should be reported to their respective projects.
