---
name: humanize-gen-plan
description: Generate a structured implementation plan from a draft document. Validates input, checks relevance, analyzes for issues, and generates a complete plan.md with acceptance criteria.
type: flow
user-invocable: false
disable-model-invocation: true
---

# Humanize Generate Plan

Transforms a rough draft document into a well-structured implementation plan with clear goals, acceptance criteria (AC-X format), path boundaries, and feasibility suggestions.

The installer hydrates this skill with an absolute runtime root path:

```bash
{{HUMANIZE_RUNTIME_ROOT}}
```

```mermaid
flowchart TD
    BEGIN([BEGIN]) --> VALIDATE[Validate input/output paths and mode flags<br/>Run: {{HUMANIZE_RUNTIME_ROOT}}/scripts/validate-gen-plan-io.sh --input &lt;draft&gt; --output &lt;plan&gt; [--check|--no-check]]
    VALIDATE --> CHECK{Validation passed?}
    CHECK -->|No| REPORT_ERROR[Report validation error<br/>Stop]
    REPORT_ERROR --> END_FAIL([END])
    CHECK -->|Yes| READ_DRAFT[Read input draft file]
    READ_DRAFT --> CHECK_RELEVANCE{Is draft relevant to<br/>this repository?}
    CHECK_RELEVANCE -->|No| REPORT_IRRELEVANT[Report: Draft not related to repo<br/>Stop]
    REPORT_IRRELEVANT --> END_FAIL
    CHECK_RELEVANCE -->|Yes| ANALYZE[Analyze draft for:<br/>- Clarity<br/>- Consistency<br/>- Completeness<br/>- Functionality]
    ANALYZE --> HAS_ISSUES{Issues found?}
    HAS_ISSUES -->|Yes| RESOLVE[Engage user to resolve issues<br/>via AskUserQuestion]
    RESOLVE --> ANALYZE
    HAS_ISSUES -->|No| CHECK_METRICS{Has quantitative<br/>metrics?}
    CHECK_METRICS -->|Yes| CONFIRM_METRICS[Confirm metrics with user:<br/>Hard requirement or trend?]
    CONFIRM_METRICS --> GEN_PLAN
    CHECK_METRICS -->|No| GEN_PLAN[Generate structured plan:<br/>- Goal Description<br/>- Acceptance Criteria with TDD tests<br/>- Path Boundaries<br/>- Feasibility Hints<br/>- Dependencies & Milestones]
    GEN_PLAN --> WRITE[Write plan to output file<br/>using Edit tool to preserve draft]
    WRITE --> REVIEW[Review complete plan<br/>Check for inconsistencies]
    REVIEW --> INCONSISTENT{Inconsistencies?}
    INCONSISTENT -->|Yes| FIX[Fix inconsistencies]
    FIX --> REVIEW
    INCONSISTENT -->|No| CHECK_LANG{Multiple languages?}
    CHECK_LANG -->|Yes| UNIFY[Ask user to unify language]
    UNIFY --> REPORT_SUCCESS
    CHECK_LANG -->|No| REPORT_SUCCESS[Report success:<br/>- Plan path<br/>- AC count<br/>- Language unified?]
    REPORT_SUCCESS --> END_SUCCESS([END])
```

## Input Requirements

**Required Arguments:**
- `--input <path/to/draft.md>` - The draft document
- `--output <path/to/plan.md>` - Where to write the plan

**Optional Arguments:**
- `--check` - Enable integrated draft-check before plan generation and plan-check with targeted repair after plan generation. This is a request to run the semantic checkers through native Codex sub-agents.
- `--no-check` - Disable integrated check mode for this invocation, overriding `--check` and config.
- `--discussion` - Use iterative discussion mode.
- `--direct` - Use direct mode.
- `--auto-start-rlcr-if-converged` - Start RLCR automatically when discussion mode converges and check-mode gates pass.

Check mode can also be enabled by the merged `gen_plan_check` config key. Effective priority is `--no-check` > `--check` > `gen_plan_check` > default disabled.

## Check Mode Delegation Contract

When effective check mode is true, treat it as an explicit user request for sub-agent based checking. Use Codex native `spawn_agent` / `wait_agent` for semantic draft and plan checks. Do not satisfy check mode by reading checker prompt files and performing all semantic checks only in the parent session.

Payload boundary for checker sub-agents:
- Spawn checker agents with `fork_context=false`.
- Pass only the checker instructions and the exact draft or plan content needed for that checker.
- Do not pass prior conversation history, project history, or unrelated repository context.
- Close completed checker agents after collecting their final output.

### Draft-Check Phase

Run this phase after relevance passes and before creating the output plan when `EFFECTIVE_CHECK_MODE=true`.

1. Initialize `.humanize/gen-plan-check/<timestamp>/` with `plan_check_init_report_dir`.
2. Spawn one checker sub-agent for `draft-consistency-checker` and one for `draft-ambiguity-checker`.
   - The draft consistency checker receives the raw draft and the intent of `{{HUMANIZE_RUNTIME_ROOT}}/agents/draft-consistency-checker.md`.
   - The draft ambiguity checker receives the raw draft and the intent of `{{HUMANIZE_RUNTIME_ROOT}}/agents/draft-ambiguity-checker.md`.
3. Wait for both checker agents and require each to return a JSON array matching the `findings.json` schema.
4. If a checker fails or returns malformed JSON, retry that checker once with a fresh sub-agent. If it still fails, persist one `runtime-error` info finding for that checker and treat check mode as having unresolved blockers for auto-start gating.
5. Merge draft findings into `${CHECK_REPORT_DIR}/draft-findings.json`.
6. Resolve blocker findings with user clarification before generating the plan. Do not create the output file when the user aborts draft-check.

### Plan-Check Phase

Run this phase after the plan body has been written when `EFFECTIVE_CHECK_MODE=true`.

1. Run deterministic schema validation locally with `plan_check_validate_schema`.
2. Spawn one checker sub-agent for `plan-consistency-checker` and one for `plan-ambiguity-checker`.
   - The plan consistency checker receives the generated plan body and the intent of `{{HUMANIZE_RUNTIME_ROOT}}/agents/plan-consistency-checker.md`.
   - The plan ambiguity checker receives the generated plan body and the intent of `{{HUMANIZE_RUNTIME_ROOT}}/agents/plan-ambiguity-checker.md`.
3. If the primary plan findings are non-empty, spawn a `draft-plan-drift-checker` sub-agent with only the plan body, original draft content, collected clarifications, and primary findings.
4. Merge schema findings, primary semantic findings, and conditional draft-plan drift findings into `${CHECK_REPORT_DIR}/plan-findings.json`.
5. Repair blocker findings using source-of-truth precedence: explicit user answers, original draft text, repository facts discovered during planning, safe leader-agent judgment, then generated plan text.
6. If `plan_check_recheck` is enabled and repair changed bytes, repeat plan-check once in check-only mode using the same sub-agent contract.

## Plan Structure Output

The generated plan includes:

```markdown
# Plan Title

## Goal Description
Clear description of what needs to be accomplished

## Acceptance Criteria

- AC-1: First criterion
  - Positive Tests (expected to PASS):
    - Test case that should succeed
  - Negative Tests (expected to FAIL):
    - Test case that should fail

## Path Boundaries

### Upper Bound (Maximum Scope)
Most comprehensive acceptable implementation

### Lower Bound (Minimum Scope)  
Minimum viable implementation

### Allowed Choices
- Can use: allowed technologies
- Cannot use: prohibited technologies

## Dependencies and Sequence

### Milestones
1. Milestone 1: Description
   - Phase A: ...
   - Phase B: ...

## Implementation Notes
- Code should NOT contain plan terminology
```

## Validation Exit Codes

| Exit Code | Meaning |
|-----------|---------|
| 0 | Success - continue |
| 1 | Input file not found |
| 2 | Input file is empty |
| 3 | Output directory does not exist |
| 4 | Output file already exists |
| 5 | No write permission |
| 6 | Invalid arguments |
| 7 | Plan template file not found |

## Usage

```bash
# Start the flow
/flow:humanize-gen-plan --input .humanize/drafts/example.md --output .humanize/plans/example.md

# Start with integrated check mode
/flow:humanize-gen-plan --input .humanize/drafts/example.md --output .humanize/plans/example.md --check

# The flow will ask for:
# - Input draft file path
# - Output plan file path
```

Or with the skill only (no auto-execution):

```bash
/skill:humanize-gen-plan
```
