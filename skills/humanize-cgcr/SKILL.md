---
name: humanize-cgcr
description: Codex-side launcher for Humanize CGCR. Creates the two-tmux Codex /goal plus Claude monitor topology and prepares the monitored goal prompt.
type: flow
argument-hint: "<long task prompt>"
user-invocable: false
disable-model-invocation: true
---

# Humanize CGCR Launcher

Use this flow from Codex to start Humanize CGCR: Codex Goal with Claude Review.

Repo-native Codex command:

```text
/flow:humanize-cgcr <long task prompt>
```

`/humanize:cgcr` is the public CGCR command name. In Codex startup context it
must delegate to this same Codex flow or the existing `setup-cgcr.sh` launcher
path. Claude-side monitoring may expose `/humanize:cgcr` as an alias for the
lower-level `/humanize:monitor-codex-goal` monitor behavior.

## Role Boundary

CGCR is not a dual-executor system:

- Codex is the only implementation agent.
- Claude Code is only a read-only reviewer/monitor.
- Claude Code must not edit files, run builds, run tests, commit, reset,
  install packages, or repair code directly.
- Claude feedback may enter Codex only as a gated `[MONITOR]` prompt through
  tmux.

If any approach would require Claude Code to mutate the repository, reject that
approach and keep feedback routed through the monitor protocol.

## Codex Execution Contract

The source of truth for the Codex execution-side contract is
`skills/humanize-codex-goal/SKILL.md`. This launcher must prepare prompts that
require the same lifecycle markers, and Codex must emit them during the
monitored `/goal`.

Required start marker:

```text
[GOAL-BINDING]
MONITOR_TARGET_ID: <unique-goal-id>
repo:
branch:
codex_session_id:
tmux_target:
started_at:
```

Required checkpoint marker:

```text
[CHECKPOINT:<phase-name>]
objective:
files_touched:
commands_run:
verification:
current_risk:
next_step:
```

Required monitor acknowledgement marker:

```text
[MONITOR-ACK]
understood_issue:
correction_plan:
will_not_do:
next_action:
```

Required closeout marker:

```text
[GOAL-CLOSEOUT]
outcome:
files_changed:
commits:
commands_run:
tests_or_verification:
known_risks:
followups:
```

Codex is the only implementation agent. Claude Code is reviewer/monitor only
and must remain read-only except for gated `[MONITOR]` tmux injection. If a
`[MONITOR]` message conflicts with the original goal, Codex pauses and asks the
user instead of silently following either side.

## What This Flow Starts

The setup script creates:

- a Humanize-owned resource directory under `.humanize/cgcr/<run-id>/`;
- one tmux window named `codex-goal` running a short `start-codex.sh` launcher;
- one tmux window named `claude-monitor` running `claude --dangerously-skip-permissions`;
- a prepared Codex `/goal` prompt with the CGCR monitor contract;
- a prepared Claude monitor command using `/humanize:monitor-codex-goal`.

The current Codex session only launches the topology. The new Codex tmux window
owns implementation.

## Long Prompt Startup Protocol

Long prompts are normal in CGCR. Do not type or paste the full Codex prompt into
tmux. Treat long content as files and keep tmux input short:

1. Write the task and generated `/goal` prompt into the run directory.
2. Generate `start-codex.sh` and `start-claude.sh` in the run directory.
3. Use tmux to paste and submit only the short launcher script paths.
4. Let `start-codex.sh` read `codex-goal-prompt.md` and invoke `codex`.
5. Start Claude through `start-claude.sh`, wait until the Claude prompt is
   visibly ready, paste the monitor command, verify `MONITOR_TARGET_ID` appears
   in the pane, then submit with `C-m`.

The tmux layer must not be the transport for large prompt payloads. Its job is
window orchestration and short command submission only.

## Execution

Run the setup script with the user's task text:

```bash
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/setup-cgcr.sh" --task "$ARGUMENTS"
```

If setup exits non-zero, report the error and do not continue with
implementation in the launcher session.

This flow treats the full argument string as the task prompt. Advanced options
such as `--goal-id`, `--session`, `--cadence`, `--principles`, and
`--notify-only` remain script-level options for manual shell use.

## Resource Files

The run directory contains:

- `task.md`
- `codex-goal-prompt.md`
- `claude-monitor-command.txt`
- `start-codex.sh`
- `start-claude.sh`
- `resources.json`
- `README.md`

Use `resources.json` as the local record of the `MONITOR_TARGET_ID`, tmux
session name, Codex tmux target, Claude monitor tmux target, and prompt files.

After the goal reaches terminal state, run the task-end resource recovery
script instead of manually killing panes:

```bash
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/cleanup-cgcr.sh" --session <tmux-session>
```

The cleanup script resolves `resources.json`, captures rollout evidence from
both tmux panes, writes `rollout.md`, `closeout.md`, `cleanup.json`,
`codex-pane-final.txt`, and `claude-monitor-final.txt`, verifies terminal
markers, then releases the CGCR tmux session. Use `--run-dir <dir>` or
`--resource-file <file>` when the session name is unavailable. Use `--force`
only after the user explicitly confirms cleanup despite missing terminal
markers.

## Examples

```text
/flow:humanize-cgcr implement the billing export described in docs/export-plan.md
```

```text
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/setup-cgcr.sh" --goal-id billing-export-20260606 --cadence 30m --principles "no fake data; no stubs; do not broaden scope" --task "implement the billing export"
```

## Notes

- Use `/humanize:cgcr` as the public CGCR name. The lower-level
  `/humanize:monitor-codex-goal` command remains available inside Claude Code in
  the separate monitor tmux window.
- This CGCR-only install exposes `/flow:humanize-cgcr` as the Codex-side
  launcher.
