# CGCR State Machine

Canonical state machine reference for CGCR: Codex Goal with Claude Review.
The long-form historical reference remains in
`references/codex-goal-monitor-state-machine.md`.

## States

| State | Meaning |
|-------|---------|
| `UNBOUND` | No confirmed Codex transcript and tmux pane pair exists. |
| `DISCOVERING` | Candidate sessions and panes are being enumerated. |
| `BOUND_READ_ONLY` | Exact binding is confirmed; monitor may observe. |
| `TICK_RUNNING` | A monitor tick is reading transcript, pane, and git state. |
| `CLEAN` | Tick found no monitor-worthy issue. |
| `NEEDS_NOTIFY` | Tick found a risk that should be reported without injection. |
| `DRAFT_PENDING` | A `[MONITOR]` draft exists and needs approval or reinspection. |
| `APPROVED_TO_INJECT` | User approved a fresh draft within the approval window. |
| `AUTO_INJECT_ELIGIBLE` | The automatic injection gate passed. |
| `INJECTING` | Monitor is typing, verifying, and submitting a prompt through tmux. |
| `COOLDOWN` | Injection occurred; further injection is blocked until cooldown passes. |
| `TERMINAL` | Target ended, is missing, unsafe, or impossible to bind. |

## Transitions

| From | To | Condition |
|------|----|-----------|
| `UNBOUND` | `DISCOVERING` | User supplies `--discover`. |
| `UNBOUND` | `BOUND_READ_ONLY` | Session id, tmux target, and expected goal match exactly. |
| `UNBOUND` | `TERMINAL` | Required binding data is absent and discovery is not requested. |
| `DISCOVERING` | `BOUND_READ_ONLY` | Exactly one candidate pair matches repo, timestamp, pane text, transcript, and goal id. |
| `DISCOVERING` | `NEEDS_NOTIFY` | Multiple plausible candidates require user confirmation. |
| `DISCOVERING` | `TERMINAL` | No plausible candidate exists. |
| `BOUND_READ_ONLY` | `TICK_RUNNING` | Tick starts. |
| `TICK_RUNNING` | `CLEAN` | No material issue is found. |
| `TICK_RUNNING` | `NEEDS_NOTIFY` | Risk exists, but injection is not permitted or not justified. |
| `TICK_RUNNING` | `DRAFT_PENDING` | Corrective prompt may help, but approval is required. |
| `TICK_RUNNING` | `AUTO_INJECT_ELIGIBLE` | Automatic injection gate passes. |
| `TICK_RUNNING` | `TERMINAL` | Target is missing, ended, blocked, mismatched, or unsafe. |
| `DRAFT_PENDING` | `APPROVED_TO_INJECT` | User approves draft within 10 minutes. |
| `DRAFT_PENDING` | `TICK_RUNNING` | Approval is stale; re-inspect and redraft. |
| `APPROVED_TO_INJECT` | `INJECTING` | Fresh inspection still supports the same narrow correction. |
| `AUTO_INJECT_ELIGIBLE` | `INJECTING` | Budget, cooldown, binding, and whitelist still pass. |
| `INJECTING` | `COOLDOWN` | Prompt was typed, verified, submitted, and user was notified. |
| `INJECTING` | `NEEDS_NOTIFY` | Typed text cannot be verified in the Codex input area. |
| `COOLDOWN` | `BOUND_READ_ONLY` | Cooldown expires and target remains bound. |
| `CLEAN` | `BOUND_READ_ONLY` | Periodic cadence continues. |
| `NEEDS_NOTIFY` | `BOUND_READ_ONLY` | User acknowledges and monitoring continues. |
| `NEEDS_NOTIFY` | `TERMINAL` | User declines continuation or target is unsafe. |

## Blocking Conditions

The monitor must not inject when any condition is true:

- `codex_session_id` is missing.
- `tmux_target` is missing.
- `MONITOR_TARGET_ID` is supplied but does not match.
- More than one target is plausible.
- The pane no longer appears to be the same Codex session.
- The draft is stale or based on old inspection.
- The issue is outside the automatic injection whitelist.
- `--notify-only` is set.
- A previous injection already happened in the current tick.
- Cooldown or budget blocks injection.
- The proposed correction broadens scope.
- The monitor would need to edit files, run builds, run tests, commit, reset,
  install packages, delete files, or otherwise become an executor.

