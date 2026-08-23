---
description: "Monitor a Codex /goal session with Claude read-only review"
argument-hint: "<codex-session-id> <tmux-target> [--discover] [--expect-goal <MONITOR_TARGET_ID>] [--cadence 1h] [--notify-only] [--manual-loop|--once|--no-cron] [--budget 0.1] [--principles \"extra rules\"]"
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

# Monitor Codex Goal

Run `/humanize:monitor-codex-goal` to monitor a Codex `/goal` session using the
`monitor-codex-goal` skill.

This is a Claude Code command. It is not a Codex command.

Command surfaces:

| Side | Command | Purpose |
|------|---------|---------|
| Claude Code | `/humanize:monitor-codex-goal` | Monitor/review a separate Codex run |
| Codex | `/goal` | Execute the implementation goal |
| Codex | `/flow:humanize-codex-goal` | Optional Codex-side CGCR execution contract |

Do not run the Claude command in Codex, and do not run Codex `/goal` or
`/flow:humanize-codex-goal` in Claude Code.

This is **not RLCR**.
This is also **not a dual-executor system**.

- RLCR: Claude Code implements, Codex reviews.
- CGCR: Codex `/goal` implements, Claude Code reviews.

For this command, Codex is executing. Claude Code is reviewing. Claude must stay
read-only except for gated `[MONITOR]` tmux injection through the monitor skill's
injection protocol.

If a proposed approach would require Claude Code to edit files, run builds, run
tests, commit, reset, or repair code directly, reject that approach and explain
that CGCR permits only Codex implementation plus gated monitor prompts.

When a corrective steer is needed, build the `[MONITOR]` prompt with
`hooks/cgcr-steer-prompt-hook.sh`. The monitor first judges whether Codex is
drifting. If the tick is clean, continue normal monitoring and reset the
same-goal correction count to 0. If the tick is drifting, increment the prior
same-goal correction count by 1, choose the base prompt from that current
1-based count, and print a prompt for the monitor to review, approve, or inject
through the gated tmux protocol.

## Required Behavior

1. Apply the `monitor-codex-goal` skill exactly.
2. Parse `$ARGUMENTS` as:
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
3. Never edit files, run builds, run tests, commit, reset, clean, install
   packages, or implement code.
4. Do not inject unless the monitor skill's binding and decision gate permit it.
5. Prefer explicit `codex_session_id`, `tmux_target`, and `--expect-goal` over
   discovery.
6. Fail closed on ambiguity.
7. Ask the user before injecting unless the automatic injection gate passes.
8. Treat `--once`, `--no-cron`, and `--manual-loop` as equivalent one-tick,
   no-scheduling modes. Do not overload `--notify-only` with scheduling
   semantics.
9. When scheduling periodic monitoring, use built-in `CronCreate`. The scheduled
   prompt must include `--once` or `--no-cron` so a cron tick cannot create
   another cron.
10. Use `CronDelete` for target completion, unsafe binding, or user cancellation.
    Use `PushNotification` for approval requests, terminal states, and
    post-injection reports.
11. Require the CGCR tmux topology: one tmux pane/window runs Codex `/goal`; a
    separate tmux pane/window runs Claude Code with this monitor command. Do not
    monitor a non-tmux Codex run, because injection safety depends on verifying
    and typing into the target tmux pane.

## Examples

Discover candidates without injection:

```text
/humanize:monitor-codex-goal --discover --notify-only
```

Manual single tick:

```text
/humanize:monitor-codex-goal <session-id> <tmux-target> \
  --expect-goal <goal-id> \
  --once \
  --notify-only
```

Periodic monitor:

```text
/humanize:monitor-codex-goal <session-id> <tmux-target> \
  --expect-goal <goal-id> \
  --cadence 30m \
  --principles "no fake data; no stubs; do not broaden scope"
```

## Output

Every tick must end with one of:

- `CLEAN`
- `NOTIFY`
- `INJECT_DRAFT`
- `TERMINAL`

Include concise evidence for all non-clean outcomes.
