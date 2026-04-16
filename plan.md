# Claude-to-Codex Workflow Migration Plan

## Goal Description
Update this repository so its skills, commands, prompt templates, scripts, and documentation consistently describe and support Codex-native workflows rather than Claude-specific flow invocation patterns. Remove features that are exclusively supported by Claude when there is no valid Codex equivalent, keep the remaining Humanize workflows coherent for Codex users, and adjust automated tests so the repository validates the migrated behavior end to end.

## Acceptance Criteria

Following TDD philosophy, each criterion includes positive and negative tests for deterministic verification.

- AC-1: User-facing workflow entrypoints describe valid Codex-native invocation patterns and do not instruct users to use unsupported Claude-only flow syntax for Codex.
  - Positive Tests (expected to PASS):
    - Repository docs and skill files that describe Codex usage show Codex-compatible phrasing such as `Run the humanize-... skill with ...` or equivalent supported commands.
    - Deprecated Claude-only invocation examples are either removed from Codex-facing sections or clearly isolated as Claude-specific guidance.
    - Commands and examples remain internally consistent across `README.md`, `docs/`, `commands/`, and `skills/`.
  - Negative Tests (expected to FAIL):
    - A Codex-facing document still tells users to run `/flow:...` directly in Codex.
    - A skill claims Codex supports a Claude-only runtime behavior that does not exist in this repository.
  - AC-1.1: Claude-specific material is either removed or explicitly scoped so it does not conflict with Codex guidance.
    - Positive: `docs/install-for-claude.md` or Claude prompt-template content may remain only if it is clearly separated from Codex instructions.
    - Negative: Mixed sections present Claude syntax as the recommended Codex path.
- AC-2: Claude-exclusive functionality without a defensible Codex path is removed or neutralized everywhere it is referenced.
  - Positive Tests (expected to PASS):
    - Repository references to removed Claude-only capabilities are deleted or rewritten in the owning skill, command, script help text, and documentation.
    - Prompt templates and runtime scripts no longer depend on unsupported Claude-only control flow for the default Codex experience.
    - Any retained Claude-specific assets are non-blocking to Codex workflows and do not appear in the main Codex path.
  - Negative Tests (expected to FAIL):
    - A removed Claude-only feature is still reachable from a Codex skill or command.
    - A script or template assumes a Claude-only hook or command is mandatory for a Codex run.
- AC-3: The RLCR and related Humanize workflows remain coherent after migration, with repo references aligned to the current Codex-centered branch direction.
  - Positive Tests (expected to PASS):
    - The main loop entrypoints, setup scripts, and skill descriptions align on supported arguments and expected runtime behavior for Codex.
    - Supporting docs explain the resulting workflow without conflicting references to the old Claude-oriented process.
    - Plan-generation and plan-refinement guidance remain usable after the migration.
  - Negative Tests (expected to FAIL):
    - One file describes the loop as Codex-native while another still requires a removed Claude-only prerequisite for the same path.
    - The migrated workflow leaves dangling references to renamed, deleted, or obsolete commands.
- AC-4: Test coverage is updated to validate the migrated behavior, and the relevant test suite passes.
  - Positive Tests (expected to PASS):
    - Tests that assert command text, prompts, routing, or workflow behavior are updated to match Codex-native expectations.
    - Newly relevant regression checks are added where needed for removed Claude syntax or unsupported features.
    - The repository test command used for this migration completes successfully after the changes.
  - Negative Tests (expected to FAIL):
    - Existing tests still encode the pre-migration Claude-only wording or assumptions.
    - The updated repo passes superficial string replacements but fails integrated workflow tests.

## Path Boundaries

Path boundaries define the acceptable range of implementation quality and choices.

### Upper Bound (Maximum Acceptable Scope)
The implementation performs a repo-wide audit of user-facing and runtime-facing Claude assumptions, updates all affected skills, docs, commands, prompt templates, and tests, and leaves a coherent Codex-first workflow with no misleading references on the supported path. Obsolete Claude-only artifacts are removed only where they directly conflict with the supported Codex experience, avoiding unnecessary churn in isolated historical or optional Claude documentation.

### Lower Bound (Minimum Acceptable Scope)
The implementation fixes every active Codex-facing reference implicated by the draft, removes or disables clearly unsupported Claude-only workflow elements that block or confuse Codex usage, updates corresponding documentation, and gets the relevant automated test suite green.

### Allowed Choices
- Can use: targeted file-by-file migration, selective removal of obsolete Claude-only text, compatibility shims only if they preserve a clean Codex user experience, updates to tests and fixtures, limited retention of clearly partitioned Claude-specific docs.
- Cannot use: leaving broken Codex instructions in place, masking unsupported behavior with misleading docs, removing unrelated functionality for convenience, or skipping test updates after changing observable behavior.

## Feasibility Hints and Suggestions

> **Note**: This section is for reference and understanding only. These are conceptual suggestions, not prescriptive requirements.

### Conceptual Approach
Start with an inventory of Codex-facing entrypoints and search for Claude-specific syntax such as `/flow:` and other runtime assumptions. Classify each occurrence into one of three buckets: keep as Claude-only and explicitly scope it, rewrite to a Codex-native pattern, or remove because the capability is unsupported. Apply changes in dependency order: skills and commands first, then scripts and prompt templates that enforce behavior, then top-level docs and install guides, then tests that encode the prior behavior. Finish by running the relevant test suite and resolving failures until the migrated workflow is consistent.

### Relevant References
- `task.md` - Draft scope for the migration.
- `README.md` - Main Codex-facing user entrypoint that must stay consistent.
- `skills/humanize-gen-plan/SKILL.md` - Existing Codex-native example for skill invocation.
- `skills/humanize-rlcr/SKILL.md` - Directly cited file with Claude-vs-Codex workflow wording.
- `commands/` - User-facing command surfaces that may still encode old patterns.
- `docs/usage.md` - Primary behavior and invocation reference.
- `docs/install-for-codex.md` - Codex setup guidance that must match the migrated workflow.
- `docs/install-for-claude.md` - Candidate source of Claude-specific material that may need isolation or removal.
- `prompt-template/claude/` - Claude-specific prompt assets that must not leak into the main Codex path.
- `scripts/` and `hooks/` - Runtime behavior that may still assume Claude-exclusive flow control.
- `tests/run-all-tests.sh` and `tests/` - Regression surface for verifying the migration.

## Dependencies and Sequence

### Milestones
1. Inventory and classification: identify all Claude-specific workflow references and decide whether each should be rewritten, isolated, or removed.
   - Phase A: Search user-facing docs, skills, and commands for unsupported syntax and stale wording.
   - Phase B: Inspect scripts, hooks, and prompt templates for runtime dependencies on Claude-only behavior.
2. Codex-path migration: update the supported workflow surfaces to present one coherent Codex-native path.
   - Phase A: Rewrite skill and command invocation text.
   - Phase B: Align README and core docs with the revised behavior.
3. Removal and cleanup: eliminate unsupported Claude-only behavior from active paths and clean up linked references.
   - Phase A: Remove or isolate obsolete references in docs and templates.
   - Phase B: Adjust runtime scripts or configuration if they still expose removed behavior.
4. Verification: update tests, run the relevant suite, and fix residual mismatches.
   - Phase A: Update tests and fixtures for new wording and behavior.
   - Phase B: Run test commands and resolve failures until green.

## Task Breakdown

Each task must include exactly one routing tag:
- `coding`: implemented by the build agent
- `analyze`: executed via Codex (the installed `ask-codex.sh` helper)

| Task ID | Description | Target AC | Tag (`coding`/`analyze`) | Depends On |
|---------|-------------|-----------|----------------------------|------------|
| task1 | Audit the repository for Claude-specific invocation patterns and classify each occurrence as rewrite, isolate, or remove. | AC-1, AC-2, AC-3 | coding | - |
| task2 | Update Codex-facing skills and commands so their usage text reflects supported Codex-native invocation. | AC-1, AC-3 | coding | task1 |
| task3 | Revise top-level and installation documentation to remove conflicting Claude-first guidance from the active Codex path. | AC-1, AC-2, AC-3 | coding | task2 |
| task4 | Clean up scripts, hooks, and prompt templates that still depend on unsupported Claude-only behavior in the supported workflow. | AC-2, AC-3 | coding | task1 |
| task5 | Update or remove corresponding references in README and ancillary docs when Claude-only functionality is deleted. | AC-1, AC-2 | coding | task3, task4 |
| task6 | Update regression tests and fixtures to validate the migrated Codex-native behavior. | AC-4 | coding | task2, task3, task4, task5 |
| task7 | Run the relevant automated tests, inspect failures, and iterate until the migration is validated. | AC-4 | coding | task6 |

## Plan Convergence Record

### Agreements
- The repository is being migrated toward a Codex-centered workflow and should not present unsupported Claude flow syntax as the primary path.
- Removals must be propagated through documentation and tests rather than leaving stale references behind.
- Verification requires running tests after the migration rather than relying on text edits alone.

### Resolved Disagreements
- None at planning time.

### Convergence Status
- Final Status: `converged`

## Pending User Decisions

- None.

## Implementation Notes

### Code Style Requirements
- Implementation code and comments must NOT contain plan-specific terminology such as "AC-", "Milestone", "Step", "Phase", or similar workflow markers
- These terms are for plan documentation only, not for the resulting codebase
- Use descriptive, domain-appropriate naming in code instead
