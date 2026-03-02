#!/bin/bash
#
# Tests for rlcr-stop-gate wrapper project root detection
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

GATE_SCRIPT="$SCRIPT_DIR/../scripts/rlcr-stop-gate.sh"

echo "=========================================="
echo "RLCR Stop Gate Wrapper Tests"
echo "=========================================="
echo ""

# Build a minimal active loop that should block on missing summary file.
setup_active_loop_fixture() {
    local project_dir="$1"

    init_test_git_repo "$project_dir"
    local branch
    branch=$(git -C "$project_dir" rev-parse --abbrev-ref HEAD)

    mkdir -p "$project_dir/.humanize/rlcr/2026-03-01_00-00-00"

    cat > "$project_dir/plan.md" << 'PLANEOF'
# Test Plan

Line 1
Line 2
Line 3
Line 4
PLANEOF

    cp "$project_dir/plan.md" "$project_dir/.humanize/rlcr/2026-03-01_00-00-00/plan.md"

    cat > "$project_dir/.humanize/rlcr/2026-03-01_00-00-00/state.md" <<EOF_STATE
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.2
codex_effort: xhigh
codex_timeout: 60
push_every_round: false
full_review_round: 5
plan_file: plan.md
plan_tracked: false
start_branch: $branch
base_branch: $branch
base_commit: deadbeef
review_started: false
ask_codex_question: true
session_id:
agent_teams: false
---
EOF_STATE
}

# Test 1: Default project root should be caller cwd (not plugin install dir)
setup_test_dir
setup_active_loop_fixture "$TEST_DIR/project"

set +e
(
    cd "$TEST_DIR/project"
    "$GATE_SCRIPT"
) > "$TEST_DIR/out1.txt" 2>&1
EXIT1=$?
set -e

if [[ "$EXIT1" -eq 10 ]]; then
    pass "rlcr-stop-gate default project root uses cwd and blocks active loop"
else
    OUTPUT1=$(cat "$TEST_DIR/out1.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate default project root uses cwd and blocks active loop" "exit 10" "exit $EXIT1; output: $OUTPUT1"
fi

if grep -q "^BLOCK:" "$TEST_DIR/out1.txt" 2>/dev/null; then
    pass "rlcr-stop-gate reports a real loop blocking reason"
else
    OUTPUT1=$(cat "$TEST_DIR/out1.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate reports a real loop blocking reason" "output containing BLOCK:" "$OUTPUT1"
fi

# Test 2: --project-root override works from outside target repository
setup_test_dir
setup_active_loop_fixture "$TEST_DIR/project"

set +e
(
    cd "$TEST_DIR"
    "$GATE_SCRIPT" --project-root "$TEST_DIR/project"
) > "$TEST_DIR/out2.txt" 2>&1
EXIT2=$?
set -e

if [[ "$EXIT2" -eq 10 ]]; then
    pass "rlcr-stop-gate --project-root override blocks using target repo loop"
else
    OUTPUT2=$(cat "$TEST_DIR/out2.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate --project-root override blocks using target repo loop" "exit 10" "exit $EXIT2; output: $OUTPUT2"
fi

if grep -q "^BLOCK:" "$TEST_DIR/out2.txt" 2>/dev/null; then
    pass "rlcr-stop-gate --project-root output contains expected block reason"
else
    OUTPUT2=$(cat "$TEST_DIR/out2.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate --project-root output contains expected block reason" "output containing BLOCK:" "$OUTPUT2"
fi

print_test_summary "RLCR Stop Gate Wrapper Test Summary"
exit $?
