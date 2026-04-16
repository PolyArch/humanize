#!/usr/bin/env bash
#
# Tests for build_provider routing in the RLCR loop
#
# Validates:
# - Default build_provider is "codex"
# - --build-provider codex sets state correctly
# - --build-provider with invalid value fails
# - State file parsing handles build_provider field
# - State file parsing defaults to "claude" when field is missing
# - Config-backed default is loaded correctly
# - Config validation rejects invalid build_provider values
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

echo "=========================================="
echo "Build Provider Routing Tests"
echo "=========================================="
echo ""

# ========================================
# Test 1: Default config has build_provider=codex
# ========================================

CONFIG_LOADER="$PROJECT_ROOT/scripts/lib/config-loader.sh"
source "$CONFIG_LOADER"

setup_test_dir
PROJECT_DIR="$TEST_DIR/empty-project"
mkdir -p "$PROJECT_DIR"

merged=$(XDG_CONFIG_HOME="$TEST_DIR/no-user-config" load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null)
val=$(get_config_value "$merged" "build_provider")
if [[ "$val" == "codex" ]]; then
    pass "default config: build_provider defaults to codex"
else
    fail "default config: build_provider defaults to codex" "codex" "$val"
fi

# ========================================
# Test 2: Project config overrides build_provider
# ========================================

setup_test_dir
PROJECT_DIR="$TEST_DIR/project-codex"
mkdir -p "$PROJECT_DIR/.humanize"
printf '{"build_provider": "codex"}' > "$PROJECT_DIR/.humanize/config.json"

merged=$(XDG_CONFIG_HOME="$TEST_DIR/no-user-config2" load_merged_config "$PROJECT_ROOT" "$PROJECT_DIR" 2>/dev/null)
val=$(get_config_value "$merged" "build_provider")
if [[ "$val" == "codex" ]]; then
    pass "project override: build_provider can be set to codex"
else
    fail "project override: build_provider can be set to codex" "codex" "$val"
fi

# ========================================
# Test 3: loop-common.sh loads DEFAULT_BUILD_PROVIDER from config
# ========================================

# Source loop-common.sh in a subshell so its readonly vars don't conflict
val=$(
    unset _LOOP_COMMON_LOADED 2>/dev/null || true
    unset DEFAULT_BUILD_PROVIDER 2>/dev/null || true
    CLAUDE_PROJECT_DIR="$TEST_DIR/empty-project"
    XDG_CONFIG_HOME="$TEST_DIR/no-user-config3"
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh" 2>/dev/null
    echo "$DEFAULT_BUILD_PROVIDER"
)
if [[ "$val" == "codex" ]]; then
    pass "loop-common.sh: DEFAULT_BUILD_PROVIDER defaults to codex"
else
    fail "loop-common.sh: DEFAULT_BUILD_PROVIDER defaults to codex" "codex" "$val"
fi

# ========================================
# Test 4: State file parsing - build_provider present
# ========================================

setup_test_dir
STATE_FILE="$TEST_DIR/state-with-provider.md"
cat > "$STATE_FILE" << 'EOF'
---
current_round: 3
max_iterations: 42
codex_model: gpt-5.4
codex_effort: high
build_provider: codex
review_started: false
---
EOF

# Parse in subshell to avoid readonly conflicts
result=$(
    unset _LOOP_COMMON_LOADED 2>/dev/null || true
    CLAUDE_PROJECT_DIR="$TEST_DIR"
    XDG_CONFIG_HOME="$TEST_DIR/no-user-config4"
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh" 2>/dev/null
    parse_state_file "$STATE_FILE"
    echo "$STATE_BUILD_PROVIDER"
)
if [[ "$result" == "codex" ]]; then
    pass "state parsing: build_provider=codex parsed correctly"
else
    fail "state parsing: build_provider=codex parsed correctly" "codex" "$result"
fi

# ========================================
# Test 5: State file parsing - build_provider missing (backward compat)
# ========================================

setup_test_dir
STATE_FILE="$TEST_DIR/state-no-provider.md"
cat > "$STATE_FILE" << 'EOF'
---
current_round: 1
max_iterations: 10
codex_model: gpt-5.4
codex_effort: high
review_started: false
---
EOF

result=$(
    unset _LOOP_COMMON_LOADED 2>/dev/null || true
    CLAUDE_PROJECT_DIR="$TEST_DIR"
    XDG_CONFIG_HOME="$TEST_DIR/no-user-config5"
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh" 2>/dev/null
    parse_state_file "$STATE_FILE"
    echo "$STATE_BUILD_PROVIDER"
)
if [[ "$result" == "claude" ]]; then
    pass "state parsing: missing build_provider defaults to claude for legacy loops"
else
    fail "state parsing: missing build_provider defaults to claude for legacy loops" "claude" "$result"
fi

# ========================================
# Test 6: setup-rlcr-loop.sh rejects invalid --build-provider
# ========================================

setup_test_dir
PROJECT_DIR="$TEST_DIR/repo-invalid"
init_test_git_repo "$PROJECT_DIR"
PLAN="$PROJECT_DIR/plan.md"
cat > "$PLAN" << 'EOF'
# Test Plan
## Goal
Test the build provider routing
## Acceptance Criteria
- AC-1: It works
## Tasks
- Task 1: Do stuff
EOF

output=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --build-provider invalid "$PLAN" 2>&1 || true)
if echo "$output" | grep -q "must be 'claude' or 'codex'"; then
    pass "setup script: rejects invalid --build-provider value"
else
    fail "setup script: rejects invalid --build-provider value" "error about claude or codex" "$output"
fi

# ========================================
# Test 7: setup-rlcr-loop.sh rejects --build-provider without argument
# ========================================

output=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --build-provider 2>&1 || true)
if echo "$output" | grep -q "requires an argument"; then
    pass "setup script: rejects --build-provider without argument"
else
    fail "setup script: rejects --build-provider without argument" "error about missing argument" "$output"
fi

# ========================================
# Test 8: setup-rlcr-loop.sh writes build_provider to state.md (default codex)
# ========================================

TEST_DIR_8=$(mktemp -d)
trap "rm -rf $TEST_DIR_8" EXIT
PROJECT_DIR="$TEST_DIR_8/repo-default"
init_test_git_repo "$PROJECT_DIR"

echo "plan.md" >> "$PROJECT_DIR/.gitignore"
cd "$PROJECT_DIR" && git add .gitignore && git commit -q -m "Add gitignore" && cd - > /dev/null

PLAN="$PROJECT_DIR/plan.md"
cat > "$PLAN" << 'PLAN_EOF'
# Test Plan

## Goal

Test the default build provider routing in setup script.

## Acceptance Criteria

- AC-1: Build provider defaults to codex
- AC-2: State file contains build_provider field

## Tasks

- Task 1: Verify build_provider in state file
PLAN_EOF

output=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" plan.md 2>&1 || true)
STATE_FILE=$(find "$PROJECT_DIR/.humanize/rlcr" -name "state.md" -type f 2>/dev/null | head -1)
if [[ -n "$STATE_FILE" ]] && grep -q "build_provider: codex" "$STATE_FILE"; then
    pass "setup script: default build_provider=codex in state.md"
else
    fail "setup script: default build_provider=codex in state.md" "build_provider: codex in state.md" "STATE_FILE=$STATE_FILE"
fi

GOAL_TRACKER_FILE=$(find "$PROJECT_DIR/.humanize/rlcr" -name "goal-tracker.md" -type f 2>/dev/null | head -1)
if [[ -n "$GOAL_TRACKER_FILE" ]] && ! grep -qF '$BUILD_PROVIDER' "$GOAL_TRACKER_FILE"; then
    pass "setup script: default-provider goal-tracker has no literal \$BUILD_PROVIDER placeholder"
else
    fail "setup script: default-provider goal-tracker has no literal \$BUILD_PROVIDER placeholder" "no literal \$BUILD_PROVIDER" "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE"
fi

if [[ -n "$GOAL_TRACKER_FILE" ]] && grep -qE '^\| \[To be populated by build agent based on plan\] \|.*\| codex \|' "$GOAL_TRACKER_FILE"; then
    pass "setup script: default-provider goal-tracker Owner column contains resolved provider codex"
else
    fail "setup script: default-provider goal-tracker Owner column contains resolved provider codex" "Owner column = codex" "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE"
fi

# ========================================
# Test 9: setup-rlcr-loop.sh writes build_provider=codex when specified
# ========================================

TEST_DIR_9=$(mktemp -d)
trap "rm -rf $TEST_DIR_9" EXIT
PROJECT_DIR="$TEST_DIR_9/repo-codex"
init_test_git_repo "$PROJECT_DIR"

echo "plan.md" >> "$PROJECT_DIR/.gitignore"
cd "$PROJECT_DIR" && git add .gitignore && git commit -q -m "Add gitignore" && cd - > /dev/null

PLAN="$PROJECT_DIR/plan.md"
cat > "$PLAN" << 'PLAN_EOF'
# Test Plan

## Goal

Test the codex build provider routing in setup script.

## Acceptance Criteria

- AC-1: Build provider set to codex
- AC-2: State file contains build_provider field

## Tasks

- Task 1: Verify build_provider=codex in state file
PLAN_EOF

output=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --build-provider codex plan.md 2>&1 || true)
STATE_FILE=$(find "$PROJECT_DIR/.humanize/rlcr" -name "state.md" -type f 2>/dev/null | head -1)
if [[ -n "$STATE_FILE" ]] && grep -q "build_provider: codex" "$STATE_FILE"; then
    pass "setup script: --build-provider codex writes codex to state.md"
else
    fail "setup script: --build-provider codex writes codex to state.md" "build_provider: codex" "$output"
fi

if [[ -d "$PROJECT_DIR/.humanize/rlcr" ]]; then
    pass "setup script: --build-provider codex creates loop dir"
else
    fail "setup script: --build-provider codex creates loop dir" ".humanize/rlcr dir exists" "missing"
fi

# ========================================
# Test 10: explicit codex selection keeps prompt owner aligned
# ========================================

PROMPT_FILE=$(find "$PROJECT_DIR/.humanize/rlcr" -name "round-0-prompt.md" -type f 2>/dev/null | head -1)
if [[ -n "$PROMPT_FILE" ]] && grep -q "build agent (codex) executes the task directly" "$PROMPT_FILE"; then
    pass "setup script: explicit codex selection writes codex task owner into prompt"
else
    fail "setup script: explicit codex selection writes codex task owner into prompt" "build agent (codex) executes the task directly" "PROMPT_FILE=$PROMPT_FILE"
fi

# ========================================
# Test 11: Config validation rejects invalid build_provider
# ========================================

val=$(
    unset _LOOP_COMMON_LOADED 2>/dev/null || true
    unset DEFAULT_BUILD_PROVIDER 2>/dev/null || true
    setup_test_dir
    PROJECT_DIR="$TEST_DIR/project-bad-provider"
    mkdir -p "$PROJECT_DIR/.humanize"
    printf '{"build_provider": "gemini"}' > "$PROJECT_DIR/.humanize/config.json"
    CLAUDE_PROJECT_DIR="$PROJECT_DIR"
    XDG_CONFIG_HOME="$TEST_DIR/no-user-config6"
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh" 2>/dev/null
    echo "$DEFAULT_BUILD_PROVIDER"
)
if [[ "$val" == "codex" ]]; then
    pass "config validation: invalid build_provider falls back to codex default"
else
    fail "config validation: invalid build_provider falls back to codex default" "codex" "$val"
fi

# ========================================
# Test 12: setup-rlcr-loop.sh rejects --build-provider codex without a plan file
# ========================================

TEST_DIR_12=$(mktemp -d)
trap "rm -rf $TEST_DIR_12" EXIT
PROJECT_DIR="$TEST_DIR_12/repo-no-plan"
init_test_git_repo "$PROJECT_DIR"
output=$(cd "$PROJECT_DIR" && "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --build-provider codex 2>&1 || true)
if echo "$output" | grep -q "Usage: setup-rlcr-loop.sh"; then
    pass "setup script: --build-provider codex without plan file now falls through to normal usage error"
else
    fail "setup script: --build-provider codex without plan file now falls through to normal usage error" "usage output" "$output"
fi

# ========================================
# Test 13: setup-rlcr-loop.sh creates loop dir under git repo root from subdirectory
# ========================================

TEST_DIR_13=$(mktemp -d)
trap "rm -rf $TEST_DIR_13" EXIT
PROJECT_DIR="$TEST_DIR_13/repo-subdir"
init_test_git_repo "$PROJECT_DIR"

echo "plan.md" >> "$PROJECT_DIR/.gitignore"
cd "$PROJECT_DIR" && git add .gitignore && git commit -q -m "Add gitignore" && cd - > /dev/null

# plan.md lives in the nested subdirectory; setup resolves plan paths from CWD
mkdir -p "$PROJECT_DIR/nested/subdir"
PLAN="$PROJECT_DIR/nested/subdir/plan.md"
cat > "$PLAN" << 'PLAN_EOF'
# Test Plan

## Goal

Test that setup creates loop dir at repo root when invoked from a subdirectory.

## Acceptance Criteria

- AC-1: Loop dir is under git repo root, not subdirectory

## Tasks

- Task 1: Verify loop dir path
PLAN_EOF

# Run setup from a nested subdirectory without CLAUDE_PROJECT_DIR set
(
    cd "$PROJECT_DIR/nested/subdir"
    unset CLAUDE_PROJECT_DIR 2>/dev/null || true
    "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" plan.md 2>&1 || true
)

# Loop dir should be at project root, not at nested/subdir
LOOP_DIR_AT_ROOT=$(find "$PROJECT_DIR/.humanize/rlcr" -name "state.md" -type f 2>/dev/null | head -1 || true)
LOOP_DIR_AT_SUBDIR=$(find "$PROJECT_DIR/nested/subdir/.humanize" -name "state.md" -type f 2>/dev/null | head -1 || true)

if [[ -n "$LOOP_DIR_AT_ROOT" ]]; then
    pass "setup script: loop dir created at git repo root when invoked from subdirectory"
else
    fail "setup script: loop dir created at git repo root when invoked from subdirectory" "state.md under $PROJECT_DIR/.humanize/rlcr" "not found"
fi

if [[ -z "$LOOP_DIR_AT_SUBDIR" ]]; then
    pass "setup script: loop dir NOT created at subdirectory when invoked from subdirectory"
else
    fail "setup script: loop dir NOT created at subdirectory when invoked from subdirectory" "no state.md under nested/subdir" "$LOOP_DIR_AT_SUBDIR"
fi

# ========================================
# Test 14: generated round-0-prompt.md references full ask-codex.sh path, not bare name
# ========================================

PROMPT_FILE=$(find "$PROJECT_DIR/.humanize/rlcr" -name "round-0-prompt.md" -type f 2>/dev/null | head -1 || true)
if [[ -n "$PROMPT_FILE" ]] && grep -q "/scripts/ask-codex.sh" "$PROMPT_FILE"; then
    pass "setup script: generated round-0-prompt.md contains full ask-codex.sh path"
else
    fail "setup script: generated round-0-prompt.md contains full ask-codex.sh path" "path ending in /scripts/ask-codex.sh" "PROMPT_FILE=$PROMPT_FILE"
fi

if [[ -n "$PROMPT_FILE" ]] && ! grep -qE "(^|[^/])\`ask-codex\.sh\`" "$PROMPT_FILE"; then
    pass "setup script: generated round-0-prompt.md does not reference bare ask-codex.sh"
else
    fail "setup script: generated round-0-prompt.md does not reference bare ask-codex.sh" "no bare \`ask-codex.sh\`" "found in $PROMPT_FILE"
fi

# ========================================
# Test 15: config build_provider=codex stays codex
# ========================================

val=$(
    unset _LOOP_COMMON_LOADED 2>/dev/null || true
    unset DEFAULT_BUILD_PROVIDER 2>/dev/null || true
    setup_test_dir
    PROJECT_DIR="$TEST_DIR/project-codex-config"
    mkdir -p "$PROJECT_DIR/.humanize"
    printf '{"build_provider": "codex"}' > "$PROJECT_DIR/.humanize/config.json"
    CLAUDE_PROJECT_DIR="$PROJECT_DIR"
    XDG_CONFIG_HOME="$TEST_DIR/no-user-config7"
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh" 2>/dev/null
    echo "$DEFAULT_BUILD_PROVIDER"
)
if [[ "$val" == "codex" ]]; then
    pass "config validation: build_provider=codex remains codex"
else
    fail "config validation: build_provider=codex remains codex" "codex" "$val"
fi

# ========================================
# Test 16: plan path resolves from caller cwd when invoked from subdirectory
# ========================================

TEST_DIR_16=$(mktemp -d)
trap "rm -rf $TEST_DIR_16" EXIT
PROJECT_DIR="$TEST_DIR_16/repo-cwd"
init_test_git_repo "$PROJECT_DIR"

echo "plan.md" >> "$PROJECT_DIR/.gitignore"
cd "$PROJECT_DIR" && git add .gitignore && git commit -q -m "Add gitignore" && cd - > /dev/null

# plan.md lives in the subdirectory (not the repo root)
mkdir -p "$PROJECT_DIR/nested/subdir"
PLAN="$PROJECT_DIR/nested/subdir/plan.md"
cat > "$PLAN" << 'PLAN_EOF'
# Test Plan

## Goal

Test that plan path resolves from caller cwd when invoked from subdirectory.

## Acceptance Criteria

- AC-1: Plan found relative to cwd, not repo root

## Tasks

- Task 1: Verify plan path resolution
PLAN_EOF

# Run setup from the nested subdirectory; plan.md is in that directory
output=$(
    cd "$PROJECT_DIR/nested/subdir"
    unset CLAUDE_PROJECT_DIR 2>/dev/null || true
    "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" plan.md 2>&1 || true
)
if ! echo "$output" | grep -q "Plan file not found"; then
    pass "setup script: plan.md resolves from caller cwd when invoked from subdirectory"
else
    fail "setup script: plan.md resolves from caller cwd when invoked from subdirectory" "plan found" "$output"
fi

# Same scenario as the real runtime: CLAUDE_PROJECT_DIR points at repo root
output=$(
    cd "$PROJECT_DIR/nested/subdir"
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" plan.md 2>&1 || true
)
if ! echo "$output" | grep -q "Plan file not found"; then
    pass "setup script: relative plan still resolves from caller cwd when CLAUDE_PROJECT_DIR points at repo root"
else
    fail "setup script: relative plan still resolves from caller cwd when CLAUDE_PROJECT_DIR points at repo root" "plan found" "$output"
fi

# When launched outside the repo but with CLAUDE_PROJECT_DIR pointing at it,
# project-relative plan paths should still resolve from the project root.
OUTER_DIR="$TEST_DIR_16/outside"
mkdir -p "$OUTER_DIR"
output=$(
    cd "$OUTER_DIR"
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" nested/subdir/plan.md 2>&1 || true
)
if echo "$output" | grep -q "Project must be a git repository"; then
    fail "setup script: project-relative plan resolves from project root when caller cwd is outside repo" "setup proceeds past git prerequisite checks" "$output"
elif ! echo "$output" | grep -q "Plan file not found"; then
    pass "setup script: project-relative plan resolves from project root when caller cwd is outside repo"
else
    fail "setup script: project-relative plan resolves from project root when caller cwd is outside repo" "plan found" "$output"
fi

# ========================================
# Test 17: rlcr-stop-gate.sh honours CLAUDE_PROJECT_DIR over git rev-parse
# ========================================

TEST_DIR_17=$(mktemp -d)
trap "rm -rf $TEST_DIR_17" EXIT
OUTER_DIR="$TEST_DIR_17/outer-dir"
mkdir -p "$OUTER_DIR"

# Create a fixture project with an active loop dir
FIXTURE_PROJECT="$TEST_DIR_17/project"
init_test_git_repo "$FIXTURE_PROJECT"
mkdir -p "$FIXTURE_PROJECT/.humanize/rlcr/2026-01-01_00-00-00"
cat > "$FIXTURE_PROJECT/.humanize/rlcr/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 1
max_iterations: 5
codex_model: gpt-5.4
codex_effort: high
build_provider: claude
review_started: false
---
EOF

# Invoke stop-gate from the unrelated outer dir but with CLAUDE_PROJECT_DIR pointing
# at the fixture project. The gate must BLOCK (active loop detected).
gate_output=$(
    cd "$OUTER_DIR"
    CLAUDE_PROJECT_DIR="$FIXTURE_PROJECT" "$PROJECT_ROOT/scripts/rlcr-stop-gate.sh" 2>&1 || echo "EXIT:$?"
)
if echo "$gate_output" | grep -qE "EXIT:10|BLOCK"; then
    pass "rlcr-stop-gate: honours CLAUDE_PROJECT_DIR when invoked from outside the repo"
else
    fail "rlcr-stop-gate: honours CLAUDE_PROJECT_DIR when invoked from outside the repo" "EXIT:10 or BLOCK" "$gate_output"
fi

# ========================================
# Test 18: DEFAULT_BUILD_PROVIDER=codex is accepted post-parse
# ========================================

TEST_DIR_18=$(mktemp -d)
trap "rm -rf $TEST_DIR_18" EXIT
PROJECT_DIR="$TEST_DIR_18/repo-env-codex"
init_test_git_repo "$PROJECT_DIR"
echo "plan.md" >> "$PROJECT_DIR/.gitignore"
cd "$PROJECT_DIR" && git add .gitignore && git commit -q -m "Add gitignore" && cd - > /dev/null
PLAN="$PROJECT_DIR/plan.md"
cat > "$PLAN" << 'PLAN_EOF'
# Test Plan

## Goal

Verify DEFAULT_BUILD_PROVIDER=codex is accepted.

## Acceptance Criteria

- AC-1: State file contains build_provider: codex

## Tasks

- Task 1: Verify env default path
PLAN_EOF
output=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" DEFAULT_BUILD_PROVIDER=codex "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" plan.md 2>&1 || true)
STATE_FILE=$(find "$PROJECT_DIR/.humanize/rlcr" -name "state.md" -type f 2>/dev/null | head -1)
if [[ -n "$STATE_FILE" ]] && grep -q "build_provider: codex" "$STATE_FILE"; then
    pass "setup script: DEFAULT_BUILD_PROVIDER=codex writes codex to state.md"
else
    fail "setup script: DEFAULT_BUILD_PROVIDER=codex writes codex to state.md" "build_provider: codex" "$output"
fi

# ========================================
# Test 19: state.md plan_file stores repo-relative path when called from subdirectory
# ========================================

TEST_DIR_19=$(mktemp -d)
trap "rm -rf $TEST_DIR_19" EXIT
PROJECT_DIR="$TEST_DIR_19/repo-normpath"
init_test_git_repo "$PROJECT_DIR"

echo "plan.md" >> "$PROJECT_DIR/.gitignore"
cd "$PROJECT_DIR" && git add .gitignore && git commit -q -m "Add gitignore" && cd - > /dev/null

mkdir -p "$PROJECT_DIR/nested/subdir"
PLAN="$PROJECT_DIR/nested/subdir/plan.md"
cat > "$PLAN" << 'PLAN_EOF'
# Test Plan

## Goal

Verify that plan_file in state.md is repo-relative when invoked from a subdirectory.

## Acceptance Criteria

- AC-1: state.md stores nested/subdir/plan.md, not bare plan.md

## Tasks

- Task 1: Verify plan_file field
PLAN_EOF

(
    cd "$PROJECT_DIR/nested/subdir"
    unset CLAUDE_PROJECT_DIR 2>/dev/null || true
    "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" plan.md 2>&1 || true
)

STATE_FILE=$(find "$PROJECT_DIR/.humanize/rlcr" -name "state.md" -type f 2>/dev/null | head -1 || true)
if [[ -n "$STATE_FILE" ]] && grep -q "plan_file: nested/subdir/plan.md" "$STATE_FILE"; then
    pass "setup script: state.md stores repo-relative plan path when called from subdirectory"
else
    ACTUAL_PLAN_LINE=$(grep "plan_file:" "$STATE_FILE" 2>/dev/null || echo "(state.md missing)")
    fail "setup script: state.md stores repo-relative plan path when called from subdirectory" "plan_file: nested/subdir/plan.md" "$ACTUAL_PLAN_LINE"
fi

# ========================================
# Test 20: --help text shows codex as default runtime
# ========================================

help_output=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --help 2>&1 || true)
if echo "$help_output" | grep -q "default: codex"; then
    pass "setup script: --help shows codex as default runtime"
else
    fail "setup script: --help shows codex as default runtime" "default: codex in help" "not found"
fi

if ! echo "$help_output" | grep -q "Not yet supported"; then
    pass "setup script: --help no longer says codex is unsupported"
else
    fail "setup script: --help no longer says codex is unsupported" "no unsupported wording" "still present"
fi

# ========================================
# Summary
# ========================================

print_test_summary "Build Provider Routing Tests"
