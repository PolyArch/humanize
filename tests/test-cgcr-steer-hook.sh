#!/usr/bin/env bash
#
# Tests for the CGCR steer prompt hook.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

HOOK="$PROJECT_ROOT/hooks/cgcr-steer-prompt-hook.sh"

run_hook() {
    "$HOOK" \
        --goal-id cgcr-goal-1 \
        --reason "scope drift detected" \
        --deviation-class scope_drift \
        --original-goal "Implement the CSV export requested by the user" \
        --latest-user-constraints "no fake data; no stubs" \
        --current-codex-direction "Refactoring unrelated authentication code" \
        --observed-deviation "Codex edited auth files unrelated to CSV export" \
        --evidence "transcript shows unrelated auth refactor" \
        "$@"
}

assert_contains_text() {
    local text="$1"
    local needle="$2"
    local desc="$3"
    if printf '%s' "$text" | grep -qF -- "$needle"; then
        pass "$desc"
    else
        fail "$desc" "$needle" "$text"
    fi
}

assert_not_contains_regex() {
    local text="$1"
    local pattern="$2"
    local desc="$3"
    if printf '%s' "$text" | grep -qiE "$pattern"; then
        fail "$desc" "absent pattern: $pattern" "$text"
    else
        pass "$desc"
    fi
}

echo "=========================================="
echo "CGCR Steer Hook Tests"
echo "=========================================="
echo ""

if [[ -x "$HOOK" ]]; then
    pass "cgcr steer hook is executable"
else
    fail "cgcr steer hook is executable" "executable" "missing or not executable"
fi

output="$(run_hook --correction-count 0)"
assert_contains_text "$output" "[MONITOR:approved]" "default mode is approved"
assert_contains_text "$output" "Return attention to the original goal" "prior count 0 increments to correction 1 and selects simple guidance"
assert_not_contains_regex "$output" "steer_level|previous_steer_count|why_this_level|reset_condition" "prompt does not expose selector metadata"

output="$(run_hook --correction-count 1)"
assert_contains_text "$output" "Identify the exact mismatch" "prior count 1 increments to correction 2 and selects explicit realignment"
assert_not_contains_regex "$output" "steer_level|previous_steer_count|why_this_level|reset_condition" "realignment prompt hides selector metadata"

output="$(run_hook --correction-count 2)"
assert_contains_text "$output" "Classify the current work into:" "prior count 2 increments to correction 3 and selects stop-and-classify"
assert_contains_text "$output" "Work that directly supports the original goal" "stop-and-classify prompt includes in-scope category"

output="$(run_hook --correction-count 3)"
assert_contains_text "$output" "perform an Occam review" "prior count 3 increments to correction 4 and selects Occam review"
assert_contains_text "$output" "simplest sufficient path" "Occam prompt asks for simplest path"

output="$(run_hook --correction-count 4)"
assert_contains_text "$output" "Return attention to the original goal" "prior count 4 increments to correction 5 and wraps back to simple guidance"

output="$(run_hook --mode auto --correction-count 0)"
assert_contains_text "$output" "[MONITOR:auto]" "auto mode emits auto monitor tag"

output="$(run_hook --drift-status clean --correction-count 3)"
assert_contains_text "$output" "RESET:" "clean tick emits reset marker instead of steer prompt"
assert_contains_text "$output" "correction_count: 0" "clean tick resets correction count to zero"
assert_not_contains_regex "$output" "\\[MONITOR:" "clean tick does not emit monitor injection prompt"

TEST_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

TRANSCRIPT="$TEST_DIR/transcript.txt"
cat > "$TRANSCRIPT" <<'EOF'
[MONITOR:approved]
goal_id: cgcr-goal-1
reason: prior finding
[/MONITOR]

[MONITOR:auto]
goal_id: other-goal
reason: other goal
[/MONITOR]

[MONITOR:auto]
goal_id: cgcr-goal-1
reason: second prior finding
[/MONITOR]
EOF

output="$(run_hook --transcript "$TRANSCRIPT")"
assert_contains_text "$output" "Classify the current work into:" "transcript-derived prior count 2 increments to correction 3 prompt"

if "$HOOK" --goal-id cgcr-goal-1 --correction-count not-a-number >/tmp/cgcr-steer-invalid.out 2>/tmp/cgcr-steer-invalid.err; then
    fail "invalid correction count fails" "non-zero exit" "exit 0"
else
    pass "invalid correction count fails"
fi

if "$HOOK" --goal-id cgcr-goal-1 --drift-status maybe >/tmp/cgcr-steer-invalid-drift.out 2>/tmp/cgcr-steer-invalid-drift.err; then
    fail "invalid drift status fails" "non-zero exit" "exit 0"
else
    pass "invalid drift status fails"
fi

print_test_summary "CGCR Steer Hook Tests"
