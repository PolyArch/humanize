# Codex Goal with Claude Review

Humanize's existing workflow is RLCR. CGCR is a new optional reverse workflow.
It does not replace RLCR.

## Current RLCR

RLCR means Ralph-Loop with Codex Review:

- Claude Code implements.
- Codex reviews.
- Existing command: `/humanize:start-rlcr-loop`

RLCR remains the default documented loop for Humanize.

## New CGCR

CGCR means Codex Goal with Claude Review:

- Codex `/goal` implements.
- Claude Code reviews and monitors.
- Public command: `/humanize:cgcr`
- Lower-level Claude Code monitor command: `/humanize:monitor-codex-goal`
- New Codex launcher flow: `/flow:humanize-cgcr`

Claude must be a reviewer with an injection protocol, not a second executor.
CGCR is not a dual-executor system.

## Command Surfaces

Do not mix Claude Code commands with Codex commands.

| Side | Command | Purpose |
|------|---------|---------|
| Claude Code | `/humanize:start-rlcr-loop` | Start RLCR: Claude implements, Codex reviews |
| Claude Code | `/humanize:cgcr` | Public CGCR monitor wrapper |
| Claude Code | `/humanize:monitor-codex-goal` | Lower-level CGCR monitoring |
| Codex | `/goal` | Execute the CGCR implementation goal |
| Codex | `/flow:humanize-codex-goal` | Optional Codex-side CGCR execution contract |
| Codex | `/flow:humanize-cgcr` | Start the two-tmux CGCR launcher |
| Codex | `/flow:humanize-rlcr` | Codex-side RLCR flow entrypoint when installed |

The Claude Code monitor command may observe a Codex `/goal` pane, but it must
not be typed into that Codex pane. The Codex `/goal` command starts execution,
but it must not be used as the Claude Code monitor command.

## Difference Table

| Workflow | Executor | Reviewer | Feedback path | Boundary |
|----------|----------|----------|---------------|----------|
| RLCR | Claude Code | Codex | Codex review result -> Claude loop | hook-managed loop |
| CGCR | Codex `/goal` | Claude Code | Claude monitor -> gated `[MONITOR]` tmux injection | read-only monitor contract |

## Recommended Tmux Layout

CGCR is designed around two tmux panes or windows:

- Codex pane/window: runs `codex` and the implementation `/goal`.
- Claude monitor pane/window: runs `claude` and `/humanize:cgcr` or the
  lower-level `/humanize:monitor-codex-goal`.

The Claude monitor must observe and, only after the gate passes, inject a normal
`[MONITOR]` prompt into the Codex tmux pane. Without a verified tmux target,
Claude may inspect transcript/git state, but must not inject.

```bash
tmux new -s humanize -n codex-goal
codex
```

```bash
tmux new-window -t humanize -n claude-monitor
claude
```

## Recommended Codex /goal Header

Include this in the Codex `/goal` prompt:

```text
MONITOR_TARGET_ID: <unique-goal-id>

MONITOR CONTRACT:
A separate Claude Code monitor may observe this run through transcript,
git diff/log/status, and tmux pane.
If a message starts with [MONITOR], reply with [MONITOR-ACK] before acting.
Never claim tests passed unless exact commands were run.
Do not use fake data, placeholder stubs, fabricated results, or TODO-only code unless explicitly requested.
```

The `humanize-codex-goal` skill gives Codex the full execution-side contract,
including `[GOAL-BINDING]`, `[CHECKPOINT:<phase-name>]`, `[MONITOR-ACK]`, and
`[GOAL-CLOSEOUT]` blocks.

Codex-side alternative when the Codex skill runtime is installed:

```text
/flow:humanize-codex-goal <goal text or plan path>
```

## Simplified Codex Launcher

When the Codex skill runtime is installed, start the full two-tmux topology from
Codex:

```text
/humanize:cgcr <your long task prompt>
```

In Codex startup context this public command delegates to:

```text
/flow:humanize-cgcr <your long task prompt>
```

This creates `.humanize/cgcr/<run-id>/`, starts a Codex `codex-goal` tmux
window through a short `start-codex.sh` launcher, and starts a Claude
`claude-monitor` tmux window through a short `start-claude.sh` launcher.
The full task and generated `/goal` prompt stay in run-dir files such as
`codex-goal-prompt.md`; tmux only receives short launcher paths.

The Claude monitor command is also staged as run-dir data. The setup script
waits for the Claude prompt to become visible, pastes the monitor command
through a tmux buffer, verifies the expected goal id appears in the pane, and
then submits with `C-m`.

## Starting The Monitor

Run these commands in Claude Code, not in Codex.
Use them from the separate Claude monitor tmux pane/window.

Prefer explicit binding:

```text
/humanize:cgcr <session-id> <tmux-target> \
  --expect-goal <goal-id> \
  --manual-loop \
  --notify-only
```

Use discovery only to identify candidates:

```text
/humanize:cgcr --discover --notify-only
```

Periodic monitoring is optional:

```text
/humanize:cgcr <session-id> <tmux-target> \
  --expect-goal <goal-id> \
  --cadence 30m \
  --principles "no fake data; no stubs; do not broaden scope"
```

`--once`, `--no-cron`, and `--manual-loop` are equivalent one-tick modes.
`--notify-only` controls intervention authority only; it does not control
scheduling.

When one-tick mode is not set, Claude Code may use built-in `CronCreate` to
schedule recurring monitor ticks. The cron prompt must re-enter
`/humanize:cgcr` or `/humanize:monitor-codex-goal` with `--once` or
`--no-cron`, so a scheduled tick does not create another cron. Stop scheduled
monitoring with `CronDelete` and the job id returned by `CronCreate`.

## Corrective Steer Shape

When Claude detects drift for the same `MONITOR_TARGET_ID`, it builds the
corrective `[MONITOR]` prompt with `hooks/cgcr-steer-prompt-hook.sh`.

The precondition is explicit: first judge whether Codex is drifting. If not,
Claude continues normal monitoring and resets the same-goal correction count to
0. If Codex is drifting, Claude increments the prior same-goal correction count
by 1, chooses the base prompt from that current count, and constructs a fresh
steer from current evidence.

The hook is read-only. It counts prior same-goal `[MONITOR:auto]` and
`[MONITOR:approved]` prompts from the current transcript when no explicit prior
count is supplied. The current 1-based correction count chooses one of four
prompt shapes:

1. simple guidance back to the original goal;
2. explicit realignment with the cited mismatch;
3. stop the tangent and classify current work;
4. Occam review to choose the simplest sufficient path.

The selected prompt does not mention its internal selector or count. Claude must
still pass the normal binding, approval, and tmux injection gates before sending
the prompt.

## Failure Modes

- Multiple Codex sessions: discovery may find more than one plausible target.
  Ask the user to confirm; do not guess.
- Transcript missing: observe only the tmux pane if available; do not inject.
- Tmux target missing: inspect transcript and git state only; do not inject.
- Goal marker mismatch: stop and notify; do not inject.
- Stale approval: if approval is older than 10 minutes, re-inspect and redraft.
- Notification fatigue: prefer concise evidence and reserve notifications for
  material risks.
- Scope expansion: monitor feedback must not broaden the original user goal.
- Codex finished or blocked: produce a terminal monitor result and offer cleanup.

## Safety Principle

Claude Code in CGCR is a reviewer with an injection protocol, not an autonomous
coding agent. It may observe transcript, git diff/log/status, and the tmux pane.
It must not edit the repository, build, test, commit, reset, install packages,
delete files, or directly implement changes.

If a design or implementation idea requires Claude Code to mutate the repo, run
builds, run tests, commit, reset, or repair code directly, reject that design and
document why. Claude feedback may enter Codex only as a normal `[MONITOR]`
prompt through tmux after the monitor gate.
