#!/usr/bin/env bash
#
# Tests for the Codex-side humanize-cgcr setup flow and resources.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

SETUP_SCRIPT="$PROJECT_ROOT/scripts/setup-cgcr.sh"
CLEANUP_SCRIPT="$PROJECT_ROOT/scripts/cleanup-cgcr.sh"
CGCR_SKILL="$PROJECT_ROOT/skills/humanize-cgcr/SKILL.md"

assert_contains() {
    local file="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" "$file"; then
        pass "$desc"
    else
        fail "$desc" "$needle" "not found in $file"
    fi
}

echo "=========================================="
echo "CGCR Setup Tests"
echo "=========================================="
echo ""

if [[ -x "$SETUP_SCRIPT" ]]; then
    pass "setup-cgcr.sh is executable"
else
    fail "setup-cgcr.sh is executable" "executable" "missing or not executable"
fi

if [[ -x "$CLEANUP_SCRIPT" ]]; then
    pass "cleanup-cgcr.sh is executable"
else
    fail "cleanup-cgcr.sh is executable" "executable" "missing or not executable"
fi

if bash -n "$CLEANUP_SCRIPT"; then
    pass "cleanup-cgcr.sh has valid shell syntax"
else
    fail "cleanup-cgcr.sh has valid shell syntax" "bash -n passes" "syntax error"
fi

if [[ -f "$CGCR_SKILL" ]]; then
    pass "Codex cgcr launcher skill exists"
else
    fail "Codex cgcr launcher skill exists" "$CGCR_SKILL exists" "missing"
fi

assert_contains "$CGCR_SKILL" "/flow:humanize-cgcr" "cgcr skill documents Codex flow command"
assert_contains "$CGCR_SKILL" '`/humanize:cgcr` is the public CGCR command name.' "cgcr skill documents canonical command wrapper"
assert_contains "$CGCR_SKILL" "setup-cgcr.sh" "cgcr skill calls setup script"
assert_contains "$CGCR_SKILL" "cleanup-cgcr.sh" "cgcr skill documents task-end cleanup script"
assert_contains "$CGCR_SKILL" "Codex is the only implementation agent" "cgcr skill preserves executor boundary"
assert_contains "$SETUP_SCRIPT" 'CODEX_CLI_COMMAND="codex --yolo' "cgcr launcher starts Codex in yolo mode"
assert_contains "$SETUP_SCRIPT" 'start-codex.sh' "cgcr launcher writes short Codex startup script"
assert_contains "$SETUP_SCRIPT" 'start-claude.sh' "cgcr launcher writes short Claude startup script"
assert_contains "$SETUP_SCRIPT" '$(cat $(shell_quote "$CODEX_PROMPT_FILE"))' "cgcr launcher passes Codex prompt at startup"
assert_contains "$SETUP_SCRIPT" "claude --dangerously-skip-permissions" "cgcr launcher starts Claude with active permission bypass flag"
assert_contains "$SETUP_SCRIPT" "wait_for_pane_text" "cgcr launcher waits on tmux pane text before monitor submit"
assert_contains "$SETUP_SCRIPT" '"bypass permissions on"' "cgcr launcher waits for Claude prompt readiness"
assert_contains "$SETUP_SCRIPT" 'wait_for_pane_text "$CLAUDE_TARGET" "$GOAL_ID"' "cgcr launcher waits for rendered monitor command"
assert_contains "$SETUP_SCRIPT" "tmux set-buffer" "cgcr launcher writes long commands through tmux buffer"
assert_contains "$SETUP_SCRIPT" "tmux paste-buffer" "cgcr launcher pastes long commands through tmux buffer"
assert_contains "$SETUP_SCRIPT" 'humanize-cgcr-$$-' "cgcr launcher uses shell pid in tmux buffer name"
assert_contains "$SETUP_SCRIPT" "tmux send-keys -t \"\$target\" C-m" "cgcr launcher submits prompts with C-m after paste"
assert_contains "$SETUP_SCRIPT" "retrying monitor submit once" "cgcr launcher retries monitor submit if Claude does not visibly start"

setup_test_dir
REPO="$TEST_DIR/repo"
mkdir -p "$REPO"
(
    cd "$REPO"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    git config commit.gpgsign false
    printf 'initial\n' > README.md
    git add README.md
    git commit -q -m "Initial commit"
)

TASK="Implement a long-running feature without fake data or placeholder stubs"
OUTPUT="$(
    cd "$REPO"
    "$SETUP_SCRIPT" \
        --prepare-only \
        --goal-id cgcr-test-goal \
        --session humanize-cgcr-test \
        --cadence 30m \
        --principles "no fake data; no stubs; do not broaden scope" \
        --task "$TASK"
)"

RUN_DIR="$(printf '%s\n' "$OUTPUT" | sed -n 's/^  run_dir:[[:space:]]*//p' | tail -1)"

if [[ -d "$RUN_DIR" ]]; then
    pass "prepare-only creates CGCR run directory"
else
    fail "prepare-only creates CGCR run directory" "directory exists" "${RUN_DIR:-missing}"
fi

TASK_FILE="$RUN_DIR/task.md"
PROMPT_FILE="$RUN_DIR/codex-goal-prompt.md"
MONITOR_FILE="$RUN_DIR/claude-monitor-command.txt"
RESOURCE_FILE="$RUN_DIR/resources.json"
README_FILE="$RUN_DIR/README.md"
CODEX_LAUNCHER_FILE="$RUN_DIR/start-codex.sh"
CLAUDE_LAUNCHER_FILE="$RUN_DIR/start-claude.sh"
CODEX_LAUNCHER_COMMAND="$(printf "'%s'" "$CODEX_LAUNCHER_FILE")"
CLAUDE_WINDOW_COMMAND="$(printf "'%s'" "$CLAUDE_LAUNCHER_FILE")"

for file in "$TASK_FILE" "$PROMPT_FILE" "$MONITOR_FILE" "$RESOURCE_FILE" "$README_FILE" "$CODEX_LAUNCHER_FILE" "$CLAUDE_LAUNCHER_FILE"; do
    if [[ -f "$file" ]]; then
        pass "created $(basename "$file")"
    else
        fail "created $(basename "$file")" "$file exists" "missing"
    fi
done

for file in "$CODEX_LAUNCHER_FILE" "$CLAUDE_LAUNCHER_FILE"; do
    if [[ -x "$file" ]]; then
        pass "$(basename "$file") is executable"
    else
        fail "$(basename "$file") is executable" "executable" "not executable"
    fi
    if bash -n "$file"; then
        pass "$(basename "$file") has valid shell syntax"
    else
        fail "$(basename "$file") has valid shell syntax" "bash -n passes" "syntax error"
    fi
done

assert_contains "$TASK_FILE" "$TASK" "task file records original task"
assert_contains "$PROMPT_FILE" "/goal $TASK" "Codex prompt starts /goal"
assert_contains "$PROMPT_FILE" "MONITOR_TARGET_ID: cgcr-test-goal" "Codex prompt includes goal id"
assert_contains "$PROMPT_FILE" "If a message starts with [MONITOR], reply with [MONITOR-ACK] before acting." "Codex prompt includes monitor ack contract"
assert_contains "$PROMPT_FILE" "Never claim tests passed unless the exact commands were run." "Codex prompt forbids fake verification"
assert_contains "$MONITOR_FILE" "/humanize:cgcr --discover --expect-goal cgcr-test-goal" "Monitor command discovers expected goal through canonical wrapper"
assert_contains "$MONITOR_FILE" "--cadence 30m" "Monitor command includes cadence"
assert_contains "$MONITOR_FILE" "--principles" "Monitor command includes principles"
assert_contains "$RESOURCE_FILE" '"workflow": "CGCR"' "resources record workflow"
assert_contains "$RESOURCE_FILE" '"tmux_session": "humanize-cgcr-test"' "resources record tmux session"
assert_contains "$RESOURCE_FILE" '"codex_target": "humanize-cgcr-test:codex-goal.0"' "resources record Codex target"
assert_contains "$RESOURCE_FILE" "\"codex_start_command\": \"$CODEX_LAUNCHER_COMMAND\"" "resources record short Codex launcher command"
assert_contains "$RESOURCE_FILE" '"codex_cli_command": "codex --yolo' "resources record Codex CLI command"
assert_contains "$RESOURCE_FILE" '"codex_launcher_file": "'"$CODEX_LAUNCHER_FILE"'"' "resources record Codex launcher path"
assert_contains "$RESOURCE_FILE" '"claude_monitor_target": "humanize-cgcr-test:claude-monitor.0"' "resources record Claude monitor target"
assert_contains "$RESOURCE_FILE" '"claude_start_command": "claude --dangerously-skip-permissions' "resources record Claude start command"
assert_contains "$RESOURCE_FILE" "\"claude_window_command\": \"$CLAUDE_WINDOW_COMMAND\"" "resources record short Claude window command"
assert_contains "$RESOURCE_FILE" '"claude_launcher_file": "'"$CLAUDE_LAUNCHER_FILE"'"' "resources record Claude launcher path"
assert_contains "$CODEX_LAUNCHER_FILE" 'exec codex --yolo' "Codex launcher executes codex"
assert_contains "$CODEX_LAUNCHER_FILE" "$PROMPT_FILE" "Codex launcher reads prompt file"
assert_contains "$CLAUDE_LAUNCHER_FILE" 'exec claude --dangerously-skip-permissions' "Claude launcher executes claude"
assert_contains "$README_FILE" "Do not implement from Claude Code." "run README preserves monitor boundary"

print_test_summary "CGCR Setup Tests"
