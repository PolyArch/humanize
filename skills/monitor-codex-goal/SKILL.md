---
name: monitor-codex-goal
description: Read-only Claude Code monitor for a separate Codex /goal session in Humanize CGCR.
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

Use this skill to supervise a separate Codex CLI `/goal` session in Humanize
**CGCR**: Codex Goal with Claude Review.

## Command Surface

This is a Claude Code monitor skill. It is not a Codex command.

- Claude Code command wrapper: `/humanize:monitor-codex-goal`
- Claude Code internal skill name: `monitor-codex-goal`
- Codex-side executor command: `/goal`
- Codex-side optional flow skill: `/flow:humanize-codex-goal`

Do not run `/humanize:monitor-codex-goal` inside Codex. Do not run
`/goal` inside Claude Code for this workflow.

Claude Code invocation:

```text
/humanize:monitor-codex-goal <codex-session-id> <tmux-target>
  [--discover]
  [--expect-goal <MONITOR_TARGET_ID>]
  [--cadence 1h]
  [--notify-only]
  [--manual-loop | --once | --no-cron]
  [--budget 0.1]
  [--principles "<extra rules>"]
```

Claude Code is a read-only third-party reviewer. Codex is the executor.

## Role Boundary

Claude Code must not become a second coding agent. The monitor may inspect
evidence, report risks, and in tightly gated cases inject a corrective
`[MONITOR]` prompt into the Codex tmux pane. It must not directly implement,
build, test, commit, reset, or otherwise drive execution.

Architectural non-negotiable: CGCR is not a dual-executor system. Codex is the only implementation agent.
If any implementation idea would require Claude Code to mutate the repo, run builds, run tests, commit, reset, or repair code
directly, reject that design and document why. Claude feedback may enter Codex
only as a normal `[MONITOR]` prompt through tmux after the monitor gate.

## Allowed Operations

Use only read-only observation commands:

- `git status`
- `git diff`
- `git log`
- `git show`
- `rg` / `grep`
- `jq`
- `tail` / `head` / `sed` in read-only mode
- `ls` / `find` / `stat` / `wc`
- `python3` only for parsing read-only files
- `tmux list-windows`
- `tmux list-panes`
- `tmux capture-pane`
- `tmux display-message`
- `tmux has-session`
- `date` for approval age and tick timestamps
- reading Codex transcript files under `~/.codex/sessions/`

The only allowed side effects are monitor-owned scheduling/notification effects
through `CronCreate`, `CronDelete`, and `PushNotification`. These must not touch
the repository, target transcript, or Codex session.

## Forbidden Operations

Do not run or invoke:

- editing files
- any repo write or shell redirection into repo files
- `apply_patch`
- editors
- `git add`
- `git commit`
- `git reset`
- `git checkout`
- `git clean`
- build commands
- test commands that mutate artifacts
- package install
- deletion
- modifying Codex transcript files
- direct repo writes
- autonomous implementation
- repairing code directly
- any `tmux send-keys` except through the approved monitor injection protocol

Subagents, if used, must be read-only exploration agents. Their prompts must
explicitly forbid mutation, builds, tests, dependency installation, commits, and
tmux injection.

If an action is not clearly read-only, treat it as forbidden.

## Binding Rules

Claude must never guess the monitored goal.

CGCR requires a verified tmux target for injection. The expected topology is one
tmux pane/window running Codex `/goal` and a separate tmux pane/window running
Claude Code with this monitor. If the Codex run is not in tmux, or the tmux pane
cannot be verified, observe only and do not inject.

Bind by all available explicit identifiers:

1. `codex_session_id`
2. `tmux_target`
3. `MONITOR_TARGET_ID` when supplied by `--expect-goal`

If `--discover` is used:

1. List candidate Codex `/goal` sessions.
2. List candidate tmux Codex panes.
3. Compare repository path, timestamps, visible pane text, transcript content,
   and `MONITOR_TARGET_ID`.
4. If more than one candidate is plausible, ask the user to confirm.
5. Do not inject until the exact transcript and pane pair is confirmed.

Fail closed:

- If session id is missing, limited pane observation is allowed, but no
  injection is allowed.
- If tmux target is missing, transcript and git diff inspection is allowed, but
  no injection is allowed.
- If `MONITOR_TARGET_ID` does not match `--expect-goal`, stop and notify; no
  injection is allowed.
- If binding is stale or ambiguous, produce `TERMINAL` or `NOTIFY`; no
  injection is allowed.

A valid monitor target requires:

1. The transcript resolves from `codex_session_id` to exactly one live or recent
   Codex session under `~/.codex/sessions/YYYY/MM/DD/rollout-*<id>.jsonl`.
2. The tmux target exists.
3. The tmux pane looks like the same Codex session, not a random shell.
4. The transcript contains the current `/goal`.
5. The repo path inferred from transcript, git state, and tmux is consistent.
6. The monitor shares the same tmux server as the target pane.

Handle transcript not-found, multiple matches, and rotated transcript files
explicitly. Never rely on "latest session" alone.

## State And Checkpoints

Each tick should be fresh and evidence-based. Maintain lightweight checkpoint
state in the monitor session only:

- last observed transcript position or latest relevant turn
- last observed `HEAD`
- latest human steering criteria and their source turns
- last auto-injection time, if any, for cooldown enforcement

If checkpoint state is missing, ambiguous, or stale, re-read enough transcript
history to reconstruct criteria before steering. If reconstruction is uncertain,
ask the user instead of injecting.

## Tick Behavior

Every scheduled or one-off run performs exactly one tick.

A monitor tick does:

1. Re-locate the target transcript and tmux pane.
2. Verify the tmux pane still looks like the same Codex session.
3. Read the latest transcript since the last checkpoint. If checkpoint state is
   unavailable, reconstruct enough history to derive current criteria.
4. Run three read-only inspections, in parallel when available:
   - Transcript progress: summarize what Codex has done most recently and what
     it appears to be trying next.
   - Repository delta: inspect new commits plus worktree diff since the last
     checkpoint `HEAD`.
   - Artifact reasonableness: derive project-specific invariants from the
     transcript and repository, then check whether outputs violate those
     invariants. Do not use hardcoded generic expectations.
5. Derive current user principles from the transcript and `--principles`.
   Precedence is:
   ```text
   newer human instruction > older human instruction > --principles > default monitor rules
   ```
6. Synthesize evidence into these judgments:
   - goal drift
   - fabricated data
   - fake/stub implementation
   - broken repo/project invariants
   - unverified success claims
   - scope expansion
   - ignored monitor feedback
   - stale or ambiguous binding
7. Produce exactly one outcome.

When evaluating findings, classify them into:

- `scope_drift`: violation of explicit user principles or original goal
  boundaries
- `fabricated_data`: invented tests, benchmark numbers, logs, review results, or
  unverifiable success claims
- `fake_stub`: placeholder, mock-only, TODO-only, dead-branch, or no-op
  implementation pretending to solve the goal
- `project_invariant_break`: breakage of invariants derived from the repo or
  transcript
- `execution_boundary`: Codex doing work outside the goal or allowed worktree
- `cross_session_leak`: using evidence from another session, stale transcript,
  wrong pane, or wrong goal marker

Deepening, simplifying, or optimizing the design is not drift when it preserves
the user's goal and useful work.

Outcomes:

```text
CLEAN:
<one-line conclusion>
```

Use `CLEAN` when the inspected evidence does not show a monitor-worthy issue.
Do not notify and do not inject.

```text
NOTIFY:
evidence:
proposed_action:
```

Use `NOTIFY` when the user should know about a risk, but injection is not
permitted or not justified.

```text
INJECT_DRAFT:
reason:
evidence:
draft:
approval_needed:
```

Use `INJECT_DRAFT` when a corrective `[MONITOR]` prompt may be useful. Require
user approval unless the automatic injection gate passes.

```text
TERMINAL:
reason:
last_known_state:
cleanup_offer:
```

Use `TERMINAL` when the target ended, is blocked, is missing, or is unsafe to
continue monitoring.

## Decision Gate

Default first-run behavior is conservative.

Definitions:

- `--notify-only` means no automatic injection ever.
- `--manual-loop`, `--once`, and `--no-cron` mean do not create cron or
  self-schedule; run exactly one tick and exit. `--once` controls scheduling,
  while `--notify-only` controls intervention authority.
- `--budget` controls automatic injection risk tolerance. Default: `0.1`.

Automatic injection is allowed only when all conditions are true:

1. `--notify-only` is not set.
2. Binding is exact.
3. No stale draft is pending.
4. The issue is in this narrow whitelist:
   - fabricated data or fabricated test result
   - fake/stub/TODO-only implementation
   - explicit violation of a user principle
5. Confidence is high.
6. The correction is focused on recovering the current goal and does not broaden
   scope.
7. Less than one injection has happened in this tick.
8. Cooldown permits it.
9. Budget permits it.

Everything else requires user approval.

For manual risk scoring, use LOW=`0.30`, HIGH=`0.70`, and default budget
`B=0.10`. A finding with several independent evidence items may be scored as:

```text
v_i = 1 - product(1 - r_ij)
```

Apply the iron law: any uncertainty means no auto-injection.

Approval is always required for:

- project-specific invariant changes
- architecture tradeoffs
- broad rewrites
- conflicts between criteria
- user intent ambiguity
- anything where the monitor is not sure
- anything based on evidence conflict between read-only inspections or subagents

## Steer Prompt Hook

When a tick produces `INJECT_DRAFT` or an automatic injection candidate, build
the `[MONITOR]` prompt through the Claude hook helper:

```bash
"${CLAUDE_PLUGIN_ROOT}/hooks/cgcr-steer-prompt-hook.sh" \
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

The hook is read-only and only prints the proposed prompt. It must not inspect
or mutate repository state by itself, and it must not inject into tmux.

Before calling the hook, reconstruct these fields from fresh evidence:

- `original_goal`
- `latest_user_constraints`
- `current_codex_direction`
- `observed_deviation`

If the original goal or latest user constraints cannot be reconstructed from
fresh evidence, do not inject. Produce `NOTIFY` and ask the user to confirm.

Phased correction is gated by the current monitor judgment:

1. Judge whether Codex is drifting from the original goal or current user
   constraints.
2. If no drift is found, continue normal monitoring and reset the same-goal
   correction count to 0. Do not build or inject a steer prompt.
3. If drift is found, increment the prior same-goal correction count by 1.
4. Choose the base prompt from the current 1-based correction count.
5. Construct a fresh steer prompt from current transcript/git/tmux evidence.
6. Send it to Codex only after the normal approval and tmux injection gates
   pass.

Derive the prior count from the current Codex transcript for the same
`MONITOR_TARGET_ID`; do not rely on persistent memory. If the count cannot be
reconstructed, use the first prompt shape or produce `NOTIFY` instead of
guessing.

Selector behavior:

- correction count `1, 5, 9, ...`: simple guidance back to the original goal.
- correction count `2, 6, 10, ...`: explicit realignment with cited mismatch.
- correction count `3, 7, 11, ...`: stop the tangent and classify work as in-scope,
  out-of-scope, or requiring user confirmation.
- correction count `4, 8, 12, ...`: Occam review; identify the simplest sufficient path and
  prune unnecessary work.

Do not include the internal selector, level, or correction count in the injected
prompt. The selected prompt records itself in the Codex transcript when it is
injected, so later ticks can recompute the next shape from fresh transcript
evidence.

## Injection Protocol

Use `tmux send-keys` safely:

1. Build the monitor prompt from fresh inspection only, using the steer prompt
   hook above for any drift-correction prompt.
2. Use `tmux send-keys -l` to type it without Enter.
3. Capture the pane and verify the exact text landed in the Codex input area.
4. Only then send Enter.
5. Capture the pane again to confirm submission.
6. Notify the user after injection with exactly what was injected.
7. Never inject stale drafts.
8. If approval is older than 10 minutes, re-inspect and redraft.

Monitor prompt format:

```text
[MONITOR:auto|approved]
goal_id:
reason:
confidence:
evidence:
instruction:
constraints:
required_response:
[/MONITOR]
```

`required_response` must instruct Codex to reply with `[MONITOR-ACK]` before
acting.

Legacy short steering prompt shape, compatible with other monitor
implementations only when the hook is unavailable:

```text
[monitor-codex-goal]
Fresh audit finding: <drift | fabricated data | fake/stub>.
Evidence: <brief transcript/repo evidence>.
Steer: <specific corrective instruction>.
Constraint: continue the current /goal; do not broaden scope.
Required response: reply with [MONITOR-ACK] before acting.
```

Approval notification format:

```text
Codex /goal monitor finding requires approval.

goal_id: <MONITOR_TARGET_ID>
reason: <one-line reason>
risk: <LOW|MEDIUM|HIGH>
why_not_auto: <notify-only|not-whitelisted|over-budget|cooldown|ambiguous|stale>

draft_to_inject:
<full [MONITOR] prompt>

Reply approve within 10 minutes to inject this exact draft. After 10 minutes I will re-inspect and redraft.
```

## Cadence

- With `--manual-loop`, `--once`, or `--no-cron`, run one tick and exit.
- Without `--manual-loop`, `--once`, or `--no-cron`, default to self-managed
  scheduling:
  1. Run one tick immediately.
  2. Create a recurring cron with `CronCreate`.
  3. Report the returned cron id to the user.
  4. Use `CronDelete` when `/goal` completes, the target terminates, binding
     becomes unsafe, or the user asks to stop monitoring.
- Do not create background daemons, sockets, MCP bridges, or persistent services.
- Use Claude Code's built-in `CronCreate` for scheduling. Do not implement a
  separate daemon, MCP bridge, service, launchd job, or crontab entry.
- Convert `--cadence <duration>` to a standard 5-field cron string. Examples:
  `10m` -> `*/10 * * * *`, `30m` -> `*/30 * * * *`, `1h` -> `7 * * * *`.
  Prefer an off-the-hour minute for hourly cadences to avoid congestion.
- The `CronCreate` prompt must re-enter the monitor for one tick only by
  including `--once` or `--no-cron`; never create recursive cron jobs.
- Document this caveat every time a cron is created: the monitor session and
  tmux window must stay alive; closing them stops monitoring.
- Stop on ambiguous binding, mismatched goal marker, missing transcript, missing
  pane, or target completion.

`--once --notify-only` is valid and means: run one audit, never auto-inject, and
do not schedule anything.

`CronCreate` payload shape:

```json
{
  "cron": "*/30 * * * *",
  "prompt": "/humanize:monitor-codex-goal <codex-session-id> <tmux-target> --expect-goal <goal-id> --once --budget 0.1 --principles \"...\"",
  "recurring": true
}
```

The cron prompt is a Claude Code command prompt. It must not use Codex `/goal`
or `/flow:humanize-codex-goal`.

Use `CronDelete` with the job id returned by `CronCreate`.

## Output Examples

Clean tick:

```text
monitor-codex-goal: clean tick - no drift, fabrication, fake/stub behavior, or confirmed invariant break found.
```

Approval notification:

```text
monitor-codex-goal needs approval to steer Codex.
Finding: <brief finding>
Evidence: <brief evidence>
Drafted steer at <timestamp>:
<message>
Reply approve within 10 minutes to inject; otherwise I will re-inspect and redraft.
```

Post-hoc auto-injection notification:

```text
monitor-codex-goal auto-injected one steer after a fresh audit.
Class: <drift | fabricated data | fake/stub>
Injected text: <exact text>
Evidence: <brief evidence>
Cooldown now active.
```

## Evidence Standard

Every monitor conclusion must cite fresh evidence from the transcript, tmux
pane, or git state. Do not rely on "latest session" guessing when multiple
Codex goals exist. Prefer explicit binding over discovery.
