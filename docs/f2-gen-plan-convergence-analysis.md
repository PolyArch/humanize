# F2: gen-plan Claude-Codex debate and convergence (net diff analysis)

## Scope

This document analyzes the net changes in `feat/gen-plan-convergence` relative to `origin/main` using the merge-base diff range:

- Diff range: `origin/main...feat/gen-plan-convergence` (three-dot diff)
- Focus: the `gen-plan` debate + convergence workflow and its downstream execution routing in the RLCR loop
- Required sub-features covered: (a) through (e) below

Net diff files (11):

- `docs/f2-gen-plan-convergence-analysis.md`
- `docs/f2-gen-plan-convergence-analysis_zh.md`
- `commands/gen-plan.md`
- `prompt-template/plan/gen-plan-template.md`
- `commands/start-rlcr-loop.md`
- `scripts/validate-gen-plan-io.sh`
- `scripts/setup-rlcr-loop.sh`
- `hooks/loop-codex-stop-hook.sh`
- `tests/test-gen-plan.sh`
- `tests/test-task-tag-routing.sh`
- `tests/run-all-tests.sh`

## High-level outcome

F2 changes `gen-plan` from a single-pass plan generator into a structured, traceable planning pipeline that:

1. Uses Codex first to critique the draft and identify risks.
2. Has Claude produce an initial candidate plan.
3. Runs a bounded Claude <-> Codex convergence loop to resolve disagreements.
4. Produces a final plan that includes explicit debate traceability, a convergence log, and task routing tags (`coding` / `analyze`) suitable for RLCR execution.
5. Emits English output by default, with an optional `_zh` translated variant when enabled via config.

## Sub-feature analysis (a) to (e)

### (a) Claude-Codex debate flow (disagreement resolution before final plan)

Behavior:

- After Claude produces a candidate plan, a second Codex pass reviews reasonability and explicitly enumerates agreements, disagreements, required changes, optional improvements, and unresolved decision points.
- Claude revises the plan to address required changes, and disagreements are either resolved, carried to user decisions, or deferred with explicit documentation.

Where it is defined / enforced:

- `commands/gen-plan.md`
  - Phase 5: “Iterative Convergence Loop (Claude <-> Second Codex)” defines the second Codex review format (`AGREE`, `DISAGREE`, `REQUIRED_CHANGES`, `OPTIONAL_IMPROVEMENTS`, `UNRESOLVED`) and the Claude revision responsibilities.
  - Phase 6: “Resolve Unresolved Claude/Codex Disagreements” requires surfacing `needs_user_decision` items to the user (rather than silently choosing).
  - Phase 7: “Final Plan Generation” requires explicit “Debate Traceability” and a “Convergence Log”.
- `prompt-template/plan/gen-plan-template.md`
  - `## Claude-Codex Deliberation` section (Agreements + Resolved Disagreements).
  - `## Convergence Log` section (round-by-round trace).
  - `## Pending User Decisions` section (unresolved opposite opinions).
- `tests/test-gen-plan.sh`
  - Validates presence of the deliberation, convergence log, and pending decisions requirements in both the command doc and the template.

Net effect:

- The plan output must include the debate record (what each side argued, what was accepted/rejected, what remains pending), making plan quality auditable and decisions explicit.

### (b) Codex-first planning with convergence loop (Codex initial plan critique; alternation until agreement)

Behavior:

- Codex is invoked before Claude’s first candidate plan so Claude starts from a structured risk/requirements critique rather than only the draft.
- A convergence loop alternates: Codex reasonability review -> Claude revision -> convergence assessment, iterating until converged (or capped; see (d)).

Where it is defined / enforced:

- `commands/gen-plan.md`
  - Phase 3: “Codex First-Pass Analysis” runs `scripts/ask-codex.sh` first and requires a structured output (“CORE_RISKS”, “MISSING_REQUIREMENTS”, “TECHNICAL_GAPS”, “ALTERNATIVE_DIRECTIONS”, “QUESTIONS_FOR_USER”, “CANDIDATE_CRITERIA”).
  - Phase 4: Claude candidate plan v1 explicitly consumes “Codex Analysis v1”.
  - Phase 5: second Codex reasonability review + Claude revisions form the convergence loop.
  - Phase 7: `## Codex Team Workflow` in the generated plan requires documenting Batch 1 (planning Codex), Batch 2 (implementation team), and Batch 3 (review team).
- `prompt-template/plan/gen-plan-template.md`
  - `## Codex Team Workflow` section formalizes the 3-batch model for downstream execution.
- `tests/test-gen-plan.sh`
  - Checks that Phase 3 (“Codex First-Pass Analysis”) appears before Phase 4 (“Claude Candidate Plan (v1)”), enforcing “Codex-first” ordering.
  - Checks the existence of the convergence loop phase and required template sections.

Net effect:

- The planning pipeline is intentionally “Codex-first, Claude-synthesizes, Codex-challenges, Claude-revises”, with traceable artifacts and explicit convergence status.

### (c) Task-tag routing (coding/analyze) for plan tasks; routing carried into RLCR prompts

Behavior:

- Every task in the plan must be tagged with exactly one of:
  - `coding`: executed by Claude directly
  - `analyze`: executed via `/humanize:ask-codex`, then integrated back into the plan/work
- RLCR tooling (goal tracker + prompts) is updated so the routing stays visible and is repeatedly reinforced during follow-up rounds.

Where it is defined / enforced:

Plan generation side:

- `commands/gen-plan.md`
  - Phase 7 “Final Plan Generation” includes “Task Tag Requirement”: every task must be tagged `coding` or `analyze` with no other values.
  - The “Task Breakdown” table definition includes a Tag column and describes intended routing.
- `prompt-template/plan/gen-plan-template.md`
  - `## Task Breakdown` table contains the Tag column (`coding` / `analyze`) and explicitly documents how `analyze` is executed (`/humanize:ask-codex`).

RLCR execution side:

- `scripts/setup-rlcr-loop.sh`
  - Writes a goal tracker with an “Active Tasks” table that includes `Tag` and `Owner` columns.
  - Injects a `## Task Tag Routing (MUST FOLLOW)` section into `round-0-prompt.md` that defines the routing contract:
    - `coding`: Claude executes directly
    - `analyze`: Claude must execute via `/humanize:ask-codex` and integrate results
    - “Tag” and “Owner” must stay aligned in the goal tracker.
- `hooks/loop-codex-stop-hook.sh`
  - Adds `append_task_tag_routing_note()` and calls it when generating follow-up prompts, ensuring the routing reminder persists after Codex feedback and across rounds.
- `commands/start-rlcr-loop.md`
  - Documents the routing rule as a first-class part of RLCR execution (“coding -> Claude”, “analyze -> /humanize:ask-codex”) and ties it to the goal tracker columns.

Tests:

- `tests/test-task-tag-routing.sh`
  - Asserts `round-0-prompt.md` contains the routing section header (`## Task Tag Routing (MUST FOLLOW)`).
  - Asserts `round-0-prompt.md` mentions `/humanize:ask-codex`.
  - Asserts the goal tracker “Active Tasks” table has `Tag` / `Owner` columns.
  - Asserts follow-up prompts generated through the stop hook keep a routing reminder section.
- `tests/run-all-tests.sh`
  - Includes `test-task-tag-routing.sh` in the full test suite list.

Net effect:

- Task routing becomes part of the plan contract and part of the loop tooling, reducing ambiguity about who/what executes each task and ensuring the routing does not get lost after multiple iterations.

### (d) Convergence loop 3-round cap (prevents infinite debate)

Behavior:

- The Claude <-> Codex convergence loop is bounded to a maximum of 3 rounds.
- If the maximum is reached and disagreements remain, they must be carried forward explicitly as user decisions or unresolved items rather than looping indefinitely.

Where it is defined / enforced:

- `commands/gen-plan.md`
  - Phase 5 “Loop Termination Rules” includes “Maximum 3 rounds reached”.
  - Sets `PLAN_CONVERGENCE_STATUS` to `converged` or `partially_converged` depending on termination conditions.
- `tests/test-gen-plan.sh`
  - Checks that `commands/gen-plan.md` contains the explicit “Maximum 3 rounds reached” termination rule.

Net effect:

- Planning cannot stall indefinitely; unresolved opposite opinions are forced into explicit documentation and (when required) user decision prompts.

### (e) Optional `_zh` output with English-only default

Behavior:

- The default `gen-plan` output is English-only.
- A Chinese-only translated companion file is produced only when explicitly enabled:
  - Config: `.humanize/config.json` with `"chinese_plan": true`
  - Output: a second file with `_zh` inserted before the extension (e.g., `plan.md` -> `plan_zh.md`)
- The `_zh` file is a translation view of the English plan; identifiers remain unchanged and the original draft section is not re-translated.

Where it is defined / enforced:

- `commands/gen-plan.md`
  - Phase 0.5 loads `.humanize/config.json` and extracts the boolean `chinese_plan`; malformed JSON should warn and fall back to disabled.
  - Phase 8 Step 4 defines the `_zh` file naming algorithm and content constraints (identifiers unchanged; no new information; draft preserved as-is).
  - The default behavior is to not create `_zh` unless `CHINESE_PLAN_ENABLED=true`.
- `prompt-template/plan/gen-plan-template.md`
  - `## Output File Convention` and “Chinese-Only Variant (`_zh` file)” section documents the same enablement and naming rules and clarifies “missing config is not an error”.
- `tests/test-gen-plan.sh`
  - Enforces English-only content (no CJK / emoji) in the `commands/gen-plan.md` command content, aligning the default planning instruction set with English-only output expectations.

Net effect:

- The main planning artifact stays English by default; teams that want a Chinese reading copy can opt in without changing identifiers or introducing ambiguity.

## Net diff by file (what changed)

- `commands/gen-plan.md`
  - Adds a multi-phase planning pipeline: config load for `_zh`, IO validation, relevance check, Codex-first analysis, Claude candidate plan, bounded convergence loop, explicit disagreement resolution, and final plan generation requirements.
  - Adds optional `--auto-start-rlcr-if-converged` behavior and gating conditions.
- `prompt-template/plan/gen-plan-template.md`
  - Expands the plan skeleton to include task routing tags, a 3-batch Codex workflow section, deliberation trace sections, convergence log, pending user decisions, and `_zh` output convention notes.
- `commands/start-rlcr-loop.md`
  - Documents task-tag routing as an explicit RLCR execution rule and ties it to goal tracking.
- `scripts/validate-gen-plan-io.sh`
  - Locates the plan template via `CLAUDE_PLUGIN_ROOT` (with script-relative fallback), fails with exit code `7` if missing, and composes the output plan by copying the template then appending the original draft.
- `scripts/setup-rlcr-loop.sh`
  - Updates goal tracker “Active Tasks” to include `Tag` and `Owner`.
  - Injects a strict routing section into `round-0-prompt.md`.
- `hooks/loop-codex-stop-hook.sh`
  - Appends a task-tag routing reminder into follow-up prompts so routing instructions persist across rounds.
- `tests/test-gen-plan.sh`
  - Adds validations for Codex-first ordering, convergence loop presence, 3-round cap, required plan template sections, and English-only command content.
- `tests/test-task-tag-routing.sh`
  - Adds coverage for routing instructions in prompts and goal tracker, plus persistence via stop hook.
- `tests/run-all-tests.sh`
  - Adds the new test suite(s) to the parallel test runner list.

## Per-commit breakdown (F2 cherry-picks)

Notes:

- Commits `5156a05` and `002308a` are a revert pair (net zero).
- Several commits touched version files (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `README.md`) during development, but the net diff range for this branch does not include version changes (see “Version policy note”).

| SHA | Subject | Files changed (as recorded per commit) |
|---|---|---|
| c283a92 | feat: add claude-codex debate flow to gen-plan | `.claude-plugin/marketplace.json`<br>`.claude-plugin/plugin.json`<br>`README.md`<br>`commands/gen-plan.md`<br>`prompt-template/plan/gen-plan-template.md`<br>`tests/test-gen-plan.sh` |
| 9c0eef7 | feat: make gen-plan codex-first with convergence loop | `.claude-plugin/marketplace.json`<br>`.claude-plugin/plugin.json`<br>`README.md`<br>`commands/gen-plan.md`<br>`prompt-template/plan/gen-plan-template.md`<br>`tests/test-gen-plan.sh` |
| 5156a05 | Add plan-type routing for Claude vs Codex execution | `README.md`<br>`commands/start-rlcr-loop.md`<br>`hooks/lib/loop-common.sh`<br>`hooks/loop-codex-stop-hook.sh`<br>`scripts/setup-rlcr-loop.sh`<br>`tests/run-all-tests.sh`<br>`tests/test-plan-type-routing.sh` |
| 002308a | Revert "Add plan-type routing for Claude vs Codex execution" | `README.md`<br>`commands/start-rlcr-loop.md`<br>`hooks/lib/loop-common.sh`<br>`hooks/loop-codex-stop-hook.sh`<br>`scripts/setup-rlcr-loop.sh`<br>`tests/run-all-tests.sh`<br>`tests/test-plan-type-routing.sh` |
| 8ba3a57 | Implement task-tag routing for coding/analyze execution | `README.md`<br>`commands/gen-plan.md`<br>`commands/start-rlcr-loop.md`<br>`hooks/loop-codex-stop-hook.sh`<br>`prompt-template/plan/gen-plan-template.md`<br>`scripts/setup-rlcr-loop.sh`<br>`tests/run-all-tests.sh`<br>`tests/test-gen-plan.sh`<br>`tests/test-task-tag-routing.sh` |
| 437567b | Enhance gen-plan with ultrathink and converged auto-start | `README.md`<br>`commands/gen-plan.md`<br>`prompt-template/plan/gen-plan-template.md`<br>`scripts/validate-gen-plan-io.sh`<br>`tests/test-gen-plan.sh` |
| 3c8caf5 | feat: cap gen-plan convergence loop to 3 rounds | `.claude-plugin/marketplace.json`<br>`.claude-plugin/plugin.json`<br>`README.md`<br>`commands/gen-plan.md`<br>`tests/test-gen-plan.sh` |
| 4a57429 | feat: add _zh bilingual file output option to gen-plan pipeline (task8) | `commands/gen-plan.md`<br>`prompt-template/plan/gen-plan-template.md` |
| 821f225 | fix: switch gen-plan default to English-only with optional _zh variant via config | `.claude-plugin/marketplace.json`<br>`.claude-plugin/plugin.json`<br>`README.md`<br>`commands/gen-plan.md`<br>`prompt-template/plan/gen-plan-template.md`<br>`tests/test-gen-plan.sh` |

## Version policy note (deferred)

Per the runbook policy referenced in the task context (section 4.5), version bump alignment is intentionally deferred to upstream maintainer decision.

In this repository snapshot:

- The net diff range `origin/main...feat/gen-plan-convergence` does not include any version-file changes.
- Version files remain at the merge-base value (1.12.1 in `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`), even though some intermediate commits updated them during development.

## `_zh` output note

A Chinese translation variant is supported as a separate `_zh` output file when enabled via `.humanize/config.json` (`"chinese_plan": true`). The default behavior is English-only output with no `_zh` file generated.
