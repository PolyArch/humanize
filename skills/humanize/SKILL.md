---
name: humanize
description: CGCR-only Humanize runtime. Launches Codex Goal with Claude Review and keeps Claude read-only.
user-invocable: false
disable-model-invocation: true
---

# Humanize - CGCR Only

Humanize is configured here as a CGCR-only runtime: Codex executes the work in
`/goal`, while Claude Code monitors as a read-only reviewer.

## Runtime Root

The installer hydrates this skill with an absolute runtime root path:

```bash
{{HUMANIZE_RUNTIME_ROOT}}
```

All command examples below use `{{HUMANIZE_RUNTIME_ROOT}}`.

## Active Workflow

### CGCR - Codex Goal with Claude Review

CGCR is the only workflow exposed by this Humanize setup.

- Codex is the only implementation agent.
- Claude Code is a read-only reviewer and monitor.
- Claude Code must not edit files, build, test, commit, reset, install
  packages, or repair code directly.
- Feedback flows only through gated `[MONITOR]` tmux injection.
- If monitor feedback conflicts with the original goal, Codex pauses and asks
  the user instead of silently following either side.

Use the Codex flow command to start the two-tmux topology:

```text
/flow:humanize-cgcr <long task prompt>
```

`/humanize:cgcr` remains the public CGCR command name for the Claude-side
monitor wrapper. In Codex startup context, it delegates to
`/flow:humanize-cgcr` or the installed `setup-cgcr.sh` launcher.

## Commands Reference

### Start CGCR

```bash
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/setup-cgcr.sh" --task "<long task prompt>"
```

Useful launcher options:

- `--goal-id ID` - Set an explicit `MONITOR_TARGET_ID`.
- `--session NAME` - Set an explicit tmux session name.
- `--cadence DURATION` - Monitor cadence, for example `10m`, `30m`, or `1h`.
- `--principles TEXT` - Extra monitor principles.
- `--notify-only` - Start the monitor without automatic injection.
- `--prepare-only` - Create `.humanize/cgcr` resources without starting tmux.

## Runtime Files

CGCR stores run data in `.humanize/cgcr/<run-id>/`:

```text
.humanize/
└── cgcr/
    └── <run-id>/
        ├── task.md
        ├── codex-goal-prompt.md
        ├── claude-monitor-command.txt
        ├── resources.json
        └── README.md
```

Use `resources.json` as the local record of the `MONITOR_TARGET_ID`, tmux
session name, Codex target, Claude monitor target, and prompt files.

## Prerequisites

- `codex` - OpenAI Codex CLI for the implementation session.
- `claude` - Claude Code for read-only monitoring.
- `tmux` - Required for the two-window CGCR topology and gated monitor
  injection.

## Scope

This setup intentionally exposes no other Humanize workflows. Keep additional
entrypoints unregistered unless a separate install mode explicitly asks for
them.
