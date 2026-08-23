# CGCR

CGCR means Codex Goal with Claude Review. It is the reverse workflow for
Humanize's existing RLCR loop, and it does not replace RLCR.

## Role Split

| Workflow | Executor | Reviewer | Feedback path | Command |
|----------|----------|----------|---------------|---------|
| RLCR | Claude Code | Codex | Codex review result -> Claude loop | `/humanize:start-rlcr-loop` |
| CGCR | Codex `/goal` or `/flow:humanize-cgcr` | Claude Code | Claude monitor -> gated `[MONITOR]` tmux injection | `/humanize:cgcr` |

RLCR:

- RLCR = Claude Code implements, Codex reviews.
- Executor: Claude Code
- Reviewer: Codex
- Feedback path: Codex review result -> Claude loop
- Command: `/humanize:start-rlcr-loop`

CGCR:

- CGCR = Codex `/goal` implements, Claude Code reviews.
- Executor: Codex `/goal` or `/flow:humanize-cgcr`
- Reviewer: Claude Code
- Feedback path: Claude monitor -> gated `[MONITOR]` tmux injection
- Command: `/humanize:cgcr`

Claude Code is read-only by default in CGCR. It is not a second executor and
must not edit files, run builds, run tests, commit, reset, install packages, or
repair code directly. Claude feedback enters Codex only as a normal `[MONITOR]`
prompt after the monitor gate.

## Command Surface

Use `/humanize:cgcr` as the public CGCR name.

- Codex-side startup delegates to `/flow:humanize-cgcr <long task prompt>`.
- Claude-side monitoring delegates to `/humanize:monitor-codex-goal`.
- Lower-level monitor details are in `commands/monitor-codex-goal.md`.
- Long-form workflow notes remain in `docs/codex-goal-claude-review.md`.

Do not use CGCR as an RLCR command. RLCR remains
`/humanize:start-rlcr-loop`.

## Tmux Layout

CGCR expects two tmux panes or windows:

- Codex pane/window: runs a short `start-codex.sh` launcher, which reads the
  prepared `/goal` prompt from `.humanize/cgcr/<run-id>/codex-goal-prompt.md`
  and starts `codex`.
- Claude monitor pane/window: runs `claude` and `/humanize:cgcr` or the
  lower-level `/humanize:monitor-codex-goal`.

Without a verified tmux target, Claude may observe transcript and git state but
must not inject.

## Long Prompt Startup Protocol

Long prompts are expected in CGCR. The tmux layer must not carry large prompt
payloads directly.

Startup uses this file-backed protocol:

1. The setup script writes the full task and generated Codex `/goal` prompt into
   `.humanize/cgcr/<run-id>/`.
2. The setup script creates executable `start-codex.sh` and `start-claude.sh`
   launchers in the same run directory.
3. tmux receives only short launcher paths, pasted through tmux buffers and
   submitted with `C-m`.
4. `start-codex.sh` reads `codex-goal-prompt.md` and invokes `codex`.
5. The Claude monitor command is pasted only after the Claude prompt is visible;
   the setup script verifies `MONITOR_TARGET_ID` is rendered before submitting.

This keeps long prompts out of tmux input while preserving the two-window CGCR
topology.

## Monitor Target

Every monitored Codex goal must have a stable `MONITOR_TARGET_ID`.

The Codex-side execution contract requires Codex to emit:

```text
[GOAL-BINDING]
MONITOR_TARGET_ID: <unique-goal-id>
repo:
branch:
codex_session_id:
tmux_target:
started_at:
```

The monitor binds by exact `codex_session_id`, exact `tmux_target`, and
`MONITOR_TARGET_ID` when supplied by `--expect-goal`.

## Exact Binding

Claude must never guess the monitored goal. A valid binding requires:

- one matching Codex transcript under `~/.codex/sessions/`;
- one verified tmux target;
- pane text that looks like the same Codex session;
- transcript content containing the current `/goal`;
- a consistent repo path across transcript, tmux, and git state;
- matching `MONITOR_TARGET_ID` when `--expect-goal` is supplied.

If discovery finds more than one plausible target, ask the user to confirm and
do not inject.

## Monitor Injection

Claude may inject only through gated tmux input. The monitor must:

1. Build the `[MONITOR]` prompt from fresh inspection.
2. Type it with `tmux send-keys -l` without Enter.
3. Capture the pane and verify the exact text landed in the Codex input area.
4. Send Enter only after verification.
5. Notify the user with the exact injected text.

Codex must reply with `[MONITOR-ACK]` before acting. If `[MONITOR]` conflicts
with the original user goal, Codex pauses and asks the user.

## Steer Prompt Selection

When the same Codex goal keeps drifting, Claude should not keep sending the same
steer shape. Before drafting a steer, Claude reconstructs the original goal,
latest user constraints, current Codex direction, and observed deviation from
fresh transcript/git/tmux evidence.

Use `hooks/cgcr-steer-prompt-hook.sh` to build the steer prompt. The precondition
for phased correction is a fresh monitor judgment that Codex is drifting.

Tick flow:

```text
judge drift
  -> no drift: continue normal monitoring and reset correction_count to 0
  -> drift: correction_count = prior_same_goal_correction_count + 1
            choose the base prompt from correction_count
            construct a fresh steer prompt from current evidence
            send it to Codex only after the monitor injection gate passes
```

The hook counts prior `[MONITOR:auto]` and `[MONITOR:approved]` prompts for the
same `MONITOR_TARGET_ID` from the current transcript when no explicit prior
count is supplied. When the current tick is clean, the monitor must not call the
hook to build a steer, or must call it with `--drift-status clean` and treat the
returned `RESET` marker as `correction_count = 0`.

When the current tick is drifting, the hook increments the prior correction
count by one and chooses the prompt shape from the current 1-based correction
count:

- simple guidance back to the original goal;
- explicit realignment with the cited mismatch;
- stop the tangent and classify work as in-scope, out-of-scope, or requiring
  user confirmation;
- Occam review: identify the simplest sufficient path and prune unnecessary
  work.

The cycle is intentionally transcript-derived. Claude does not need persistent
memory to know which shape comes next; it recomputes the count from the current
Codex transcript each tick. If the count cannot be reconstructed, Claude uses
the simple guidance shape or produces `NOTIFY` instead of guessing.

The internal selector, count, and level are not written into the injected
prompt. Codex only sees the corrective instruction, evidence, constraints, and
required `[MONITOR-ACK]`.

The hook only prints the prompt. The monitor still owns approval, tmux capture
verification, and injection.

Hook input:

```bash
hooks/cgcr-steer-prompt-hook.sh \
  --goal-id "<MONITOR_TARGET_ID>" \
  --drift-status "drift|clean" \
  --transcript "<codex-transcript-path>" \
  --mode "approved|auto" \
  --reason "<one-line reason>" \
  --deviation-class "<scope_drift|fabricated_data|fake_stub|project_invariant_break|execution_boundary>" \
  --original-goal "<freshly reconstructed original goal>" \
  --latest-user-constraints "<freshly reconstructed constraints>" \
  --current-codex-direction "<what Codex is doing now>" \
  --observed-deviation "<specific mismatch>" \
  --evidence "<fresh transcript/git/tmux evidence>"
```

Steer shapes:

| Correction Count | Shape | Use |
|------------------|-------|-----|
| `1, 5, 9, ...` | Simple guidance | Codex likely needs a light nudge back to the goal. |
| `2, 6, 10, ...` | Explicit realignment | The same goal is still drifting and needs a cited mismatch. |
| `3, 7, 11, ...` | Stop and classify | Codex needs to stop the tangent and separate in-scope, out-of-scope, and uncertain work. |
| `4, 8, 12, ...` | Occam review | Codex needs to prune branches and return to the simplest sufficient path. |

The monitor must not use the hook to provide patches or become the executor.
Every generated steer should keep Codex inside the current `/goal` and require:

```text
required_response:
Reply with [MONITOR-ACK] before acting.
```

## Failure Modes

- Missing transcript: observe only if a verified pane exists; do not inject.
- Missing tmux target: inspect transcript/git state only; do not inject.
- Multiple plausible targets: ask the user; do not guess.
- `MONITOR_TARGET_ID` mismatch: stop and notify; do not inject.
- Stale draft or approval older than 10 minutes: re-inspect and redraft.
- Scope expansion: reject the steer or ask the user.
- Target completed, blocked, or unsafe: produce a terminal monitor result and
  offer cleanup.

## References

- Long-form CGCR guide: `docs/codex-goal-claude-review.md`
- State machine: `references/cgcr-state-machine.md`
- Long-form monitor state reference:
  `references/codex-goal-monitor-state-machine.md`
