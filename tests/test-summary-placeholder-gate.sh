#!/usr/bin/env bash
#
# Regression tests for summary placeholder gating in loop-codex-stop-hook.sh.
#
# Round summary files are pre-created as scaffold targets. The stop hook must
# reject a scaffold summary before running Codex, otherwise a contract-only
# round can be reviewed as if implementation work was attempted.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

STOP_HOOK="$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh"

setup_test_dir
export XDG_CACHE_HOME="$TEST_DIR/.cache"
mkdir -p "$XDG_CACHE_HOME"

setup_mock_codex() {
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/codex" << 'EOF'
#!/usr/bin/env bash
if [[ -n "${MOCK_CODEX_MARKER:-}" ]]; then
    : > "$MOCK_CODEX_MARKER"
fi
echo "Mainline Progress Verdict: STALLED"
echo "Final Decision: NOT COMPLETE"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/codex"
    export PATH="$TEST_DIR/bin:$PATH"
}

create_loop_fixture() {
    local repo_dir="$1"
    local summary_body="$2"

    init_test_git_repo "$repo_dir"
    printf 'plans/\n' > "$repo_dir/.gitignore"
    git -C "$repo_dir" add .gitignore
    git -C "$repo_dir" commit -q -m "Add gitignore"

    mkdir -p "$repo_dir/plans"
    cat > "$repo_dir/plans/plan.md" << 'EOF'
# Test Plan

Complete real implementation work.
EOF

    local loop_dir="$repo_dir/.humanize/rlcr/2026-03-01_00-00-00"
    mkdir -p "$loop_dir"
    cp "$repo_dir/plans/plan.md" "$loop_dir/plan.md"

    local branch base_commit
    branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)
    base_commit=$(git -C "$repo_dir" rev-parse HEAD)

    cat > "$loop_dir/state.md" << EOF
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.5
codex_effort: high
codex_timeout: 60
push_every_round: false
full_review_round: 5
plan_file: "plans/plan.md"
plan_tracked: false
start_branch: $branch
base_branch: $branch
base_commit: $base_commit
review_started: false
ask_codex_question: false
agent_teams: false
bitlesson_required: false
mainline_stall_count: 0
last_mainline_verdict: unknown
drift_status: normal
---
EOF

    printf '%s\n' "$summary_body" > "$loop_dir/round-0-summary.md"

    cat > "$loop_dir/round-0-contract.md" << 'EOF'
# Round 0 Contract

- Mainline Objective: Complete real implementation work.
- Target ACs: AC-1.
- Blocking: none.
- Queued: none.
- Success Criteria: concrete implementation evidence exists.
EOF

    cat > "$loop_dir/goal-tracker.md" << 'EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Complete real implementation work.
### Acceptance Criteria
- AC-1: Work evidence exists.
---
## MUTABLE SECTION
### Plan Version: 1 (Updated: Round 0)
#### Active Tasks
| Task | Target AC | Status | Tag | Owner | Notes |
|------|-----------|--------|-----|-------|-------|
EOF

    echo "$loop_dir"
}

run_stop_hook() {
    local repo_dir="$1"
    printf '{"hook_event_name":"Stop","cwd":"%s","session_id":"test-session","transcript_path":null}\n' "$repo_dir" \
        | CLAUDE_PROJECT_DIR="$repo_dir" "$STOP_HOOK"
}

setup_mock_codex

echo "=========================================="
echo "Summary Placeholder Gate Tests"
echo "=========================================="

# Test 1: scaffold summary blocks before Codex runs.
repo1="$TEST_DIR/repo-placeholder"
marker1="$TEST_DIR/codex-ran-placeholder"
summary_placeholder='# Round 0 Summary

## Work Completed
- [Describe what was implemented in this phase]

## Files Changed
- [List created/modified files]

## Validation
- [List tests/commands run and outcomes]'
create_loop_fixture "$repo1" "$summary_placeholder" >/dev/null
export MOCK_CODEX_MARKER="$marker1"
output1=$(run_stop_hook "$repo1")
unset MOCK_CODEX_MARKER
msg1=$(printf '%s' "$output1" | jq -r '.systemMessage // empty')
reason1=$(printf '%s' "$output1" | jq -r '.reason // empty')
if [[ "$msg1" == "Loop: Summary file still contains placeholders for round 0" ]] && \
   [[ "$reason1" == *"Work Summary Still Placeholder"* ]] && \
   [[ ! -e "$marker1" ]]; then
    pass "placeholder summary is blocked before Codex runs"
else
    fail "placeholder summary is blocked before Codex runs" "placeholder block without Codex marker" "msg=$msg1 marker=$([[ -e "$marker1" ]] && echo yes || echo no)"
fi

# Test 2: concrete summary reaches Codex review path.
repo2="$TEST_DIR/repo-concrete"
marker2="$TEST_DIR/codex-ran-concrete"
summary_concrete='# Round 0 Summary

## Work Completed
- Implemented the target change and captured validation evidence.

## Files Changed
- hooks/loop-codex-stop-hook.sh

## Validation
- bash -n hooks/loop-codex-stop-hook.sh: passed

## Remaining Items
- None.'
create_loop_fixture "$repo2" "$summary_concrete" >/dev/null
export MOCK_CODEX_MARKER="$marker2"
output2=$(run_stop_hook "$repo2")
unset MOCK_CODEX_MARKER
if [[ -e "$marker2" ]] && [[ "$output2" == *"Codex found issues"* || "$output2" == *"Mainline Progress Verdict"* ]]; then
    pass "concrete summary reaches Codex review"
else
    fail "concrete summary reaches Codex review" "Codex marker created" "marker=$([[ -e "$marker2" ]] && echo yes || echo no) output=$output2"
fi

# Test 3: concrete summary may mention scaffold tokens in prose/code blocks.
repo3="$TEST_DIR/repo-legitimate-mentions"
marker3="$TEST_DIR/codex-ran-legitimate-mentions"
summary_mentions='# Round 0 Summary

## Work Completed
- Updated documentation that explains the BitLesson template string `Action: none|add|update`.
- Added validation output that quotes `[what changed and why]` as an example literal, not as the Notes scaffold line.

## Files Changed
- prompt-template/block/work-summary-placeholder.md

## Validation
```text
The docs mention [what changed and why] in prose and Action: none|add|update in a code block.
- [List created/modified files]
Action: none|add|update
Notes: [what changed and why]
```

## Remaining Items
- None.'
create_loop_fixture "$repo3" "$summary_mentions" >/dev/null
export MOCK_CODEX_MARKER="$marker3"
output3=$(run_stop_hook "$repo3")
unset MOCK_CODEX_MARKER
if [[ -e "$marker3" ]] && [[ "$output3" == *"Codex found issues"* || "$output3" == *"Mainline Progress Verdict"* ]]; then
    pass "legitimate scaffold-token mentions reach Codex review"
else
    fail "legitimate scaffold-token mentions reach Codex review" "Codex marker created" "marker=$([[ -e "$marker3" ]] && echo yes || echo no) output=$output3"
fi

print_test_summary "Summary Placeholder Gate Test Summary"
