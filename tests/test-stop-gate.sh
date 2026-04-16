#!/usr/bin/env bash
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
codex_model: gpt-5.4
codex_effort: high
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

# Single setup_test_dir call to avoid EXIT trap overwrite and temp dir leak.
setup_test_dir

# Test 1: Default project root should be caller cwd (not plugin install dir)
T1_DIR="$TEST_DIR/t1"
mkdir -p "$T1_DIR"
setup_active_loop_fixture "$T1_DIR/project"

set +e
(
    cd "$T1_DIR/project"
    "$GATE_SCRIPT"
) > "$T1_DIR/out.txt" 2>&1
EXIT1=$?
set -e

if [[ "$EXIT1" -eq 10 ]]; then
    pass "rlcr-stop-gate default project root resolves caller repo root and blocks active loop"
else
    OUTPUT1=$(cat "$T1_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate default project root resolves caller repo root and blocks active loop" "exit 10" "exit $EXIT1; output: $OUTPUT1"
fi

if grep -q "^BLOCK:" "$T1_DIR/out.txt" 2>/dev/null; then
    pass "rlcr-stop-gate reports a real loop blocking reason"
else
    OUTPUT1=$(cat "$T1_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate reports a real loop blocking reason" "output containing BLOCK:" "$OUTPUT1"
fi

# Test 2: --project-root override works from outside target repository
T2_DIR="$TEST_DIR/t2"
mkdir -p "$T2_DIR"
setup_active_loop_fixture "$T2_DIR/project"

set +e
(
    cd "$T2_DIR"
    "$GATE_SCRIPT" --project-root "$T2_DIR/project"
) > "$T2_DIR/out.txt" 2>&1
EXIT2=$?
set -e

if [[ "$EXIT2" -eq 10 ]]; then
    pass "rlcr-stop-gate --project-root override blocks using target repo loop"
else
    OUTPUT2=$(cat "$T2_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate --project-root override blocks using target repo loop" "exit 10" "exit $EXIT2; output: $OUTPUT2"
fi

if grep -q "^BLOCK:" "$T2_DIR/out.txt" 2>/dev/null; then
    pass "rlcr-stop-gate --project-root output contains expected block reason"
else
    OUTPUT2=$(cat "$T2_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate --project-root output contains expected block reason" "output containing BLOCK:" "$OUTPUT2"
fi

# Test 3: No active loop -> gate allows exit (exit 0)
T3_DIR="$TEST_DIR/t3"
mkdir -p "$T3_DIR/empty-project"

set +e
(
    cd "$T3_DIR/empty-project"
    # Pass --project-root explicitly so the test is environment-independent:
    # CLAUDE_PROJECT_DIR (exported in Claude/Codex environments) would otherwise
    # override the cwd and inspect the active project instead of this empty dir.
    "$GATE_SCRIPT" --project-root "$T3_DIR/empty-project"
) > "$T3_DIR/out.txt" 2>&1
EXIT3=$?
set -e

if [[ "$EXIT3" -eq 0 ]]; then
    pass "rlcr-stop-gate exits 0 when no active loop exists"
else
    OUTPUT3=$(cat "$T3_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate exits 0 when no active loop exists" "exit 0" "exit $EXIT3; output: $OUTPUT3"
fi

if grep -q "^ALLOW:" "$T3_DIR/out.txt" 2>/dev/null; then
    pass "rlcr-stop-gate reports ALLOW when no active loop"
else
    OUTPUT3=$(cat "$T3_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate reports ALLOW when no active loop" "output containing ALLOW:" "$OUTPUT3"
fi

# Test 4: Default resolves to git worktree root even when invoked from a subdir
T4_DIR="$TEST_DIR/t4"
mkdir -p "$T4_DIR"
setup_active_loop_fixture "$T4_DIR/project"
mkdir -p "$T4_DIR/project/subdir/nested"

set +e
(
    cd "$T4_DIR/project/subdir/nested"
    "$GATE_SCRIPT"
) > "$T4_DIR/out.txt" 2>&1
EXIT4=$?
set -e

if [[ "$EXIT4" -eq 10 ]]; then
    pass "rlcr-stop-gate default resolves repo root from a nested subdirectory"
else
    OUTPUT4=$(cat "$T4_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate default resolves repo root from a nested subdirectory" "exit 10" "exit $EXIT4; output: $OUTPUT4"
fi

if grep -q "^BLOCK:" "$T4_DIR/out.txt" 2>/dev/null; then
    pass "rlcr-stop-gate subdirectory invocation reports BLOCK from the repo-root loop"
else
    OUTPUT4=$(cat "$T4_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate subdirectory invocation reports BLOCK from the repo-root loop" "output containing BLOCK:" "$OUTPUT4"
fi

# Test 5: --help text describes the actual default-resolution contract
set +e
"$GATE_SCRIPT" --help > "$TEST_DIR/help.txt" 2>&1
EXIT5=$?
set -e

if [[ "$EXIT5" -eq 0 ]]; then
    pass "rlcr-stop-gate --help exits 0"
else
    OUTPUT5=$(cat "$TEST_DIR/help.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate --help exits 0" "exit 0" "exit $EXIT5; output: $OUTPUT5"
fi

if grep -q "git rev-parse --show-toplevel" "$TEST_DIR/help.txt" 2>/dev/null; then
    pass "rlcr-stop-gate --help documents the git worktree root default"
else
    OUTPUT5=$(cat "$TEST_DIR/help.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate --help documents the git worktree root default" "help output mentioning 'git rev-parse --show-toplevel'" "$OUTPUT5"
fi

print_test_summary "RLCR Stop Gate Wrapper Test Summary"
exit $?
