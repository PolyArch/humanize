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

export XDG_CACHE_HOME="$TEST_DIR/.cache"
mkdir -p "$XDG_CACHE_HOME"

# Fake HOME rooted inside $TEST_DIR so the tilde-path regressions (AC-10,
# AC-10b, AC-10c) do not write into the real user home. The hook, helper,
# and wrapper invocations that need tilde expansion run with HOME set to
# this directory; every other invocation keeps the real HOME. Cleanup is
# covered by the setup_test_dir EXIT trap because FAKE_HOME is under
# $TEST_DIR.
FAKE_HOME="$TEST_DIR/fake-home"
mkdir -p "$FAKE_HOME"

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

emit_sdk_task_notification() {
    local task_id="$1" tool_use_id="$2" status="${3:-completed}"
    jq -c -n --arg tid "$task_id" --arg tu "$tool_use_id" --arg st "$status" \
        '{type:"system", subtype:"task_notification", task_id:$tid, tool_use_id:$tu, status:$st}'
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
# Invoke the stop hook with a crafted hook input JSON. The optional third
# argument overrides HOME for the hook invocation only, so tilde-path
# regressions can point at a fake HOME rooted under $TEST_DIR without
# leaking into the real user home.
# Sets RUN_EXIT_CODE, RUN_OUTPUT, RUN_MARKER.
# ----------------------------------------------------------------------
run_stop_hook_with_input() {
    local repo_dir="$1" hook_input_json="$2" home_override="${3:-}"

    RUN_MARKER="$repo_dir/codex-called.marker"
    rm -f "$RUN_MARKER"

    set +e
    RUN_OUTPUT=$(
        cd "$repo_dir"
        [[ -n "$home_override" ]] && export HOME="$home_override"
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

# ---------------- AC-10 / AC-10b / AC-10c ----------------
# Regression: real sessions pass transcript_path as "~/.claude/projects/...".
# Without tilde expansion the file check `[[ -f "~/..." ]]` is always false,
# so the short-circuit silently misses pending background tasks.
#
# The fixture lives under a fake HOME rooted inside $TEST_DIR so the tests
# remain portable on sandboxed or read-only-HOME environments. Only the
# specific hook / helper / wrapper invocations that need tilde expansion
# run with HOME=$FAKE_HOME; the rest of the suite keeps the real HOME.
echo "Test AC-10: '~/...' transcript path still triggers short-circuit"
AC10_REPO="$TEST_DIR/ac10"
AC10_LOOP=$(create_full_fixture "$AC10_REPO")
AC10_STATE="$AC10_LOOP/state.md"

mkdir -p "$FAKE_HOME/session-data"
AC10_TRANSCRIPT="$FAKE_HOME/session-data/ac10.jsonl"
AC10_LAUNCH=$(emit_tool_use_assistant "toolu_H" "Agent" ',"description":"x","prompt":"x"')
AC10_RESULT=$(emit_async_agent_launch_result "toolu_H" "agent_pending_H")
write_transcript "$AC10_TRANSCRIPT" "$AC10_LAUNCH" "$AC10_RESULT"

# Build the tilde-form string literally. Do NOT let the shell expand "~".
AC10_TILDE_PATH="~/session-data/ac10.jsonl"
AC10_INPUT=$(jq -c -n --arg tp "$AC10_TILDE_PATH" '{transcript_path:$tp}')
run_stop_hook_with_input "$AC10_REPO" "$AC10_INPUT" "$FAKE_HOME"
assert_systemmessage_only \
    "AC-10: '~/'-prefixed transcript_path is expanded and short-circuits on pending bg" \
    "$AC10_REPO" "$AC10_STATE" "1 background task"

# Also prove the helper works directly against a "~/..." argument under a
# fake HOME. Avoids masking a helper regression behind the hook's own
# normalization.
AC10_HELPER_OUT=$(
    cd "$AC10_REPO"
    HOME="$FAKE_HOME"
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

# Verify the gate wrapper path with a tilde-form --transcript-path also
# reaches the short-circuit. AC-9 uses an absolute transcript path; this
# covers the same code path with a "~/..." form.
echo "Test AC-10c: rlcr-stop-gate.sh with '~/...' --transcript-path -> ALLOW"
AC10C_OUT="$TEST_DIR/ac10c-out.txt"
set +e
(
    cd "$AC10_REPO"
    HOME="$FAKE_HOME" "$GATE_SCRIPT" --transcript-path "$AC10_TILDE_PATH"
) > "$AC10C_OUT" 2>&1
AC10C_EXIT=$?
set -e

if [[ "$AC10C_EXIT" -eq 0 ]] \
   && grep -q "^ALLOW:" "$AC10C_OUT" \
   && grep -q "background task" "$AC10C_OUT"; then
    pass "AC-10c: rlcr-stop-gate.sh expands '~/...' and emits ALLOW with systemMessage"
else
    AC10C_BODY=$(cat "$AC10C_OUT" 2>/dev/null || true)
    fail "AC-10c: rlcr-stop-gate.sh expands '~/...' and emits ALLOW with systemMessage" \
        "exit 0 + output containing ALLOW: and 'background task'" \
        "exit $AC10C_EXIT; output: $AC10C_BODY"
fi

# ---------------- AC-11 / AC-11b ----------------
# Orphan prevention: when the short-circuit parks a loop waiting for a
# background task and the user closes that Claude session, a fresh
# session must still be able to pick up the loop. The short-circuit
# writes `bg-pending.marker` into the loop dir; find_active_loop
# accepts a stored-vs-filter session_id mismatch iff the marker is
# present. Without this cross-session adoption path, state.md would
# be stranded with the dead session_id and require manual cancel.
echo "Test AC-11: cross-session bg-pending.marker allows pickup"
AC11_REPO="$TEST_DIR/ac11"
AC11_LOOP=$(create_full_fixture "$AC11_REPO")
AC11_STATE="$AC11_LOOP/state.md"

# Override state.md with an explicit stored session_id so find_active_loop
# sees a real mismatch when we later pass a different session_id.
AC11_BRANCH=$(git -C "$AC11_REPO" rev-parse --abbrev-ref HEAD)
AC11_BASE_COMMIT=$(git -C "$AC11_REPO" rev-parse HEAD)
cat > "$AC11_STATE" <<EOF_AC11
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
start_branch: $AC11_BRANCH
base_branch: $AC11_BRANCH
base_commit: $AC11_BASE_COMMIT
review_started: false
ask_codex_question: false
agent_teams: false
session_id: session_alpha
---
EOF_AC11

# Simulate the state left by a previous session that took the short-circuit
# and then died (Claude window closed). The marker is the public contract
# between the short-circuit path and cross-session pickup.
: > "$AC11_LOOP/bg-pending.marker"

AC11_TRANSCRIPT="$TRANSCRIPTS_DIR/ac11.jsonl"
AC11_LAUNCH=$(emit_tool_use_assistant "toolu_I" "Agent" ',"description":"x","prompt":"x"')
AC11_RESULT=$(emit_async_agent_launch_result "toolu_I" "agent_pending_I")
write_transcript "$AC11_TRANSCRIPT" "$AC11_LAUNCH" "$AC11_RESULT"

AC11_INPUT=$(jq -c -n --arg tp "$AC11_TRANSCRIPT" \
    '{transcript_path:$tp, session_id:"session_beta"}')
run_stop_hook_with_input "$AC11_REPO" "$AC11_INPUT"
assert_systemmessage_only \
    "AC-11: cross-session bg-pending.marker allows pickup and short-circuit" \
    "$AC11_REPO" "$AC11_STATE" "1 background task"

# Negative counterpart: same session mismatch but NO marker must still
# reject the loop (preserving the existing session-bound isolation when
# the loop was not explicitly parked).
echo "Test AC-11b: cross-session without marker is still rejected"
AC11B_REPO="$TEST_DIR/ac11b"
AC11B_LOOP=$(create_full_fixture "$AC11B_REPO")
AC11B_STATE="$AC11B_LOOP/state.md"
AC11B_BRANCH=$(git -C "$AC11B_REPO" rev-parse --abbrev-ref HEAD)
AC11B_BASE_COMMIT=$(git -C "$AC11B_REPO" rev-parse HEAD)
cat > "$AC11B_STATE" <<EOF_AC11B
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
start_branch: $AC11B_BRANCH
base_branch: $AC11B_BRANCH
base_commit: $AC11B_BASE_COMMIT
review_started: false
ask_codex_question: false
agent_teams: false
session_id: session_alpha
---
EOF_AC11B
# Intentionally NO marker in AC11B_LOOP.

AC11B_TRANSCRIPT="$TRANSCRIPTS_DIR/ac11b.jsonl"
AC11B_LAUNCH=$(emit_tool_use_assistant "toolu_J" "Agent" ',"description":"x","prompt":"x"')
AC11B_RESULT=$(emit_async_agent_launch_result "toolu_J" "agent_pending_J")
write_transcript "$AC11B_TRANSCRIPT" "$AC11B_LAUNCH" "$AC11B_RESULT"

AC11B_INPUT=$(jq -c -n --arg tp "$AC11B_TRANSCRIPT" \
    '{transcript_path:$tp, session_id:"session_beta"}')
run_stop_hook_with_input "$AC11B_REPO" "$AC11B_INPUT"
AC11B_SYS_MSG=$(printf '%s' "$RUN_OUTPUT" | jq -r '.systemMessage // empty' 2>/dev/null || echo "")
if [[ "$RUN_EXIT_CODE" -eq 0 ]] && [[ ! -f "$RUN_MARKER" ]] && [[ -z "$AC11B_SYS_MSG" ]]; then
    pass "AC-11b: cross-session without marker keeps existing isolation (no adoption)"
else
    fail "AC-11b: cross-session without marker keeps existing isolation (no adoption)" \
        "exit 0, no Codex marker, no systemMessage" \
        "exit $RUN_EXIT_CODE, marker=$(test -f "$RUN_MARKER" && echo present || echo missing), systemMessage='$AC11B_SYS_MSG'; output: $RUN_OUTPUT"
fi

# AC-11c: short-circuit should actually write bg-pending.marker so the
# adoption path in AC-11 is reachable from real usage (not only from
# synthetic test setup).
echo "Test AC-11c: short-circuit writes bg-pending.marker"
AC11C_REPO="$TEST_DIR/ac11c"
AC11C_LOOP=$(create_full_fixture "$AC11C_REPO")
AC11C_MARKER="$AC11C_LOOP/bg-pending.marker"
[[ -e "$AC11C_MARKER" ]] && rm -f "$AC11C_MARKER"

AC11C_TRANSCRIPT="$TRANSCRIPTS_DIR/ac11c.jsonl"
AC11C_LAUNCH=$(emit_tool_use_assistant "toolu_K" "Agent" ',"description":"x","prompt":"x"')
AC11C_RESULT=$(emit_async_agent_launch_result "toolu_K" "agent_pending_K")
write_transcript "$AC11C_TRANSCRIPT" "$AC11C_LAUNCH" "$AC11C_RESULT"

AC11C_INPUT=$(jq -c -n --arg tp "$AC11C_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$AC11C_REPO" "$AC11C_INPUT"
if [[ "$RUN_EXIT_CODE" -eq 0 ]] && [[ -f "$AC11C_MARKER" ]]; then
    pass "AC-11c: short-circuit path writes bg-pending.marker into loop dir"
else
    fail "AC-11c: short-circuit path writes bg-pending.marker into loop dir" \
        "exit 0 and bg-pending.marker present" \
        "exit $RUN_EXIT_CODE, marker=$(test -f "$AC11C_MARKER" && echo present || echo missing); output: $RUN_OUTPUT"
fi

# ---------------- AC-12 ----------------
# Session isolation under multiple concurrent RLCR loops: when the caller's
# own exact-match dir exists in the listing, find_active_loop must return
# it even if a newer sibling dir (belonging to another session) also has a
# bg-pending.marker. The marker fallback is only for orphan recovery when
# no exact match exists.
echo "Test AC-12: find_active_loop prefers exact session match over marker"
AC12_BASE="$TEST_DIR/ac12-loops"
mkdir -p "$AC12_BASE/2026-03-02_00-00-00"
mkdir -p "$AC12_BASE/2026-03-01_00-00-00"

cat > "$AC12_BASE/2026-03-02_00-00-00/state.md" <<'EOF_AC12_NEWER'
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.4
codex_effort: high
session_id: session_foreign
---
EOF_AC12_NEWER
: > "$AC12_BASE/2026-03-02_00-00-00/bg-pending.marker"

cat > "$AC12_BASE/2026-03-01_00-00-00/state.md" <<'EOF_AC12_OLDER'
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.4
codex_effort: high
session_id: session_home
---
EOF_AC12_OLDER

AC12_RESULT=$(
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    find_active_loop "$AC12_BASE" "session_home"
)
if [[ "$AC12_RESULT" == "$AC12_BASE/2026-03-01_00-00-00" ]]; then
    pass "AC-12: find_active_loop returns older exact-match dir over newer marker dir"
else
    fail "AC-12: find_active_loop returns older exact-match dir over newer marker dir" \
        "$AC12_BASE/2026-03-01_00-00-00" "$AC12_RESULT"
fi

if [[ -f "$AC12_BASE/2026-03-02_00-00-00/bg-pending.marker" ]]; then
    pass "AC-12b: foreign session's marker untouched by find_active_loop scan"
else
    fail "AC-12b: foreign session's marker untouched by find_active_loop scan" \
        "newer dir marker still present" "marker was removed"
fi

# ---------------- AC-13 ----------------
# Same-session resume after background completion: a stale marker from the
# previous short-circuit must be cleaned up on the next stop where no bg is
# pending. State.md session_id stays put because it already matches.
echo "Test AC-13: same-session resume removes stale bg-pending.marker"
AC13_REPO="$TEST_DIR/ac13"
AC13_LOOP=$(create_full_fixture "$AC13_REPO")
AC13_STATE="$AC13_LOOP/state.md"
AC13_BRANCH=$(git -C "$AC13_REPO" rev-parse --abbrev-ref HEAD)
AC13_BASE_COMMIT=$(git -C "$AC13_REPO" rev-parse HEAD)
cat > "$AC13_STATE" <<EOF_AC13
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
start_branch: $AC13_BRANCH
base_branch: $AC13_BRANCH
base_commit: $AC13_BASE_COMMIT
review_started: false
ask_codex_question: false
agent_teams: false
session_id: session_home
---
EOF_AC13
: > "$AC13_LOOP/bg-pending.marker"

AC13_TRANSCRIPT="$TRANSCRIPTS_DIR/ac13.jsonl"
write_transcript "$AC13_TRANSCRIPT" '{"type":"user","message":{"role":"user","content":"hello"}}'
AC13_INPUT=$(jq -c -n --arg tp "$AC13_TRANSCRIPT" \
    '{transcript_path:$tp, session_id:"session_home"}')
run_stop_hook_with_input "$AC13_REPO" "$AC13_INPUT"

if [[ ! -f "$AC13_LOOP/bg-pending.marker" ]]; then
    pass "AC-13: marker removed on non-short-circuit resume (same session)"
else
    fail "AC-13: marker removed on non-short-circuit resume (same session)" \
        "marker absent" "marker still present"
fi

if grep -q "^session_id: session_home$" "$AC13_STATE"; then
    pass "AC-13b: same-session resume leaves state.md session_id unchanged"
else
    fail "AC-13b: same-session resume leaves state.md session_id unchanged" \
        "session_id: session_home" "$(grep '^session_id:' "$AC13_STATE" || echo '(missing)')"
fi

# ---------------- AC-14 ----------------
# Cross-session resume: a different session walks in, finds the loop through
# the marker fallback, and the non-short-circuit path must rewrite the
# stored session_id so future same-session stops use the exact-match path
# instead of re-adopting via a stale marker.
echo "Test AC-14: cross-session resume rewrites session_id and removes marker"
AC14_REPO="$TEST_DIR/ac14"
AC14_LOOP=$(create_full_fixture "$AC14_REPO")
AC14_STATE="$AC14_LOOP/state.md"
AC14_BRANCH=$(git -C "$AC14_REPO" rev-parse --abbrev-ref HEAD)
AC14_BASE_COMMIT=$(git -C "$AC14_REPO" rev-parse HEAD)
cat > "$AC14_STATE" <<EOF_AC14
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
start_branch: $AC14_BRANCH
base_branch: $AC14_BRANCH
base_commit: $AC14_BASE_COMMIT
review_started: false
ask_codex_question: false
agent_teams: false
session_id: session_foreign
---
EOF_AC14
: > "$AC14_LOOP/bg-pending.marker"

AC14_TRANSCRIPT="$TRANSCRIPTS_DIR/ac14.jsonl"
write_transcript "$AC14_TRANSCRIPT" '{"type":"user","message":{"role":"user","content":"hello"}}'
AC14_INPUT=$(jq -c -n --arg tp "$AC14_TRANSCRIPT" \
    '{transcript_path:$tp, session_id:"session_home"}')
run_stop_hook_with_input "$AC14_REPO" "$AC14_INPUT"

if [[ ! -f "$AC14_LOOP/bg-pending.marker" ]]; then
    pass "AC-14: marker removed after cross-session resume"
else
    fail "AC-14: marker removed after cross-session resume" \
        "marker absent" "marker still present"
fi

if grep -q "^session_id: session_home$" "$AC14_STATE"; then
    pass "AC-14b: state.md session_id rewritten to the current session on adoption"
else
    fail "AC-14b: state.md session_id rewritten to the current session on adoption" \
        "session_id: session_home" "$(grep '^session_id:' "$AC14_STATE" || echo '(missing)')"
fi

# ---------------- AC-15 ----------------
# Completion recognition: the current Claude Code transcript format emits
# background-task completion as
#   type: "system", subtype: "task_notification", task_id: "..."
# The helper must recognise this form (not only the legacy queue-operation
# XML block) or launched tasks will stay "pending" forever.
echo "Test AC-15: task_notification system records mark launches completed"
AC15_TRANSCRIPT="$TRANSCRIPTS_DIR/ac15.jsonl"
AC15_LAUNCH=$(emit_tool_use_assistant "toolu_L" "Agent" ',"description":"x","prompt":"x"')
AC15_RESULT=$(emit_async_agent_launch_result "toolu_L" "agent_done_L")
AC15_NOTIF=$(emit_sdk_task_notification "agent_done_L" "toolu_L" "completed")
write_transcript "$AC15_TRANSCRIPT" "$AC15_LAUNCH" "$AC15_RESULT" "$AC15_NOTIF"

AC15_PENDING=$(
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    list_pending_background_task_ids "$AC15_TRANSCRIPT" 2>/dev/null
)
if [[ -z "$AC15_PENDING" ]]; then
    pass "AC-15: task_notification completion removes the matching launch from pending"
else
    fail "AC-15: task_notification completion removes the matching launch from pending" \
        "empty pending list" "got: $AC15_PENDING"
fi

# ---------------- AC-16 ----------------
# Completion recognition mixed formats: two launches, one completed via the
# legacy queue-operation XML block, the other via the current
# system/task_notification record. Union of both sources must resolve to
# an empty pending set.
echo "Test AC-16: helper unions legacy queue-operation and task_notification completions"
AC16_TRANSCRIPT="$TRANSCRIPTS_DIR/ac16.jsonl"
AC16_L1=$(emit_tool_use_assistant "toolu_M1" "Agent" ',"description":"x","prompt":"x"')
AC16_R1=$(emit_async_agent_launch_result "toolu_M1" "agent_legacy_M1")
AC16_C1=$(emit_task_completion_event "agent_legacy_M1" "toolu_M1" "completed")
AC16_L2=$(emit_tool_use_assistant "toolu_M2" "Agent" ',"description":"y","prompt":"y"')
AC16_R2=$(emit_async_agent_launch_result "toolu_M2" "agent_sdk_M2")
AC16_C2=$(emit_sdk_task_notification "agent_sdk_M2" "toolu_M2" "completed")
write_transcript "$AC16_TRANSCRIPT" \
    "$AC16_L1" "$AC16_R1" "$AC16_C1" \
    "$AC16_L2" "$AC16_R2" "$AC16_C2"

AC16_PENDING=$(
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    list_pending_background_task_ids "$AC16_TRANSCRIPT" 2>/dev/null
)
if [[ -z "$AC16_PENDING" ]]; then
    pass "AC-16: mixed legacy+SDK completion records resolve to empty pending set"
else
    fail "AC-16: mixed legacy+SDK completion records resolve to empty pending set" \
        "empty pending list" "got: $AC16_PENDING"
fi

# ---------------- AC-17 ----------------
# Marker preservation when completion cannot be verified: if
# transcript_path is missing or unreadable, has_pending_background_tasks
# fails closed (returns no pending). The non-short-circuit cleanup must NOT
# erase bg-pending.marker or rewrite session_id in that case, because the
# cross-session recovery signal is still needed.
echo "Test AC-17: missing transcript preserves bg-pending.marker and session_id"
AC17_REPO="$TEST_DIR/ac17"
AC17_LOOP=$(create_full_fixture "$AC17_REPO")
AC17_STATE="$AC17_LOOP/state.md"
AC17_BRANCH=$(git -C "$AC17_REPO" rev-parse --abbrev-ref HEAD)
AC17_BASE_COMMIT=$(git -C "$AC17_REPO" rev-parse HEAD)
cat > "$AC17_STATE" <<EOF_AC17
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
start_branch: $AC17_BRANCH
base_branch: $AC17_BRANCH
base_commit: $AC17_BASE_COMMIT
review_started: false
ask_codex_question: false
agent_teams: false
session_id: session_foreign
---
EOF_AC17
: > "$AC17_LOOP/bg-pending.marker"

# Hook input has NO transcript_path -> has_pending_background_tasks is
# fail-closed; cleanup path must leave marker and session_id intact.
AC17_INPUT='{"session_id":"session_home"}'
run_stop_hook_with_input "$AC17_REPO" "$AC17_INPUT"

if [[ -f "$AC17_LOOP/bg-pending.marker" ]]; then
    pass "AC-17: unreadable transcript preserves bg-pending.marker"
else
    fail "AC-17: unreadable transcript preserves bg-pending.marker" \
        "marker still present" "marker was removed"
fi

if grep -q "^session_id: session_foreign$" "$AC17_STATE"; then
    pass "AC-17b: unreadable transcript leaves stored session_id untouched"
else
    fail "AC-17b: unreadable transcript leaves stored session_id untouched" \
        "session_id: session_foreign" "$(grep '^session_id:' "$AC17_STATE" || echo '(missing)')"
fi

# AC-17c: transcript_path is provided but points at a non-existent file
# (equally unreadable). Same guarantee: marker + stored session_id
# preserved.
echo "Test AC-17c: transcript_path pointing at non-existent file preserves marker"
AC17C_REPO="$TEST_DIR/ac17c"
AC17C_LOOP=$(create_full_fixture "$AC17C_REPO")
AC17C_STATE="$AC17C_LOOP/state.md"
AC17C_BRANCH=$(git -C "$AC17C_REPO" rev-parse --abbrev-ref HEAD)
AC17C_BASE_COMMIT=$(git -C "$AC17C_REPO" rev-parse HEAD)
cat > "$AC17C_STATE" <<EOF_AC17C
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
start_branch: $AC17C_BRANCH
base_branch: $AC17C_BRANCH
base_commit: $AC17C_BASE_COMMIT
review_started: false
ask_codex_question: false
agent_teams: false
session_id: session_foreign
---
EOF_AC17C
: > "$AC17C_LOOP/bg-pending.marker"

AC17C_INPUT=$(jq -c -n --arg tp "$TRANSCRIPTS_DIR/never-written.jsonl" \
    '{transcript_path:$tp, session_id:"session_home"}')
run_stop_hook_with_input "$AC17C_REPO" "$AC17C_INPUT"

if [[ -f "$AC17C_LOOP/bg-pending.marker" ]] \
   && grep -q "^session_id: session_foreign$" "$AC17C_STATE"; then
    pass "AC-17c: missing-file transcript_path preserves marker and session_id"
else
    fail "AC-17c: missing-file transcript_path preserves marker and session_id" \
        "marker present and session_id: session_foreign" \
        "marker=$(test -f "$AC17C_LOOP/bg-pending.marker" && echo present || echo missing); session_id=$(grep '^session_id:' "$AC17C_STATE" || echo '(missing)')"
fi

print_test_summary "Stop Hook Background-Task Allow Test Summary"
exit $?
