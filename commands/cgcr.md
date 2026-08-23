---
description: "Canonical CGCR command wrapper"
argument-hint: "[--discover] [<codex-session-id> <tmux-target>] [--expect-goal <MONITOR_TARGET_ID>] [--cadence 1h] [--notify-only] [--manual-loop|--once|--no-cron] [--budget 0.1] [--principles \"extra rules\"]"
allowed-tools:
  - "Read"
  - "Bash(git status:*)"
  - "Bash(git diff:*)"
  - "Bash(git log:*)"
  - "Bash(git show:*)"
  - "Bash(rg:*)"
  - "Bash(grep:*)"
  - "Bash(jq:*)"
  - "Bash(tail:*)"
  - "Bash(head:*)"
  - "Bash(sed:*)"
  - "Bash(ls:*)"
  - "Bash(find:*)"
  - "Bash(stat:*)"
  - "Bash(wc:*)"
  - "Bash(python3:*)"
  - "Bash(tmux list-windows:*)"
  - "Bash(tmux list-panes:*)"
  - "Bash(tmux capture-pane:*)"
  - "Bash(tmux display-message:*)"
  - "Bash(tmux has-session:*)"
  - "Bash(tmux send-keys:*)"
  - "Bash(${CLAUDE_PLUGIN_ROOT}/hooks/cgcr-steer-prompt-hook.sh:*)"
  - "Bash(date:*)"
  - "AskUserQuestion"
  - "CronCreate"
  - "CronDelete"
  - "PushNotification"
---

# CGCR

Run `/humanize:cgcr` as the public Humanize command name for CGCR: Codex Goal
with Claude Review.

This command is CGCR, not RLCR.

- RLCR = Claude Code implements, Codex reviews.
- CGCR = Codex `/goal` implements, Claude Code reviews and monitors.

## Delegation

Do not create a second CGCR implementation path.

- For Codex-side startup, `/humanize:cgcr <long task prompt>` must delegate to
  `/flow:humanize-cgcr <long task prompt>` or the existing
  `scripts/setup-cgcr.sh` launcher path.
- For Claude-side monitoring, `/humanize:cgcr` is a public alias for the
  existing lower-level `/humanize:monitor-codex-goal` command and must apply the
  `monitor-codex-goal` skill exactly.
- Lower-level monitor details remain documented in
  `commands/monitor-codex-goal.md`.

## Role Boundary

CGCR is not a dual-executor system.

- Codex is the only implementation agent.
- Claude Code is a read-only reviewer/monitor.
- Claude Code must not edit files, run builds, run tests, commit, reset,
  install packages, or repair code directly.
- Claude feedback may enter Codex only through a gated `[MONITOR]` tmux
  injection after exact binding and the monitor decision gate.

If any approach would require Claude Code to mutate the repository, reject it
and route feedback through the monitor protocol.

When Claude drafts a corrective steer prompt, use the CGCR steer prompt hook in
`hooks/cgcr-steer-prompt-hook.sh`. The monitor first judges whether Codex is
drifting. If not, normal monitoring continues and the same-goal correction count
resets to 0. If it is drifting, the prior same-goal correction count increments
by 1, that current 1-based count selects the base prompt, and the hook prints
the `[MONITOR]` prompt. It does not inject into tmux or mutate repository files.

## Required Behavior

When monitoring, parse `$ARGUMENTS` exactly like
`/humanize:monitor-codex-goal`:

```text
<codex-session-id> <tmux-target>
  [--discover]
  [--expect-goal <MONITOR_TARGET_ID>]
  [--cadence 1h]
  [--notify-only]
  [--manual-loop | --once | --no-cron]
  [--budget 0.1]
  [--principles "<extra rules>"]
```

Use explicit `codex_session_id`, `tmux_target`, and `--expect-goal` when
available. Use `--discover` only to enumerate candidates, and fail closed on
ambiguous binding.

`--notify-only` disables automatic injection. `--manual-loop`, `--once`, and
`--no-cron` mean run one tick without scheduling. `--budget` controls automatic
injection risk tolerance.

## Examples

Discover candidates without injection:

```text
/humanize:cgcr --discover --notify-only
```

Manual single tick:

```text
/humanize:cgcr <codex-session-id> <tmux-target> \
  --expect-goal <goal-id> \
  --manual-loop \
  --notify-only
```

Periodic monitor:

```text
/humanize:cgcr <codex-session-id> <tmux-target> \
  --expect-goal <goal-id> \
  --cadence 30m \
  --principles "no fake data; no stubs; do not broaden scope"
```
