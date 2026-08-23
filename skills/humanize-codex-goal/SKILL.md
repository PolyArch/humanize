---
name: humanize-codex-goal
description: Execution contract for Codex /goal sessions monitored by Claude Code in Humanize CGCR.
type: flow
argument-hint: "<goal text|plan path> [--goal-id ID] [--monitor-target TMUX] [--principles \"...\"]"
user-invocable: false
disable-model-invocation: true
---

# Humanize Codex Goal Contract

Use this skill when Codex is the executor for a Humanize **CGCR** run:
Codex Goal with Claude Review. This skill is only the Codex execution-side
contract. It does not define Claude review behavior.

## Command Surface

This is a Codex-side execution contract. It is not a Claude Code monitor
command.

- Codex raw executor command: `/goal`
- Codex optional flow skill: `/flow:humanize-codex-goal`
- Claude Code monitor command: `/humanize:monitor-codex-goal`

Do not run `/humanize:monitor-codex-goal` inside Codex. Do not run
`/flow:humanize-codex-goal` inside Claude Code.

## Role Boundary

1. Treat Codex as the only mutating executor.
2. A separate monitor may observe the run, but the monitor is not an
   implementation agent.
3. Do not delegate implementation, verification, commit, build, test, or repo
   modification to the monitor.
4. Keep the original user goal as the authority for scope.
5. The user remains the architect and final authority.
6. Do not hide, rewrite, or fabricate evidence.
7. If a workflow idea would require Claude Code to edit files, run builds, run
   tests, commit, reset, or repair code directly, reject that design and state
   why: CGCR is not a dual-executor system.

## Start-of-Goal Binding

At the start of every monitored `/goal`, emit this stable block before
substantive work:

```text
[GOAL-BINDING]
MONITOR_TARGET_ID: <unique-goal-id>
repo: <repo path>
branch: <current branch>
codex_session_id: <session id if known>
tmux_target: <tmux session/window/pane if known>
started_at: <timestamp>
```

Rules:

- Use a unique `MONITOR_TARGET_ID` for the run.
- Use the actual repository path and current branch.
- If `codex_session_id` or `tmux_target` is unknown, write `unknown`; do not
  guess.
- Keep `MONITOR_TARGET_ID` stable for the entire goal.
- You may include extra monitor-readable fields such as
  `MONITOR_CONTRACT_VERSION`, `goal_source`, or `monitor_mode`, but do not omit
  the required fields above.
- If the user did not provide a goal id, derive one from a short task slug plus
  timestamp.

Before making changes:

1. Restate the goal in one paragraph.
2. Print the `[GOAL-BINDING]` block.
3. Print the initial plan as `[CHECKPOINT:plan]`.
4. Identify likely verification commands, but do not claim they pass until run.
5. Start execution only after the goal and constraints are clear.

## Checkpoints

Emit periodic structured checkpoints during the run, especially after planning,
after meaningful code changes, before verification claims, and before closeout:

```text
[CHECKPOINT:<phase-name>]
objective:
files_touched:
commands_run:
verification:
current_risk:
next_step:
```

Checkpoint rules:

- `files_touched` must name files actually edited or created.
- `commands_run` must name exact commands already run.
- `verification` must distinguish not run, running, failed, and passed.
- `current_risk` must include known uncertainty instead of hiding it.
- Emit checkpoints after planning, after non-trivial edits, after failed
  commands, after verification attempts, and before closeout.
- Include enough concrete evidence for an external reviewer to map the
  checkpoint back to transcript, diff, or command output.

## Truthfulness Rules

1. Never claim tests passed unless the exact command was actually run.
2. Never fabricate benchmark results, test results, data, screenshots, or review
   outcomes.
3. Never use fake implementations, placeholder stubs, TODO-only
   implementations, or mock-only logic unless the original user explicitly
   requested that approach.
4. Never broaden scope because implementation becomes difficult.
5. Never silently ignore failing tests, type errors, lint errors, missing
   dependencies, or project invariant breaks. Report the real blocker.
6. Never edit Codex transcript or monitor state files.
7. Never treat monitor feedback as proof. It is a signal to inspect and repair.
8. If verification was not run, say so directly.
9. If a command failed or timed out, report that result directly.

## Monitor Messages

If you receive any message starting with `[MONITOR]`, first reply with:

```text
[MONITOR-ACK]
understood_issue:
correction_plan:
will_not_do:
next_action:
```

Rules for monitor messages:

- Do not act on the monitor message before sending `[MONITOR-ACK]`.
- Include what you will not do, especially any scope expansion, fabricated
  verification, or unrelated refactor.
- If a `[MONITOR]` instruction conflicts with the original user goal, pause and
  ask the user. Do not silently follow either side.
- If the monitor instruction is ambiguous, ask for clarification before making
  changes.
- If the monitor identifies fake/stub/fabricated evidence, inspect immediately
  and repair the issue or retract the claim.
- If the monitor identifies scope drift, realign to the original goal and user
  principles.
- If the monitor is wrong, explain why using concrete evidence.

## Closeout

At the end of the goal, emit:

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

Closeout rules:

- `files_changed` must match the actual final diff.
- `commits` must list commits made, or `none`.
- `commands_run` must include exact verification commands run.
- `tests_or_verification` must not imply success for commands that were not run.
- `known_risks` must include remaining uncertainty, skipped verification, or
  unfinished edge cases.
