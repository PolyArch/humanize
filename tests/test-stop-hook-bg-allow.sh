#!/usr/bin/env bash
#
# Tests for the background-task short-circuit in loop-codex-stop-hook.sh.
#
# When the current Claude Code session has dispatched background work that has
# not yet completed (via Agent run_in_background=true or Bash
# run_in_background=true), the RLCR stop hook must exit 0 with a user-facing
# systemMessage instead of running any gate or Codex review. The on-disk loop
# state must remain unchanged, so that the next natural stop (after the
# background task finishes) re-enters the normal review flow.
#
# Acceptance criteria exercised here (see
# .humanize/rlcr/2026-04-16_13-19-26/goal-tracker.md for authoritative list):
#   AC-1  no bg dispatches            -> normal Codex flow
#   AC-2  pending subagent            -> exit 0 + systemMessage
#   AC-3  pending shell               -> exit 0 + systemMessage
#   AC-4  subagent launch + complete  -> normal Codex flow
#   AC-5  2 subagents + 1 shell       -> systemMessage mentions "3 background"
#   AC-6  missing transcript path     -> normal Codex flow (fail-closed)
#   AC-7  no active loop              -> exit 0, no systemMessage, no Codex
#   AC-8  finalize phase pending bg   -> exit 0 + systemMessage
#   AC-9  via rlcr-stop-gate.sh       -> exit 0 (wrapper ALLOW)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

STOP_HOOK="$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh"
GATE_SCRIPT="$PROJECT_ROOT/scripts/rlcr-stop-gate.sh"

setup_test_dir

# AC-10 needs a transcript living under $HOME so the hook input can use
# the "~/..." form. Create the fixture dir in the AC-10 block and extend
# the EXIT trap set by setup_test_dir to clean both directories on shutdown.
HOME_FIXTURE_DIR=""
cleanup_all() {
    rm -rf "$TEST_DIR"
    [[ -n "$HOME_FIXTURE_DIR" ]] && rm -rf "$HOME_FIXTURE_DIR"
}
trap cleanup_all EXIT

export XDG_CACHE_HOME="$TEST_DIR/.cache"
mkdir -p "$XDG_CACHE_HOME"

# ----------------------------------------------------------------------
# Mock codex CLI: records an invocation marker and prints canned feedback.
# ----------------------------------------------------------------------
setup_mock_codex() {
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/codex" << 'EOF'
#!/usr/bin/env bash
if [[ -n "${MOCK_CODEX_MARKER:-}" ]]; then
    : > "$MOCK_CODEX_MARKER"
fi
printf '%s\n' "${MOCK_CODEX_OUTPUT:-Mock review feedback}"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/codex"
    export PATH="$TEST_DIR/bin:$PATH"
}

# ----------------------------------------------------------------------
# Build a minimal "active loop" project that satisfies every gate the
# stop hook enforces BEFORE it calls Codex (so tests that want to reach
# the Codex review flow can pass cleanly when bg-pending is not expected).
# ----------------------------------------------------------------------
create_full_fixture() {
    local repo_dir="$1"
    local finalize_phase="${2:-false}"

    init_test_git_repo "$repo_dir"

    printf 'plans/\n' > "$repo_dir/.gitignore"
    git -C "$repo_dir" add .gitignore
    git -C "$repo_dir" commit -q -m "Add test gitignore"

    mkdir -p "$repo_dir/plans"
    cat > "$repo_dir/plans/test-plan.md" << 'EOF'
# Test Plan

Exercise the background-task short-circuit.
EOF

    local branch base_commit loop_dir
    branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)
    base_commit=$(git -C "$repo_dir" rev-parse HEAD)
    loop_dir="$repo_dir/.humanize/rlcr/2026-03-01_00-00-00"
    mkdir -p "$loop_dir"

    cp "$repo_dir/plans/test-plan.md" "$loop_dir/plan.md"

    local state_name="state.md"
    if [[ "$finalize_phase" == "true" ]]; then
        state_name="finalize-state.md"
    fi

    cat > "$loop_dir/$state_name" << EOF
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.4
codex_effort: high
codex_timeout: 60
push_every_round: false
full_review_round: 5
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $branch
base_branch: $branch
base_commit: $base_commit
review_started: false
ask_codex_question: false
agent_teams: false
---
EOF

    local summary_name="round-0-summary.md"
    if [[ "$finalize_phase" == "true" ]]; then
        summary_name="finalize-summary.md"
    fi
    cat > "$loop_dir/$summary_name" << 'EOF'
# Summary

Exercised the background-task short-circuit.
EOF

    cat > "$loop_dir/goal-tracker.md" << 'EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Exercise background-task short-circuit.
### Acceptance Criteria
- AC-1: Hook reaches Codex review when no bg tasks are pending.
## MUTABLE SECTION
### Plan Version: 1 (Updated: Round 0)
#### Active Tasks
| Task | Target AC | Status | Notes |
|------|-----------|--------|-------|
| Exercise stop hook | AC-1 | completed | - |
EOF

    # Echo the loop dir so callers can reach state artifacts.
    echo "$loop_dir"
}

# A project with no RLCR state file at all.
create_empty_project() {
    local repo_dir="$1"
    init_test_git_repo "$repo_dir"
}

# ----------------------------------------------------------------------
# Transcript fixture builders.
# Each prints a JSONL transcript to stdout.
# ----------------------------------------------------------------------
emit_tool_use_assistant() {
    local tool_use_id="$1" tool_name="$2" extra_input_json="$3"
    local input_json="{\"run_in_background\":true${extra_input_json}}"
    jq -c -n \
        --arg id "$tool_use_id" \
        --arg name "$tool_name" \
        --argjson input "$input_json" \
        '{
          type:"assistant",
          message:{
            role:"assistant",
            content:[
              {type:"tool_use", id:$id, name:$name, input:$input}
            ]
          }
        }'
}

emit_async_agent_launch_result() {
    local tool_use_id="$1" agent_id="$2"
    jq -c -n \
        --arg id "$tool_use_id" \
        --arg aid "$agent_id" \
        '{
          type:"user",
          message:{
            role:"user",
            content:[{tool_use_id:$id, type:"tool_result",
                      content:[{type:"text", text:"Async agent launched"}]}]
          },
          toolUseResult:{isAsync:true, status:"async_launched", agentId:$aid}
        }'
}

emit_bg_shell_launch_result() {
    local tool_use_id="$1" bg_task_id="$2"
    jq -c -n \
        --arg id "$tool_use_id" \
        --arg bid "$bg_task_id" \
        '{
          type:"user",
          message:{
            role:"user",
            content:[{tool_use_id:$id, type:"tool_result",
                      content:[{type:"text", text:"Shell started in background"}]}]
          },
          toolUseResult:{backgroundTaskId:$bid}
        }'
}

emit_task_completion_event() {
    local task_id="$1" tool_use_id="$2" status="${3:-completed}"
    local notif
    notif=$(printf '<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>%s</tool-use-id>\n<status>%s</status>\n</task-notification>' \
        "$task_id" "$tool_use_id" "$status")
    jq -c -n --arg content "$notif" \
        '{type:"queue-operation", operation:"enqueue", content:$content}'
}

write_transcript() {
    local path="$1"
    shift
    : > "$path"
    for line in "$@"; do
        printf '%s\n' "$line" >> "$path"
    done
}

# ----------------------------------------------------------------------
# Invoke the stop hook with a crafted hook input JSON.
# Sets RUN_EXIT_CODE, RUN_OUTPUT, RUN_MARKER.
# ----------------------------------------------------------------------
run_stop_hook_with_input() {
    local repo_dir="$1" hook_input_json="$2"

    RUN_MARKER="$repo_dir/codex-called.marker"
    rm -f "$RUN_MARKER"

    set +e
    RUN_OUTPUT=$(
        cd "$repo_dir"
        CLAUDE_PROJECT_DIR="$repo_dir" \
        MOCK_CODEX_MARKER="$RUN_MARKER" \
        MOCK_CODEX_OUTPUT="Mock review feedback" \
        "$STOP_HOOK" <<<"$hook_input_json" 2>&1
    )
    RUN_EXIT_CODE=$?
    set -e
}

assert_systemmessage_only() {
    local test_name="$1" repo_dir="$2" state_file="$3" expected_count_regex="$4"

    local before_hash after_hash
    before_hash=$(sha256sum "$state_file" 2>/dev/null | awk '{print $1}')

    if [[ "$RUN_EXIT_CODE" -ne 0 ]]; then
        fail "$test_name" "exit 0 with systemMessage" \
            "exit $RUN_EXIT_CODE; output: $RUN_OUTPUT"
        return
    fi
    if [[ -f "$RUN_MARKER" ]]; then
        fail "$test_name" "Codex NOT invoked" \
            "marker present (Codex was called); output: $RUN_OUTPUT"
        return
    fi
    local system_message
    system_message=$(printf '%s' "$RUN_OUTPUT" | jq -r '.systemMessage // empty' 2>/dev/null || echo "")
    if [[ -z "$system_message" ]]; then
        fail "$test_name" "JSON output with systemMessage" \
            "no systemMessage in output: $RUN_OUTPUT"
        return
    fi
    if [[ -n "$expected_count_regex" ]]; then
        if ! printf '%s' "$system_message" | grep -Eq "$expected_count_regex"; then
            fail "$test_name" \
                "systemMessage matches /$expected_count_regex/" \
                "got: $system_message"
            return
        fi
    fi
    after_hash=$(sha256sum "$state_file" 2>/dev/null | awk '{print $1}')
    if [[ "$before_hash" != "$after_hash" ]]; then
        fail "$test_name" "state file unchanged" \
            "hash changed ($before_hash -> $after_hash)"
        return
    fi
    pass "$test_name"
}

assert_reached_codex() {
    local test_name="$1"
    if [[ "$RUN_EXIT_CODE" -eq 0 ]] && [[ -f "$RUN_MARKER" ]]; then
        pass "$test_name"
    else
        fail "$test_name" "exit 0 and Codex invoked (marker present)" \
            "exit $RUN_EXIT_CODE, marker=$(test -f "$RUN_MARKER" && echo present || echo missing); output: $RUN_OUTPUT"
    fi
}

setup_mock_codex

# Transcripts live outside any test repo to avoid tripping git cleanliness
# gates in the stop hook.
TRANSCRIPTS_DIR="$TEST_DIR/transcripts"
mkdir -p "$TRANSCRIPTS_DIR"

echo "=========================================="
echo "Stop Hook Background-Task Allow Tests"
echo "=========================================="
echo ""

# ---------------- AC-1 ----------------
echo "Test AC-1: No bg dispatches -> reaches Codex"
AC1_REPO="$TEST_DIR/ac1"
create_full_fixture "$AC1_REPO" > /dev/null
AC1_TRANSCRIPT="$TRANSCRIPTS_DIR/ac1.jsonl"
write_transcript "$AC1_TRANSCRIPT" '{"type":"user","message":{"role":"user","content":"hello"}}'

AC1_INPUT=$(jq -c -n --arg tp "$AC1_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$AC1_REPO" "$AC1_INPUT"
assert_reached_codex "AC-1: transcript without bg dispatches proceeds to Codex review"

# ---------------- AC-2 ----------------
echo "Test AC-2: One pending background subagent -> exit 0 + systemMessage"
AC2_REPO="$TEST_DIR/ac2"
AC2_LOOP=$(create_full_fixture "$AC2_REPO")
AC2_STATE="$AC2_LOOP/state.md"
AC2_TRANSCRIPT="$TRANSCRIPTS_DIR/ac2.jsonl"
AC2_LINE_LAUNCH=$(emit_tool_use_assistant "toolu_A" "Agent" ',"description":"x","prompt":"x"')
AC2_LINE_RESULT=$(emit_async_agent_launch_result "toolu_A" "agent_pending_A")
write_transcript "$AC2_TRANSCRIPT" "$AC2_LINE_LAUNCH" "$AC2_LINE_RESULT"

AC2_INPUT=$(jq -c -n --arg tp "$AC2_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$AC2_REPO" "$AC2_INPUT"
assert_systemmessage_only \
    "AC-2: pending subagent triggers exit 0 + systemMessage, state untouched" \
    "$AC2_REPO" "$AC2_STATE" "1 background task"

# ---------------- AC-3 ----------------
echo "Test AC-3: One pending background shell -> exit 0 + systemMessage"
AC3_REPO="$TEST_DIR/ac3"
AC3_LOOP=$(create_full_fixture "$AC3_REPO")
AC3_STATE="$AC3_LOOP/state.md"
AC3_TRANSCRIPT="$TRANSCRIPTS_DIR/ac3.jsonl"
AC3_LINE_LAUNCH=$(emit_tool_use_assistant "toolu_B" "Bash" ',"command":"sleep 30"')
AC3_LINE_RESULT=$(emit_bg_shell_launch_result "toolu_B" "shell_pending_B")
write_transcript "$AC3_TRANSCRIPT" "$AC3_LINE_LAUNCH" "$AC3_LINE_RESULT"

AC3_INPUT=$(jq -c -n --arg tp "$AC3_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$AC3_REPO" "$AC3_INPUT"
assert_systemmessage_only \
    "AC-3: pending background shell triggers exit 0 + systemMessage" \
    "$AC3_REPO" "$AC3_STATE" "1 background task"

# ---------------- AC-4 ----------------
echo "Test AC-4: Launched subagent with completion notification -> reaches Codex"
AC4_REPO="$TEST_DIR/ac4"
create_full_fixture "$AC4_REPO" > /dev/null
AC4_TRANSCRIPT="$TRANSCRIPTS_DIR/ac4.jsonl"
AC4_LAUNCH=$(emit_tool_use_assistant "toolu_C" "Agent" ',"description":"x","prompt":"x"')
AC4_RESULT=$(emit_async_agent_launch_result "toolu_C" "agent_done_C")
AC4_COMPLETE=$(emit_task_completion_event "agent_done_C" "toolu_C" "completed")
write_transcript "$AC4_TRANSCRIPT" "$AC4_LAUNCH" "$AC4_RESULT" "$AC4_COMPLETE"

AC4_INPUT=$(jq -c -n --arg tp "$AC4_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$AC4_REPO" "$AC4_INPUT"
assert_reached_codex "AC-4: subagent with matching completion notification proceeds to Codex review"

# ---------------- AC-5 ----------------
echo "Test AC-5: 2 pending subagents + 1 pending shell -> systemMessage mentions 3"
AC5_REPO="$TEST_DIR/ac5"
AC5_LOOP=$(create_full_fixture "$AC5_REPO")
AC5_STATE="$AC5_LOOP/state.md"
AC5_TRANSCRIPT="$TRANSCRIPTS_DIR/ac5.jsonl"
AC5_L1_LAUNCH=$(emit_tool_use_assistant "toolu_D1" "Agent" ',"description":"x","prompt":"x"')
AC5_L1_RESULT=$(emit_async_agent_launch_result "toolu_D1" "agent_pending_D1")
AC5_L2_LAUNCH=$(emit_tool_use_assistant "toolu_D2" "Agent" ',"description":"y","prompt":"y"')
AC5_L2_RESULT=$(emit_async_agent_launch_result "toolu_D2" "agent_pending_D2")
AC5_L3_LAUNCH=$(emit_tool_use_assistant "toolu_D3" "Bash" ',"command":"sleep 30"')
AC5_L3_RESULT=$(emit_bg_shell_launch_result "toolu_D3" "shell_pending_D3")
write_transcript "$AC5_TRANSCRIPT" \
    "$AC5_L1_LAUNCH" "$AC5_L1_RESULT" \
    "$AC5_L2_LAUNCH" "$AC5_L2_RESULT" \
    "$AC5_L3_LAUNCH" "$AC5_L3_RESULT"

AC5_INPUT=$(jq -c -n --arg tp "$AC5_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$AC5_REPO" "$AC5_INPUT"
assert_systemmessage_only \
    "AC-5: 2 pending subagents + 1 pending shell -> systemMessage mentions '3 background task(s)'" \
    "$AC5_REPO" "$AC5_STATE" "3 background task\\(s\\)"

# ---------------- AC-6 ----------------
echo "Test AC-6: missing transcript path -> reaches Codex (fail-closed)"
AC6_REPO="$TEST_DIR/ac6"
create_full_fixture "$AC6_REPO" > /dev/null
AC6_INPUT=$(jq -c -n --arg tp "/nonexistent/file-$$.jsonl" '{transcript_path:$tp}')
run_stop_hook_with_input "$AC6_REPO" "$AC6_INPUT"
assert_reached_codex "AC-6: missing transcript_path proceeds to Codex review (fail-closed)"

# Also: empty transcript_path field
AC6B_REPO="$TEST_DIR/ac6b"
create_full_fixture "$AC6B_REPO" > /dev/null
AC6B_INPUT='{"transcript_path":""}'
run_stop_hook_with_input "$AC6B_REPO" "$AC6B_INPUT"
assert_reached_codex "AC-6b: empty transcript_path string proceeds to Codex review"

# And: no transcript_path key at all
AC6C_REPO="$TEST_DIR/ac6c"
create_full_fixture "$AC6C_REPO" > /dev/null
AC6C_INPUT='{}'
run_stop_hook_with_input "$AC6C_REPO" "$AC6C_INPUT"
assert_reached_codex "AC-6c: hook input with no transcript_path proceeds to Codex review"

# ---------------- AC-7 ----------------
echo "Test AC-7: No active loop -> exit 0, no systemMessage, no Codex"
AC7_REPO="$TEST_DIR/ac7"
create_empty_project "$AC7_REPO"
AC7_TRANSCRIPT="$TRANSCRIPTS_DIR/ac7.jsonl"
AC7_LAUNCH=$(emit_tool_use_assistant "toolu_E" "Agent" ',"description":"x","prompt":"x"')
AC7_RESULT=$(emit_async_agent_launch_result "toolu_E" "agent_pending_E")
write_transcript "$AC7_TRANSCRIPT" "$AC7_LAUNCH" "$AC7_RESULT"
AC7_INPUT=$(jq -c -n --arg tp "$AC7_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$AC7_REPO" "$AC7_INPUT"

AC7_SYS_MSG=$(printf '%s' "$RUN_OUTPUT" | jq -r '.systemMessage // empty' 2>/dev/null || echo "")
if [[ "$RUN_EXIT_CODE" -eq 0 ]] && [[ ! -f "$RUN_MARKER" ]] && [[ -z "$AC7_SYS_MSG" ]]; then
    pass "AC-7: no active loop takes original exit-0 path without systemMessage"
else
    fail "AC-7: no active loop takes original exit-0 path without systemMessage" \
        "exit 0, no Codex marker, no systemMessage" \
        "exit $RUN_EXIT_CODE, marker=$(test -f "$RUN_MARKER" && echo present || echo missing), systemMessage='$AC7_SYS_MSG'; output: $RUN_OUTPUT"
fi

# ---------------- AC-8 ----------------
echo "Test AC-8: Finalize phase + pending bg -> exit 0 + systemMessage"
AC8_REPO="$TEST_DIR/ac8"
AC8_LOOP=$(create_full_fixture "$AC8_REPO" true)
AC8_STATE="$AC8_LOOP/finalize-state.md"
AC8_TRANSCRIPT="$TRANSCRIPTS_DIR/ac8.jsonl"
AC8_LAUNCH=$(emit_tool_use_assistant "toolu_F" "Agent" ',"description":"x","prompt":"x"')
AC8_RESULT=$(emit_async_agent_launch_result "toolu_F" "agent_pending_F")
write_transcript "$AC8_TRANSCRIPT" "$AC8_LAUNCH" "$AC8_RESULT"
AC8_INPUT=$(jq -c -n --arg tp "$AC8_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$AC8_REPO" "$AC8_INPUT"
assert_systemmessage_only \
    "AC-8: finalize phase with pending bg task -> exit 0 + systemMessage" \
    "$AC8_REPO" "$AC8_STATE" "1 background task"

# ---------------- AC-9 ----------------
echo "Test AC-9: rlcr-stop-gate.sh forwards transcript_path to hook"
AC9_REPO="$TEST_DIR/ac9"
create_full_fixture "$AC9_REPO" > /dev/null
AC9_TRANSCRIPT="$TRANSCRIPTS_DIR/ac9.jsonl"
AC9_LAUNCH=$(emit_tool_use_assistant "toolu_G" "Agent" ',"description":"x","prompt":"x"')
AC9_RESULT=$(emit_async_agent_launch_result "toolu_G" "agent_pending_G")
write_transcript "$AC9_TRANSCRIPT" "$AC9_LAUNCH" "$AC9_RESULT"

AC9_OUT="$AC9_REPO/gate-out.txt"
set +e
(
    cd "$AC9_REPO"
    "$GATE_SCRIPT" --transcript-path "$AC9_TRANSCRIPT"
) > "$AC9_OUT" 2>&1
AC9_EXIT=$?
set -e

if [[ "$AC9_EXIT" -eq 0 ]] && grep -q "^ALLOW:" "$AC9_OUT"; then
    pass "AC-9: rlcr-stop-gate.sh exits 0 with ALLOW when bg tasks are pending"
else
    AC9_BODY=$(cat "$AC9_OUT" 2>/dev/null || true)
    fail "AC-9: rlcr-stop-gate.sh exits 0 with ALLOW when bg tasks are pending" \
        "exit 0 and output containing ALLOW:" \
        "exit $AC9_EXIT; output: $AC9_BODY"
fi

# ---------------- AC-10 ----------------
# Regression: real sessions pass transcript_path as "~/.claude/projects/...".
# Without tilde expansion the file check `[[ -f "~/..." ]]` is always false,
# so the short-circuit silently misses pending background tasks.
echo "Test AC-10: '~/...' transcript path still triggers short-circuit"
AC10_REPO="$TEST_DIR/ac10"
AC10_LOOP=$(create_full_fixture "$AC10_REPO")
AC10_STATE="$AC10_LOOP/state.md"

HOME_FIXTURE_DIR=$(mktemp -d "$HOME/.humanize-bg-allow-test-XXXXXX")
AC10_TRANSCRIPT="$HOME_FIXTURE_DIR/ac10.jsonl"
AC10_LAUNCH=$(emit_tool_use_assistant "toolu_H" "Agent" ',"description":"x","prompt":"x"')
AC10_RESULT=$(emit_async_agent_launch_result "toolu_H" "agent_pending_H")
write_transcript "$AC10_TRANSCRIPT" "$AC10_LAUNCH" "$AC10_RESULT"

# Build the tilde-form string literally. Do NOT let the shell expand "~".
AC10_TILDE_PATH="~/${AC10_TRANSCRIPT#$HOME/}"
AC10_INPUT=$(jq -c -n --arg tp "$AC10_TILDE_PATH" '{transcript_path:$tp}')
run_stop_hook_with_input "$AC10_REPO" "$AC10_INPUT"
assert_systemmessage_only \
    "AC-10: '~/'-prefixed transcript_path is expanded and short-circuits on pending bg" \
    "$AC10_REPO" "$AC10_STATE" "1 background task"

# Also prove the helper works directly against a "~/..." argument.
# This avoids masking a helper regression behind the hook's own expansion.
AC10_HELPER_OUT=$(
    cd "$AC10_REPO"
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    list_pending_background_task_ids "$AC10_TILDE_PATH" 2>/dev/null | sort -u
)
if printf '%s\n' "$AC10_HELPER_OUT" | grep -qx 'agent_pending_H'; then
    pass "AC-10b: list_pending_background_task_ids expands '~/...' directly"
else
    fail "AC-10b: list_pending_background_task_ids expands '~/...' directly" \
        "output containing 'agent_pending_H'" "$AC10_HELPER_OUT"
fi

print_test_summary "Stop Hook Background-Task Allow Test Summary"
exit $?
