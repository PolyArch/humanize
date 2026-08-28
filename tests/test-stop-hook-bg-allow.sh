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
#   no bg dispatches                          -> normal Codex flow
#   pending subagent                          -> exit 0 + systemMessage
#   pending shell                             -> exit 0 + systemMessage
#   subagent launch + complete                -> normal Codex flow
#   2 subagents + 1 shell                     -> systemMessage mentions "3 background"
#   missing transcript path                   -> normal Codex flow (fail-closed)
#   no active loop                            -> exit 0, no systemMessage, no Codex
#   finalize phase pending bg                 -> exit 0 + systemMessage
#   via rlcr-stop-gate.sh                     -> exit 0 (wrapper ALLOW)
#   tilde transcript path                     -> short-circuit fires
#   cross-session bg-pending.marker           -> "parked" systemMessage, artifacts intact
#   find_active_loop prefers exact session    -> returns older exact-match dir
#   same-session resume                       -> stale marker removed
#   cross-session stop with marker            -> marker and stored session_id preserved
#   task_notification completion format       -> marks launch completed
#   mixed legacy + SDK completions            -> resolves to empty pending set
#   unreadable transcript with marker         -> marker and session_id preserved
#   find_active_loop default ignores marker   -> validators stay isolated
#   hook input omits session_id               -> cross-session guard fires
#   malformed transcript with marker          -> marker preserved (fail-closed)
#   TaskStop scan with non-string message     -> unrelated tool_result does not poison completions
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

# Fake HOME rooted inside $TEST_DIR so the tilde-path regressions (tilde transcript path,
# helper expands tilde path, stop-gate tilde path) do not write into the real user home. The hook, helper,
# and wrapper invocations that need tilde expansion run with HOME set to
# this directory; every other invocation keeps the real HOME. Cleanup is
# covered by the setup_test_dir EXIT trap because FAKE_HOME is under
# $TEST_DIR.
FAKE_HOME="$TEST_DIR/fake-home"
mkdir -p "$FAKE_HOME"

# ----------------------------------------------------------------------
# Mock lsof binaries used by the liveness-probe tests (alive task still short-circuits, dead/orphaned task pruned).
# lsof-alive exits 0 (simulates >= 1 holder: task is running).
# lsof-dead  exits 1 (simulates   0 holders: task is orphaned/dead).
# ----------------------------------------------------------------------
setup_mock_lsof() {
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/lsof-alive" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$TEST_DIR/bin/lsof-alive"

    cat > "$TEST_DIR/bin/lsof-dead" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$TEST_DIR/bin/lsof-dead"
}

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
codex_model: gpt-5.5
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
- no background dispatches: Hook reaches Codex review when no bg tasks are pending.
## MUTABLE SECTION
### Plan Version: 1 (Updated: Round 0)
#### Active Tasks
| Task | Target AC | Status | Notes |
|------|-----------|--------|-------|
| Exercise stop hook | no background dispatches | completed | - |
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

emit_bg_shell_launch_result_with_output_path() {
    local tool_use_id="$1" bg_task_id="$2" output_path="$3" include_suffix="${4:-1}"
    local suffix
    if [[ "$include_suffix" == "1" ]]; then
        suffix=". You will be notified when it completes."
    else
        suffix=""
    fi
    jq -c -n \
        --arg id "$tool_use_id" \
        --arg bid "$bg_task_id" \
        --arg out "$output_path" \
        --arg suffix "$suffix" \
        '{
          type:"user",
          message:{
            role:"user",
            content:[{tool_use_id:$id, type:"tool_result",
                      content:[{type:"text", text:("Command running in background with ID: " + $bid + ". Output is being written to: " + $out + $suffix)}]}]
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

# TaskStop tool_result: the harness records a top-level .toolUseResult
# whose .message is "Successfully stopped task: <id>" and .task_id is the
# stopped id. Many builds do NOT also emit a task_notification system
# event for a TaskStop, so the helper must recognise this form directly
# (source 3 in list_pending_background_task_ids).
emit_task_stop_result() {
    local tool_use_id="$1" task_id="$2"
    local msg="Successfully stopped task: $task_id"
    jq -c -n \
        --arg id "$tool_use_id" \
        --arg tid "$task_id" \
        --arg msg "$msg" \
        '{
          type:"user",
          message:{
            role:"user",
            content:[{tool_use_id:$id, type:"tool_result",
                      content:[{type:"text", text:$msg}]}]
          },
          toolUseResult:{message:$msg, task_id:$tid, task_type:"local_bash"}
        }'
}

# Variant of the TaskStop tool_result where the stopped id appears ONLY in
# the message text, not as a separate .toolUseResult.task_id field. The
# helper must still recognise it by parsing the message (the fallback path
# of source 3 in list_pending_background_task_ids). The message includes a
# parenthesised command suffix so the id-extraction regex is exercised at
# its "( " boundary, matching the real recorded form.
emit_task_stop_result_message_only() {
    local tool_use_id="$1" task_id="$2"
    local msg="Successfully stopped task: $task_id (mock command)"
    jq -c -n \
        --arg id "$tool_use_id" \
        --arg msg "$msg" \
        '{
          type:"user",
          message:{
            role:"user",
            content:[{tool_use_id:$id, type:"tool_result",
                      content:[{type:"text", text:$msg}]}]
          },
          toolUseResult:{message:$msg, task_type:"local_bash"}
        }'
}

# Unrelated tool_result whose .message is a structured value rather than a
# string. list_pending_background_task_ids scans every .toolUseResult while
# looking for TaskStop records; a non-string .message must not make jq's
# `contains()` error and poison the completion pipeline under pipefail.
emit_tool_result_nonstring_message() {
    local tool_use_id="$1"
    jq -c -n \
        --arg id "$tool_use_id" \
        '{
          type:"user",
          message:{
            role:"user",
            content:[{tool_use_id:$id, type:"tool_result",
                      content:[{type:"text", text:"structured result"}]}]
          },
          toolUseResult:{message:{status:"ok", details:[1,2,3]}, status:"success"}
        }'
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
    local repo_dir="$1" hook_input_json="$2" home_override="${3:-}" lsof_bin_override="${4:-}"

    RUN_MARKER="$repo_dir/codex-called.marker"
    rm -f "$RUN_MARKER"

    set +e
    RUN_OUTPUT=$(
        cd "$repo_dir"
        [[ -n "$home_override" ]] && export HOME="$home_override"
        [[ -n "$lsof_bin_override" ]] && export LSOF_BIN="$lsof_bin_override"
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
setup_mock_lsof

# Transcripts live outside any test repo to avoid tripping git cleanliness
# gates in the stop hook.
TRANSCRIPTS_DIR="$TEST_DIR/transcripts"
mkdir -p "$TRANSCRIPTS_DIR"

echo "=========================================="
echo "Stop Hook Background-Task Allow Tests"
echo "=========================================="
echo ""

# ---------------- no background dispatches ----------------
echo "Test: No bg dispatches -> reaches Codex"
NO_BG_DISPATCH_REPO="$TEST_DIR/no_bg_dispatch"
create_full_fixture "$NO_BG_DISPATCH_REPO" > /dev/null
NO_BG_DISPATCH_TRANSCRIPT="$TRANSCRIPTS_DIR/no_bg_dispatch.jsonl"
write_transcript "$NO_BG_DISPATCH_TRANSCRIPT" '{"type":"user","message":{"role":"user","content":"hello"}}'

NO_BG_DISPATCH_INPUT=$(jq -c -n --arg tp "$NO_BG_DISPATCH_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$NO_BG_DISPATCH_REPO" "$NO_BG_DISPATCH_INPUT"
assert_reached_codex "transcript without bg dispatches proceeds to Codex review"

# ---------------- pending background subagent ----------------
echo "Test: One pending background subagent -> exit 0 + systemMessage"
PENDING_SUBAGENT_REPO="$TEST_DIR/pending_subagent"
PENDING_SUBAGENT_LOOP=$(create_full_fixture "$PENDING_SUBAGENT_REPO")
PENDING_SUBAGENT_STATE="$PENDING_SUBAGENT_LOOP/state.md"
PENDING_SUBAGENT_TRANSCRIPT="$TRANSCRIPTS_DIR/pending_subagent.jsonl"
PENDING_SUBAGENT_LINE_LAUNCH=$(emit_tool_use_assistant "toolu_A" "Agent" ',"description":"x","prompt":"x"')
PENDING_SUBAGENT_LINE_RESULT=$(emit_async_agent_launch_result "toolu_A" "agent_pending_A")
write_transcript "$PENDING_SUBAGENT_TRANSCRIPT" "$PENDING_SUBAGENT_LINE_LAUNCH" "$PENDING_SUBAGENT_LINE_RESULT"

PENDING_SUBAGENT_INPUT=$(jq -c -n --arg tp "$PENDING_SUBAGENT_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$PENDING_SUBAGENT_REPO" "$PENDING_SUBAGENT_INPUT"
assert_systemmessage_only \
    "pending subagent triggers exit 0 + systemMessage, state untouched" \
    "$PENDING_SUBAGENT_REPO" "$PENDING_SUBAGENT_STATE" "1 background task"

# ---------------- pending background shell ----------------
echo "Test: One pending background shell -> exit 0 + systemMessage"
PENDING_SHELL_REPO="$TEST_DIR/pending_shell"
PENDING_SHELL_LOOP=$(create_full_fixture "$PENDING_SHELL_REPO")
PENDING_SHELL_STATE="$PENDING_SHELL_LOOP/state.md"
PENDING_SHELL_TRANSCRIPT="$TRANSCRIPTS_DIR/pending_shell.jsonl"
PENDING_SHELL_LINE_LAUNCH=$(emit_tool_use_assistant "toolu_B" "Bash" ',"command":"sleep 30"')
PENDING_SHELL_LINE_RESULT=$(emit_bg_shell_launch_result "toolu_B" "shell_pending_B")
write_transcript "$PENDING_SHELL_TRANSCRIPT" "$PENDING_SHELL_LINE_LAUNCH" "$PENDING_SHELL_LINE_RESULT"

PENDING_SHELL_INPUT=$(jq -c -n --arg tp "$PENDING_SHELL_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$PENDING_SHELL_REPO" "$PENDING_SHELL_INPUT"
assert_systemmessage_only \
    "pending background shell triggers exit 0 + systemMessage" \
    "$PENDING_SHELL_REPO" "$PENDING_SHELL_STATE" "1 background task"

# ---------------- subagent launch plus completion ----------------
echo "Test: Launched subagent with completion notification -> reaches Codex"
SUBAGENT_COMPLETE_REPO="$TEST_DIR/subagent_complete"
create_full_fixture "$SUBAGENT_COMPLETE_REPO" > /dev/null
SUBAGENT_COMPLETE_TRANSCRIPT="$TRANSCRIPTS_DIR/subagent_complete.jsonl"
SUBAGENT_COMPLETE_LAUNCH=$(emit_tool_use_assistant "toolu_C" "Agent" ',"description":"x","prompt":"x"')
SUBAGENT_COMPLETE_RESULT=$(emit_async_agent_launch_result "toolu_C" "agent_done_C")
SUBAGENT_COMPLETE_COMPLETE=$(emit_task_completion_event "agent_done_C" "toolu_C" "completed")
write_transcript "$SUBAGENT_COMPLETE_TRANSCRIPT" "$SUBAGENT_COMPLETE_LAUNCH" "$SUBAGENT_COMPLETE_RESULT" "$SUBAGENT_COMPLETE_COMPLETE"

SUBAGENT_COMPLETE_INPUT=$(jq -c -n --arg tp "$SUBAGENT_COMPLETE_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$SUBAGENT_COMPLETE_REPO" "$SUBAGENT_COMPLETE_INPUT"
assert_reached_codex "subagent with matching completion notification proceeds to Codex review"

# ---------------- multiple pending tasks ----------------
echo "Test: 2 pending subagents + 1 pending shell -> systemMessage mentions 3"
MULTI_PENDING_REPO="$TEST_DIR/multi_pending"
MULTI_PENDING_LOOP=$(create_full_fixture "$MULTI_PENDING_REPO")
MULTI_PENDING_STATE="$MULTI_PENDING_LOOP/state.md"
MULTI_PENDING_TRANSCRIPT="$TRANSCRIPTS_DIR/multi_pending.jsonl"
MULTI_PENDING_L1_LAUNCH=$(emit_tool_use_assistant "toolu_D1" "Agent" ',"description":"x","prompt":"x"')
MULTI_PENDING_L1_RESULT=$(emit_async_agent_launch_result "toolu_D1" "agent_pending_D1")
MULTI_PENDING_L2_LAUNCH=$(emit_tool_use_assistant "toolu_D2" "Agent" ',"description":"y","prompt":"y"')
MULTI_PENDING_L2_RESULT=$(emit_async_agent_launch_result "toolu_D2" "agent_pending_D2")
MULTI_PENDING_L3_LAUNCH=$(emit_tool_use_assistant "toolu_D3" "Bash" ',"command":"sleep 30"')
MULTI_PENDING_L3_RESULT=$(emit_bg_shell_launch_result "toolu_D3" "shell_pending_D3")
write_transcript "$MULTI_PENDING_TRANSCRIPT" \
    "$MULTI_PENDING_L1_LAUNCH" "$MULTI_PENDING_L1_RESULT" \
    "$MULTI_PENDING_L2_LAUNCH" "$MULTI_PENDING_L2_RESULT" \
    "$MULTI_PENDING_L3_LAUNCH" "$MULTI_PENDING_L3_RESULT"

MULTI_PENDING_INPUT=$(jq -c -n --arg tp "$MULTI_PENDING_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$MULTI_PENDING_REPO" "$MULTI_PENDING_INPUT"
assert_systemmessage_only \
    "2 pending subagents + 1 pending shell -> systemMessage mentions '3 background task(s)'" \
    "$MULTI_PENDING_REPO" "$MULTI_PENDING_STATE" "3 background task\\(s\\)"

# ---------------- missing transcript path ----------------
echo "Test: missing transcript path -> reaches Codex (fail-closed)"
MISSING_TRANSCRIPT_REPO="$TEST_DIR/missing_transcript"
create_full_fixture "$MISSING_TRANSCRIPT_REPO" > /dev/null
MISSING_TRANSCRIPT_INPUT=$(jq -c -n --arg tp "/nonexistent/file-$$.jsonl" '{transcript_path:$tp}')
run_stop_hook_with_input "$MISSING_TRANSCRIPT_REPO" "$MISSING_TRANSCRIPT_INPUT"
assert_reached_codex "missing transcript_path proceeds to Codex review (fail-closed)"

# Also: empty transcript_path field
EMPTY_TRANSCRIPT_PATH_REPO="$TEST_DIR/empty_transcript_path"
create_full_fixture "$EMPTY_TRANSCRIPT_PATH_REPO" > /dev/null
EMPTY_TRANSCRIPT_PATH_INPUT='{"transcript_path":""}'
run_stop_hook_with_input "$EMPTY_TRANSCRIPT_PATH_REPO" "$EMPTY_TRANSCRIPT_PATH_INPUT"
assert_reached_codex "empty transcript_path string proceeds to Codex review"

# And: no transcript_path key at all
ABSENT_TRANSCRIPT_PATH_REPO="$TEST_DIR/absent_transcript_path"
create_full_fixture "$ABSENT_TRANSCRIPT_PATH_REPO" > /dev/null
ABSENT_TRANSCRIPT_PATH_INPUT='{}'
run_stop_hook_with_input "$ABSENT_TRANSCRIPT_PATH_REPO" "$ABSENT_TRANSCRIPT_PATH_INPUT"
assert_reached_codex "hook input with no transcript_path proceeds to Codex review"

# ---------------- no active loop ----------------
echo "Test: No active loop -> exit 0, no systemMessage, no Codex"
NO_ACTIVE_LOOP_REPO="$TEST_DIR/no_active_loop"
create_empty_project "$NO_ACTIVE_LOOP_REPO"
NO_ACTIVE_LOOP_TRANSCRIPT="$TRANSCRIPTS_DIR/no_active_loop.jsonl"
NO_ACTIVE_LOOP_LAUNCH=$(emit_tool_use_assistant "toolu_E" "Agent" ',"description":"x","prompt":"x"')
NO_ACTIVE_LOOP_RESULT=$(emit_async_agent_launch_result "toolu_E" "agent_pending_E")
write_transcript "$NO_ACTIVE_LOOP_TRANSCRIPT" "$NO_ACTIVE_LOOP_LAUNCH" "$NO_ACTIVE_LOOP_RESULT"
NO_ACTIVE_LOOP_INPUT=$(jq -c -n --arg tp "$NO_ACTIVE_LOOP_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$NO_ACTIVE_LOOP_REPO" "$NO_ACTIVE_LOOP_INPUT"

NO_ACTIVE_LOOP_SYS_MSG=$(printf '%s' "$RUN_OUTPUT" | jq -r '.systemMessage // empty' 2>/dev/null || echo "")
if [[ "$RUN_EXIT_CODE" -eq 0 ]] && [[ ! -f "$RUN_MARKER" ]] && [[ -z "$NO_ACTIVE_LOOP_SYS_MSG" ]]; then
    pass "no active loop takes original exit-0 path without systemMessage"
else
    fail "no active loop takes original exit-0 path without systemMessage" \
        "exit 0, no Codex marker, no systemMessage" \
        "exit $RUN_EXIT_CODE, marker=$(test -f "$RUN_MARKER" && echo present || echo missing), systemMessage='$NO_ACTIVE_LOOP_SYS_MSG'; output: $RUN_OUTPUT"
fi

# ---------------- finalize phase with pending bg ----------------
echo "Test: Finalize phase + pending bg -> exit 0 + systemMessage"
FINALIZE_PENDING_REPO="$TEST_DIR/finalize_pending"
FINALIZE_PENDING_LOOP=$(create_full_fixture "$FINALIZE_PENDING_REPO" true)
FINALIZE_PENDING_STATE="$FINALIZE_PENDING_LOOP/finalize-state.md"
FINALIZE_PENDING_TRANSCRIPT="$TRANSCRIPTS_DIR/finalize_pending.jsonl"
FINALIZE_PENDING_LAUNCH=$(emit_tool_use_assistant "toolu_F" "Agent" ',"description":"x","prompt":"x"')
FINALIZE_PENDING_RESULT=$(emit_async_agent_launch_result "toolu_F" "agent_pending_F")
write_transcript "$FINALIZE_PENDING_TRANSCRIPT" "$FINALIZE_PENDING_LAUNCH" "$FINALIZE_PENDING_RESULT"
FINALIZE_PENDING_INPUT=$(jq -c -n --arg tp "$FINALIZE_PENDING_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$FINALIZE_PENDING_REPO" "$FINALIZE_PENDING_INPUT"
assert_systemmessage_only \
    "finalize phase with pending bg task -> exit 0 + systemMessage" \
    "$FINALIZE_PENDING_REPO" "$FINALIZE_PENDING_STATE" "1 background task"

# ---------------- invocation via rlcr-stop-gate.sh ----------------
echo "Test: rlcr-stop-gate.sh forwards transcript_path to hook"
VIA_STOP_GATE_REPO="$TEST_DIR/via_stop_gate"
create_full_fixture "$VIA_STOP_GATE_REPO" > /dev/null
VIA_STOP_GATE_TRANSCRIPT="$TRANSCRIPTS_DIR/via_stop_gate.jsonl"
VIA_STOP_GATE_LAUNCH=$(emit_tool_use_assistant "toolu_G" "Agent" ',"description":"x","prompt":"x"')
VIA_STOP_GATE_RESULT=$(emit_async_agent_launch_result "toolu_G" "agent_pending_G")
write_transcript "$VIA_STOP_GATE_TRANSCRIPT" "$VIA_STOP_GATE_LAUNCH" "$VIA_STOP_GATE_RESULT"

VIA_STOP_GATE_OUT="$VIA_STOP_GATE_REPO/gate-out.txt"
# Pass --project-root explicitly so an inherited CLAUDE_PROJECT_DIR
# from the outer runner cannot redirect the gate to the outer repo.
set +e
(
    cd "$VIA_STOP_GATE_REPO"
    "$GATE_SCRIPT" --project-root "$VIA_STOP_GATE_REPO" --transcript-path "$VIA_STOP_GATE_TRANSCRIPT"
) > "$VIA_STOP_GATE_OUT" 2>&1
VIA_STOP_GATE_EXIT=$?
set -e

if [[ "$VIA_STOP_GATE_EXIT" -eq 0 ]] && grep -q "^ALLOW:" "$VIA_STOP_GATE_OUT"; then
    pass "rlcr-stop-gate.sh exits 0 with ALLOW when bg tasks are pending"
else
    VIA_STOP_GATE_BODY=$(cat "$VIA_STOP_GATE_OUT" 2>/dev/null || true)
    fail "rlcr-stop-gate.sh exits 0 with ALLOW when bg tasks are pending" \
        "exit 0 and output containing ALLOW:" \
        "exit $VIA_STOP_GATE_EXIT; output: $VIA_STOP_GATE_BODY"
fi

# ---------------- tilde transcript path / helper expands tilde path / stop-gate tilde path ----------------
# Regression: real sessions pass transcript_path as "~/.claude/projects/...".
# Without tilde expansion the file check `[[ -f "~/..." ]]` is always false,
# so the short-circuit silently misses pending background tasks.
#
# The fixture lives under a fake HOME rooted inside $TEST_DIR so the tests
# remain portable on sandboxed or read-only-HOME environments. Only the
# specific hook / helper / wrapper invocations that need tilde expansion
# run with HOME=$FAKE_HOME; the rest of the suite keeps the real HOME.
echo "Test: '~/...' transcript path still triggers short-circuit"
TILDE_PATH_REPO="$TEST_DIR/tilde_path"
TILDE_PATH_LOOP=$(create_full_fixture "$TILDE_PATH_REPO")
TILDE_PATH_STATE="$TILDE_PATH_LOOP/state.md"

mkdir -p "$FAKE_HOME/session-data"
TILDE_PATH_TRANSCRIPT="$FAKE_HOME/session-data/tilde_path.jsonl"
TILDE_PATH_LAUNCH=$(emit_tool_use_assistant "toolu_H" "Agent" ',"description":"x","prompt":"x"')
TILDE_PATH_RESULT=$(emit_async_agent_launch_result "toolu_H" "agent_pending_H")
write_transcript "$TILDE_PATH_TRANSCRIPT" "$TILDE_PATH_LAUNCH" "$TILDE_PATH_RESULT"

# Build the tilde-form string literally. Do NOT let the shell expand "~".
TILDE_PATH_TILDE_PATH="~/session-data/tilde_path.jsonl"
TILDE_PATH_INPUT=$(jq -c -n --arg tp "$TILDE_PATH_TILDE_PATH" '{transcript_path:$tp}')
run_stop_hook_with_input "$TILDE_PATH_REPO" "$TILDE_PATH_INPUT" "$FAKE_HOME"
assert_systemmessage_only \
    "'~/'-prefixed transcript_path is expanded and short-circuits on pending bg" \
    "$TILDE_PATH_REPO" "$TILDE_PATH_STATE" "1 background task"

# Also prove the helper works directly against a "~/..." argument under a
# fake HOME. Avoids masking a helper regression behind the hook's own
# normalization.
TILDE_PATH_HELPER_OUT=$(
    cd "$TILDE_PATH_REPO"
    HOME="$FAKE_HOME"
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    list_pending_background_task_ids "$TILDE_PATH_TILDE_PATH" 2>/dev/null | sort -u
)
if printf '%s\n' "$TILDE_PATH_HELPER_OUT" | grep -qx 'agent_pending_H'; then
    pass "list_pending_background_task_ids expands '~/...' directly"
else
    fail "list_pending_background_task_ids expands '~/...' directly" \
        "output containing 'agent_pending_H'" "$TILDE_PATH_HELPER_OUT"
fi

# Verify the gate wrapper path with a tilde-form --transcript-path also
# reaches the short-circuit. invocation via rlcr-stop-gate.sh uses an absolute transcript path; this
# covers the same code path with a "~/..." form.
#
# Fresh fixture so the repo has no prior bg-pending.marker (tilde transcript path left
# one behind). The ambiguous-caller guard in the hook only silences the
# wrapper when a marker already exists; a clean repo falls through to
# the normal short-circuit so the systemMessage surfaces in the wrapper
# output.
echo "Test: rlcr-stop-gate.sh with '~/...' --transcript-path -> ALLOW"
TILDE_PATH_STOP_GATE_REPO="$TEST_DIR/tilde_path_stop_gate"
create_full_fixture "$TILDE_PATH_STOP_GATE_REPO" > /dev/null
mkdir -p "$FAKE_HOME/session-data-c"
TILDE_PATH_STOP_GATE_TRANSCRIPT="$FAKE_HOME/session-data-c/tilde_path_stop_gate.jsonl"
TILDE_PATH_STOP_GATE_LAUNCH=$(emit_tool_use_assistant "toolu_H2" "Agent" ',"description":"x","prompt":"x"')
TILDE_PATH_STOP_GATE_RESULT=$(emit_async_agent_launch_result "toolu_H2" "agent_pending_H2")
write_transcript "$TILDE_PATH_STOP_GATE_TRANSCRIPT" "$TILDE_PATH_STOP_GATE_LAUNCH" "$TILDE_PATH_STOP_GATE_RESULT"
TILDE_PATH_STOP_GATE_TILDE_PATH="~/session-data-c/tilde_path_stop_gate.jsonl"

TILDE_PATH_STOP_GATE_OUT="$TEST_DIR/tilde_path_stop_gate-out.txt"
set +e
(
    cd "$TILDE_PATH_STOP_GATE_REPO"
    HOME="$FAKE_HOME" "$GATE_SCRIPT" \
        --project-root "$TILDE_PATH_STOP_GATE_REPO" \
        --transcript-path "$TILDE_PATH_STOP_GATE_TILDE_PATH"
) > "$TILDE_PATH_STOP_GATE_OUT" 2>&1
TILDE_PATH_STOP_GATE_EXIT=$?
set -e

if [[ "$TILDE_PATH_STOP_GATE_EXIT" -eq 0 ]] \
   && grep -q "^ALLOW:" "$TILDE_PATH_STOP_GATE_OUT" \
   && grep -q "background task" "$TILDE_PATH_STOP_GATE_OUT"; then
    pass "rlcr-stop-gate.sh expands '~/...' and emits ALLOW with systemMessage"
else
    TILDE_PATH_STOP_GATE_BODY=$(cat "$TILDE_PATH_STOP_GATE_OUT" 2>/dev/null || true)
    fail "rlcr-stop-gate.sh expands '~/...' and emits ALLOW with systemMessage" \
        "exit 0 + output containing ALLOW: and 'background task'" \
        "exit $TILDE_PATH_STOP_GATE_EXIT; output: $TILDE_PATH_STOP_GATE_BODY"
fi

# ---------------- cross-session bg-pending marker / cross-session without marker ----------------
# Cross-session parked-loop guard: when a loop in the repo carries the
# bg-pending.marker and its stored session_id does not match the caller,
# the stop hook must exit 0 with a dedicated "parked by another session"
# systemMessage and leave every on-disk artifact intact. The current
# session has no authority to advance or cleanup a foreign parked loop
# because its transcript cannot observe the other session's bg task.
echo "Test: cross-session bg-pending.marker emits 'parked' systemMessage"
CROSS_SESSION_MARKER_REPO="$TEST_DIR/cross_session_marker"
CROSS_SESSION_MARKER_LOOP=$(create_full_fixture "$CROSS_SESSION_MARKER_REPO")
CROSS_SESSION_MARKER_STATE="$CROSS_SESSION_MARKER_LOOP/state.md"
CROSS_SESSION_MARKER_MARKER="$CROSS_SESSION_MARKER_LOOP/bg-pending.marker"

# Override state.md with an explicit stored session_id so find_active_loop
# sees a real mismatch when we later pass a different session_id.
CROSS_SESSION_MARKER_BRANCH=$(git -C "$CROSS_SESSION_MARKER_REPO" rev-parse --abbrev-ref HEAD)
CROSS_SESSION_MARKER_BASE_COMMIT=$(git -C "$CROSS_SESSION_MARKER_REPO" rev-parse HEAD)
cat > "$CROSS_SESSION_MARKER_STATE" <<EOF_CROSS_SESSION_MARKER
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.5
codex_effort: high
codex_timeout: 60
push_every_round: false
full_review_round: 5
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $CROSS_SESSION_MARKER_BRANCH
base_branch: $CROSS_SESSION_MARKER_BRANCH
base_commit: $CROSS_SESSION_MARKER_BASE_COMMIT
review_started: false
ask_codex_question: false
agent_teams: false
session_id: session_alpha
---
EOF_CROSS_SESSION_MARKER
CROSS_SESSION_MARKER_STATE_HASH_BEFORE=$(sha256sum "$CROSS_SESSION_MARKER_STATE" | awk '{print $1}')

# Simulate the state left by a previous session that took the short-circuit.
: > "$CROSS_SESSION_MARKER_MARKER"

CROSS_SESSION_MARKER_TRANSCRIPT="$TRANSCRIPTS_DIR/cross_session_marker.jsonl"
CROSS_SESSION_MARKER_LAUNCH=$(emit_tool_use_assistant "toolu_I" "Agent" ',"description":"x","prompt":"x"')
CROSS_SESSION_MARKER_RESULT=$(emit_async_agent_launch_result "toolu_I" "agent_pending_I")
write_transcript "$CROSS_SESSION_MARKER_TRANSCRIPT" "$CROSS_SESSION_MARKER_LAUNCH" "$CROSS_SESSION_MARKER_RESULT"

CROSS_SESSION_MARKER_INPUT=$(jq -c -n --arg tp "$CROSS_SESSION_MARKER_TRANSCRIPT" \
    '{transcript_path:$tp, session_id:"session_beta"}')
run_stop_hook_with_input "$CROSS_SESSION_MARKER_REPO" "$CROSS_SESSION_MARKER_INPUT"
CROSS_SESSION_MARKER_SYS_MSG=$(printf '%s' "$RUN_OUTPUT" | jq -r '.systemMessage // empty' 2>/dev/null || echo "")
CROSS_SESSION_MARKER_STATE_HASH_AFTER=$(sha256sum "$CROSS_SESSION_MARKER_STATE" | awk '{print $1}')
if [[ "$RUN_EXIT_CODE" -eq 0 ]] \
   && [[ ! -f "$RUN_MARKER" ]] \
   && [[ -f "$CROSS_SESSION_MARKER_MARKER" ]] \
   && [[ "$CROSS_SESSION_MARKER_STATE_HASH_BEFORE" == "$CROSS_SESSION_MARKER_STATE_HASH_AFTER" ]] \
   && printf '%s' "$CROSS_SESSION_MARKER_SYS_MSG" | grep -qi "parked"; then
    pass "cross-session stop exits with 'parked' systemMessage; marker and session_id untouched"
else
    fail "cross-session stop exits with 'parked' systemMessage; marker and session_id untouched" \
        "exit 0 + systemMessage matches /parked/ + marker stays + state.md byte-identical + no Codex" \
        "exit $RUN_EXIT_CODE, codex_marker=$(test -f "$RUN_MARKER" && echo present || echo missing), bg_marker=$(test -f "$CROSS_SESSION_MARKER_MARKER" && echo present || echo missing), state_unchanged=$([[ "$CROSS_SESSION_MARKER_STATE_HASH_BEFORE" == "$CROSS_SESSION_MARKER_STATE_HASH_AFTER" ]] && echo yes || echo no), systemMessage='$CROSS_SESSION_MARKER_SYS_MSG'; output: $RUN_OUTPUT"
fi

# Negative counterpart: same session mismatch but NO marker must still
# reject the loop (preserving the existing session-bound isolation when
# the loop was not explicitly parked).
echo "Test: cross-session without marker is still rejected"
CROSS_SESSION_NO_MARKER_REPO="$TEST_DIR/cross_session_no_marker"
CROSS_SESSION_NO_MARKER_LOOP=$(create_full_fixture "$CROSS_SESSION_NO_MARKER_REPO")
CROSS_SESSION_NO_MARKER_STATE="$CROSS_SESSION_NO_MARKER_LOOP/state.md"
CROSS_SESSION_NO_MARKER_BRANCH=$(git -C "$CROSS_SESSION_NO_MARKER_REPO" rev-parse --abbrev-ref HEAD)
CROSS_SESSION_NO_MARKER_BASE_COMMIT=$(git -C "$CROSS_SESSION_NO_MARKER_REPO" rev-parse HEAD)
cat > "$CROSS_SESSION_NO_MARKER_STATE" <<EOF_CROSS_SESSION_NO_MARKER
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.5
codex_effort: high
codex_timeout: 60
push_every_round: false
full_review_round: 5
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $CROSS_SESSION_NO_MARKER_BRANCH
base_branch: $CROSS_SESSION_NO_MARKER_BRANCH
base_commit: $CROSS_SESSION_NO_MARKER_BASE_COMMIT
review_started: false
ask_codex_question: false
agent_teams: false
session_id: session_alpha
---
EOF_CROSS_SESSION_NO_MARKER
# Intentionally NO marker in CROSS_SESSION_NO_MARKER_LOOP.

CROSS_SESSION_NO_MARKER_TRANSCRIPT="$TRANSCRIPTS_DIR/cross_session_no_marker.jsonl"
CROSS_SESSION_NO_MARKER_LAUNCH=$(emit_tool_use_assistant "toolu_J" "Agent" ',"description":"x","prompt":"x"')
CROSS_SESSION_NO_MARKER_RESULT=$(emit_async_agent_launch_result "toolu_J" "agent_pending_J")
write_transcript "$CROSS_SESSION_NO_MARKER_TRANSCRIPT" "$CROSS_SESSION_NO_MARKER_LAUNCH" "$CROSS_SESSION_NO_MARKER_RESULT"

CROSS_SESSION_NO_MARKER_INPUT=$(jq -c -n --arg tp "$CROSS_SESSION_NO_MARKER_TRANSCRIPT" \
    '{transcript_path:$tp, session_id:"session_beta"}')
run_stop_hook_with_input "$CROSS_SESSION_NO_MARKER_REPO" "$CROSS_SESSION_NO_MARKER_INPUT"
CROSS_SESSION_NO_MARKER_SYS_MSG=$(printf '%s' "$RUN_OUTPUT" | jq -r '.systemMessage // empty' 2>/dev/null || echo "")
if [[ "$RUN_EXIT_CODE" -eq 0 ]] && [[ ! -f "$RUN_MARKER" ]] && [[ -z "$CROSS_SESSION_NO_MARKER_SYS_MSG" ]]; then
    pass "cross-session without marker keeps existing isolation (no adoption)"
else
    fail "cross-session without marker keeps existing isolation (no adoption)" \
        "exit 0, no Codex marker, no systemMessage" \
        "exit $RUN_EXIT_CODE, marker=$(test -f "$RUN_MARKER" && echo present || echo missing), systemMessage='$CROSS_SESSION_NO_MARKER_SYS_MSG'; output: $RUN_OUTPUT"
fi

# short-circuit should actually write bg-pending.marker so the
# adoption path in cross-session bg-pending marker is reachable from real usage (not only from
# synthetic test setup).
echo "Test: short-circuit writes bg-pending.marker"
SHORT_CIRCUIT_WRITES_MARKER_REPO="$TEST_DIR/short_circuit_writes_marker"
SHORT_CIRCUIT_WRITES_MARKER_LOOP=$(create_full_fixture "$SHORT_CIRCUIT_WRITES_MARKER_REPO")
SHORT_CIRCUIT_WRITES_MARKER_MARKER="$SHORT_CIRCUIT_WRITES_MARKER_LOOP/bg-pending.marker"
[[ -e "$SHORT_CIRCUIT_WRITES_MARKER_MARKER" ]] && rm -f "$SHORT_CIRCUIT_WRITES_MARKER_MARKER"

SHORT_CIRCUIT_WRITES_MARKER_TRANSCRIPT="$TRANSCRIPTS_DIR/short_circuit_writes_marker.jsonl"
SHORT_CIRCUIT_WRITES_MARKER_LAUNCH=$(emit_tool_use_assistant "toolu_K" "Agent" ',"description":"x","prompt":"x"')
SHORT_CIRCUIT_WRITES_MARKER_RESULT=$(emit_async_agent_launch_result "toolu_K" "agent_pending_K")
write_transcript "$SHORT_CIRCUIT_WRITES_MARKER_TRANSCRIPT" "$SHORT_CIRCUIT_WRITES_MARKER_LAUNCH" "$SHORT_CIRCUIT_WRITES_MARKER_RESULT"

SHORT_CIRCUIT_WRITES_MARKER_INPUT=$(jq -c -n --arg tp "$SHORT_CIRCUIT_WRITES_MARKER_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$SHORT_CIRCUIT_WRITES_MARKER_REPO" "$SHORT_CIRCUIT_WRITES_MARKER_INPUT"
if [[ "$RUN_EXIT_CODE" -eq 0 ]] && [[ -f "$SHORT_CIRCUIT_WRITES_MARKER_MARKER" ]]; then
    pass "short-circuit path writes bg-pending.marker into loop dir"
else
    fail "short-circuit path writes bg-pending.marker into loop dir" \
        "exit 0 and bg-pending.marker present" \
        "exit $RUN_EXIT_CODE, marker=$(test -f "$SHORT_CIRCUIT_WRITES_MARKER_MARKER" && echo present || echo missing); output: $RUN_OUTPUT"
fi

# ---------------- find_active_loop prefers exact session ----------------
# Session isolation under multiple concurrent RLCR loops: when the caller's
# own exact-match dir exists in the listing, find_active_loop must return
# it even if a newer sibling dir (belonging to another session) also has a
# bg-pending.marker. The marker fallback is only for orphan recovery when
# no exact match exists.
echo "Test: find_active_loop prefers exact session match over marker"
FIND_LOOP_EXACT_SESSION_BASE="$TEST_DIR/find_loop_exact_session-loops"
mkdir -p "$FIND_LOOP_EXACT_SESSION_BASE/2026-03-02_00-00-00"
mkdir -p "$FIND_LOOP_EXACT_SESSION_BASE/2026-03-01_00-00-00"

cat > "$FIND_LOOP_EXACT_SESSION_BASE/2026-03-02_00-00-00/state.md" <<'EOF_FIND_LOOP_EXACT_SESSION_NEWER'
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.5
codex_effort: high
session_id: session_foreign
---
EOF_FIND_LOOP_EXACT_SESSION_NEWER
: > "$FIND_LOOP_EXACT_SESSION_BASE/2026-03-02_00-00-00/bg-pending.marker"

cat > "$FIND_LOOP_EXACT_SESSION_BASE/2026-03-01_00-00-00/state.md" <<'EOF_FIND_LOOP_EXACT_SESSION_OLDER'
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.5
codex_effort: high
session_id: session_home
---
EOF_FIND_LOOP_EXACT_SESSION_OLDER

FIND_LOOP_EXACT_SESSION_RESULT=$(
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    find_active_loop "$FIND_LOOP_EXACT_SESSION_BASE" "session_home"
)
if [[ "$FIND_LOOP_EXACT_SESSION_RESULT" == "$FIND_LOOP_EXACT_SESSION_BASE/2026-03-01_00-00-00" ]]; then
    pass "find_active_loop returns older exact-match dir over newer marker dir"
else
    fail "find_active_loop returns older exact-match dir over newer marker dir" \
        "$FIND_LOOP_EXACT_SESSION_BASE/2026-03-01_00-00-00" "$FIND_LOOP_EXACT_SESSION_RESULT"
fi

if [[ -f "$FIND_LOOP_EXACT_SESSION_BASE/2026-03-02_00-00-00/bg-pending.marker" ]]; then
    pass "foreign session's marker untouched by find_active_loop scan"
else
    fail "foreign session's marker untouched by find_active_loop scan" \
        "newer dir marker still present" "marker was removed"
fi

# ---------------- same-session resume clears marker ----------------
# Same-session resume after background completion: a stale marker from the
# previous short-circuit must be cleaned up on the next stop where no bg is
# pending. State.md session_id stays put because it already matches.
echo "Test: same-session resume removes stale bg-pending.marker"
SAME_SESSION_RESUME_REPO="$TEST_DIR/same_session_resume"
SAME_SESSION_RESUME_LOOP=$(create_full_fixture "$SAME_SESSION_RESUME_REPO")
SAME_SESSION_RESUME_STATE="$SAME_SESSION_RESUME_LOOP/state.md"
SAME_SESSION_RESUME_BRANCH=$(git -C "$SAME_SESSION_RESUME_REPO" rev-parse --abbrev-ref HEAD)
SAME_SESSION_RESUME_BASE_COMMIT=$(git -C "$SAME_SESSION_RESUME_REPO" rev-parse HEAD)
cat > "$SAME_SESSION_RESUME_STATE" <<EOF_SAME_SESSION_RESUME
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.5
codex_effort: high
codex_timeout: 60
push_every_round: false
full_review_round: 5
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $SAME_SESSION_RESUME_BRANCH
base_branch: $SAME_SESSION_RESUME_BRANCH
base_commit: $SAME_SESSION_RESUME_BASE_COMMIT
review_started: false
ask_codex_question: false
agent_teams: false
session_id: session_home
---
EOF_SAME_SESSION_RESUME
: > "$SAME_SESSION_RESUME_LOOP/bg-pending.marker"

SAME_SESSION_RESUME_TRANSCRIPT="$TRANSCRIPTS_DIR/same_session_resume.jsonl"
write_transcript "$SAME_SESSION_RESUME_TRANSCRIPT" '{"type":"user","message":{"role":"user","content":"hello"}}'
SAME_SESSION_RESUME_INPUT=$(jq -c -n --arg tp "$SAME_SESSION_RESUME_TRANSCRIPT" \
    '{transcript_path:$tp, session_id:"session_home"}')
run_stop_hook_with_input "$SAME_SESSION_RESUME_REPO" "$SAME_SESSION_RESUME_INPUT"

if [[ ! -f "$SAME_SESSION_RESUME_LOOP/bg-pending.marker" ]]; then
    pass "marker removed on non-short-circuit resume (same session)"
else
    fail "marker removed on non-short-circuit resume (same session)" \
        "marker absent" "marker still present"
fi

if grep -q "^session_id: session_home$" "$SAME_SESSION_RESUME_STATE"; then
    pass "same-session resume leaves state.md session_id unchanged"
else
    fail "same-session resume leaves state.md session_id unchanged" \
        "session_id: session_home" "$(grep '^session_id:' "$SAME_SESSION_RESUME_STATE" || echo '(missing)')"
fi

# ---------------- cross-session stop preserves marker ----------------
# Anti-hijack: a different session walking in MUST NOT rewrite the stored
# session_id and MUST NOT delete bg-pending.marker, even when its own
# transcript shows no pending bg events. The foreign session's transcript
# cannot observe the parking session's bg activity, so nothing the new
# session sees is authoritative. The cross-session guard takes over
# instead.
echo "Test: cross-session stop preserves marker and stored session_id"
CROSS_SESSION_PRESERVE_REPO="$TEST_DIR/cross_session_preserve"
CROSS_SESSION_PRESERVE_LOOP=$(create_full_fixture "$CROSS_SESSION_PRESERVE_REPO")
CROSS_SESSION_PRESERVE_STATE="$CROSS_SESSION_PRESERVE_LOOP/state.md"
CROSS_SESSION_PRESERVE_MARKER="$CROSS_SESSION_PRESERVE_LOOP/bg-pending.marker"
CROSS_SESSION_PRESERVE_BRANCH=$(git -C "$CROSS_SESSION_PRESERVE_REPO" rev-parse --abbrev-ref HEAD)
CROSS_SESSION_PRESERVE_BASE_COMMIT=$(git -C "$CROSS_SESSION_PRESERVE_REPO" rev-parse HEAD)
cat > "$CROSS_SESSION_PRESERVE_STATE" <<EOF_CROSS_SESSION_PRESERVE
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.5
codex_effort: high
codex_timeout: 60
push_every_round: false
full_review_round: 5
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $CROSS_SESSION_PRESERVE_BRANCH
base_branch: $CROSS_SESSION_PRESERVE_BRANCH
base_commit: $CROSS_SESSION_PRESERVE_BASE_COMMIT
review_started: false
ask_codex_question: false
agent_teams: false
session_id: session_foreign
---
EOF_CROSS_SESSION_PRESERVE
: > "$CROSS_SESSION_PRESERVE_MARKER"

CROSS_SESSION_PRESERVE_TRANSCRIPT="$TRANSCRIPTS_DIR/cross_session_preserve.jsonl"
write_transcript "$CROSS_SESSION_PRESERVE_TRANSCRIPT" '{"type":"user","message":{"role":"user","content":"hello"}}'
CROSS_SESSION_PRESERVE_INPUT=$(jq -c -n --arg tp "$CROSS_SESSION_PRESERVE_TRANSCRIPT" \
    '{transcript_path:$tp, session_id:"session_home"}')
run_stop_hook_with_input "$CROSS_SESSION_PRESERVE_REPO" "$CROSS_SESSION_PRESERVE_INPUT"

if [[ -f "$CROSS_SESSION_PRESERVE_MARKER" ]]; then
    pass "cross-session stop preserves bg-pending.marker"
else
    fail "cross-session stop preserves bg-pending.marker" \
        "marker still present" "marker was removed (foreign-session hijack)"
fi

if grep -q "^session_id: session_foreign$" "$CROSS_SESSION_PRESERVE_STATE"; then
    pass "cross-session stop leaves stored session_id intact"
else
    fail "cross-session stop leaves stored session_id intact" \
        "session_id: session_foreign" "$(grep '^session_id:' "$CROSS_SESSION_PRESERVE_STATE" || echo '(missing)')"
fi

# ---------------- task_notification completion ----------------
# Completion recognition: the current Claude Code transcript format emits
# background-task completion as
#   type: "system", subtype: "task_notification", task_id: "..."
# The helper must recognise this form (not only the legacy queue-operation
# XML block) or launched tasks will stay "pending" forever.
echo "Test: task_notification system records mark launches completed"
TASK_NOTIFICATION_COMPLETE_TRANSCRIPT="$TRANSCRIPTS_DIR/task_notification_complete.jsonl"
TASK_NOTIFICATION_COMPLETE_LAUNCH=$(emit_tool_use_assistant "toolu_L" "Agent" ',"description":"x","prompt":"x"')
TASK_NOTIFICATION_COMPLETE_RESULT=$(emit_async_agent_launch_result "toolu_L" "agent_done_L")
TASK_NOTIFICATION_COMPLETE_NOTIF=$(emit_sdk_task_notification "agent_done_L" "toolu_L" "completed")
write_transcript "$TASK_NOTIFICATION_COMPLETE_TRANSCRIPT" "$TASK_NOTIFICATION_COMPLETE_LAUNCH" "$TASK_NOTIFICATION_COMPLETE_RESULT" "$TASK_NOTIFICATION_COMPLETE_NOTIF"

TASK_NOTIFICATION_COMPLETE_PENDING=$(
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    list_pending_background_task_ids "$TASK_NOTIFICATION_COMPLETE_TRANSCRIPT" 2>/dev/null
)
if [[ -z "$TASK_NOTIFICATION_COMPLETE_PENDING" ]]; then
    pass "task_notification completion removes the matching launch from pending"
else
    fail "task_notification completion removes the matching launch from pending" \
        "empty pending list" "got: $TASK_NOTIFICATION_COMPLETE_PENDING"
fi

# ---------------- mixed completion formats ----------------
# Completion recognition mixed formats: two launches, one completed via the
# legacy queue-operation XML block, the other via the current
# system/task_notification record. Union of both sources must resolve to
# an empty pending set.
echo "Test: helper unions legacy queue-operation and task_notification completions"
MIXED_COMPLETION_FORMATS_TRANSCRIPT="$TRANSCRIPTS_DIR/mixed_completion_formats.jsonl"
MIXED_COMPLETION_FORMATS_L1=$(emit_tool_use_assistant "toolu_M1" "Agent" ',"description":"x","prompt":"x"')
MIXED_COMPLETION_FORMATS_R1=$(emit_async_agent_launch_result "toolu_M1" "agent_legacy_M1")
MIXED_COMPLETION_FORMATS_C1=$(emit_task_completion_event "agent_legacy_M1" "toolu_M1" "completed")
MIXED_COMPLETION_FORMATS_L2=$(emit_tool_use_assistant "toolu_M2" "Agent" ',"description":"y","prompt":"y"')
MIXED_COMPLETION_FORMATS_R2=$(emit_async_agent_launch_result "toolu_M2" "agent_sdk_M2")
MIXED_COMPLETION_FORMATS_C2=$(emit_sdk_task_notification "agent_sdk_M2" "toolu_M2" "completed")
write_transcript "$MIXED_COMPLETION_FORMATS_TRANSCRIPT" \
    "$MIXED_COMPLETION_FORMATS_L1" "$MIXED_COMPLETION_FORMATS_R1" "$MIXED_COMPLETION_FORMATS_C1" \
    "$MIXED_COMPLETION_FORMATS_L2" "$MIXED_COMPLETION_FORMATS_R2" "$MIXED_COMPLETION_FORMATS_C2"

MIXED_COMPLETION_FORMATS_PENDING=$(
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    list_pending_background_task_ids "$MIXED_COMPLETION_FORMATS_TRANSCRIPT" 2>/dev/null
)
if [[ -z "$MIXED_COMPLETION_FORMATS_PENDING" ]]; then
    pass "mixed legacy+SDK completion records resolve to empty pending set"
else
    fail "mixed legacy+SDK completion records resolve to empty pending set" \
        "empty pending list" "got: $MIXED_COMPLETION_FORMATS_PENDING"
fi

# ---------------- unreadable transcript with marker ----------------
# Marker preservation when completion cannot be verified: if
# transcript_path is missing or unreadable, has_pending_background_tasks
# fails closed (returns no pending). The non-short-circuit cleanup must NOT
# erase bg-pending.marker or rewrite session_id in that case, because the
# cross-session recovery signal is still needed.
echo "Test: missing transcript preserves bg-pending.marker and session_id"
UNREADABLE_TRANSCRIPT_REPO="$TEST_DIR/unreadable_transcript"
UNREADABLE_TRANSCRIPT_LOOP=$(create_full_fixture "$UNREADABLE_TRANSCRIPT_REPO")
UNREADABLE_TRANSCRIPT_STATE="$UNREADABLE_TRANSCRIPT_LOOP/state.md"
UNREADABLE_TRANSCRIPT_BRANCH=$(git -C "$UNREADABLE_TRANSCRIPT_REPO" rev-parse --abbrev-ref HEAD)
UNREADABLE_TRANSCRIPT_BASE_COMMIT=$(git -C "$UNREADABLE_TRANSCRIPT_REPO" rev-parse HEAD)
cat > "$UNREADABLE_TRANSCRIPT_STATE" <<EOF_UNREADABLE_TRANSCRIPT
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.5
codex_effort: high
codex_timeout: 60
push_every_round: false
full_review_round: 5
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $UNREADABLE_TRANSCRIPT_BRANCH
base_branch: $UNREADABLE_TRANSCRIPT_BRANCH
base_commit: $UNREADABLE_TRANSCRIPT_BASE_COMMIT
review_started: false
ask_codex_question: false
agent_teams: false
session_id: session_foreign
---
EOF_UNREADABLE_TRANSCRIPT
: > "$UNREADABLE_TRANSCRIPT_LOOP/bg-pending.marker"

# Hook input has NO transcript_path -> has_pending_background_tasks is
# fail-closed; cleanup path must leave marker and session_id intact.
UNREADABLE_TRANSCRIPT_INPUT='{"session_id":"session_home"}'
run_stop_hook_with_input "$UNREADABLE_TRANSCRIPT_REPO" "$UNREADABLE_TRANSCRIPT_INPUT"

if [[ -f "$UNREADABLE_TRANSCRIPT_LOOP/bg-pending.marker" ]]; then
    pass "unreadable transcript preserves bg-pending.marker"
else
    fail "unreadable transcript preserves bg-pending.marker" \
        "marker still present" "marker was removed"
fi

if grep -q "^session_id: session_foreign$" "$UNREADABLE_TRANSCRIPT_STATE"; then
    pass "unreadable transcript leaves stored session_id untouched"
else
    fail "unreadable transcript leaves stored session_id untouched" \
        "session_id: session_foreign" "$(grep '^session_id:' "$UNREADABLE_TRANSCRIPT_STATE" || echo '(missing)')"
fi

# transcript_path is provided but points at a non-existent file
# (equally unreadable). Same guarantee: marker + stored session_id
# preserved.
echo "Test: transcript_path pointing at non-existent file preserves marker"
MISSING_FILE_TRANSCRIPT_REPO="$TEST_DIR/missing_file_transcript"
MISSING_FILE_TRANSCRIPT_LOOP=$(create_full_fixture "$MISSING_FILE_TRANSCRIPT_REPO")
MISSING_FILE_TRANSCRIPT_STATE="$MISSING_FILE_TRANSCRIPT_LOOP/state.md"
MISSING_FILE_TRANSCRIPT_BRANCH=$(git -C "$MISSING_FILE_TRANSCRIPT_REPO" rev-parse --abbrev-ref HEAD)
MISSING_FILE_TRANSCRIPT_BASE_COMMIT=$(git -C "$MISSING_FILE_TRANSCRIPT_REPO" rev-parse HEAD)
cat > "$MISSING_FILE_TRANSCRIPT_STATE" <<EOF_MISSING_FILE_TRANSCRIPT
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.5
codex_effort: high
codex_timeout: 60
push_every_round: false
full_review_round: 5
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $MISSING_FILE_TRANSCRIPT_BRANCH
base_branch: $MISSING_FILE_TRANSCRIPT_BRANCH
base_commit: $MISSING_FILE_TRANSCRIPT_BASE_COMMIT
review_started: false
ask_codex_question: false
agent_teams: false
session_id: session_foreign
---
EOF_MISSING_FILE_TRANSCRIPT
: > "$MISSING_FILE_TRANSCRIPT_LOOP/bg-pending.marker"

MISSING_FILE_TRANSCRIPT_INPUT=$(jq -c -n --arg tp "$TRANSCRIPTS_DIR/never-written.jsonl" \
    '{transcript_path:$tp, session_id:"session_home"}')
run_stop_hook_with_input "$MISSING_FILE_TRANSCRIPT_REPO" "$MISSING_FILE_TRANSCRIPT_INPUT"

if [[ -f "$MISSING_FILE_TRANSCRIPT_LOOP/bg-pending.marker" ]] \
   && grep -q "^session_id: session_foreign$" "$MISSING_FILE_TRANSCRIPT_STATE"; then
    pass "missing-file transcript_path preserves marker and session_id"
else
    fail "missing-file transcript_path preserves marker and session_id" \
        "marker present and session_id: session_foreign" \
        "marker=$(test -f "$MISSING_FILE_TRANSCRIPT_LOOP/bg-pending.marker" && echo present || echo missing); session_id=$(grep '^session_id:' "$MISSING_FILE_TRANSCRIPT_STATE" || echo '(missing)')"
fi

# ---------------- find_active_loop ignores foreign marker ----------------
# Validator isolation: find_active_loop's marker-based adoption is opt-in
# via its third positional argument. Default callers (read/write/bash/etc.
# validators) must continue to see strict session-id isolation; a parked
# loop for a different session must NOT become visible to them through a
# bg-pending.marker.
echo "Test: find_active_loop default invocation ignores foreign marker"
FIND_LOOP_IGNORES_FOREIGN_MARKER_BASE="$TEST_DIR/find_loop_ignores_foreign_marker-loops"
mkdir -p "$FIND_LOOP_IGNORES_FOREIGN_MARKER_BASE/2026-03-02_00-00-00"
cat > "$FIND_LOOP_IGNORES_FOREIGN_MARKER_BASE/2026-03-02_00-00-00/state.md" <<'EOF_FIND_LOOP_IGNORES_FOREIGN_MARKER'
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.5
codex_effort: high
session_id: session_foreign
---
EOF_FIND_LOOP_IGNORES_FOREIGN_MARKER
: > "$FIND_LOOP_IGNORES_FOREIGN_MARKER_BASE/2026-03-02_00-00-00/bg-pending.marker"

FIND_LOOP_IGNORES_FOREIGN_MARKER_DEFAULT=$(
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    find_active_loop "$FIND_LOOP_IGNORES_FOREIGN_MARKER_BASE" "session_home"
)
if [[ -z "$FIND_LOOP_IGNORES_FOREIGN_MARKER_DEFAULT" ]]; then
    pass "find_active_loop default (no opt-in) ignores foreign marker dir"
else
    fail "find_active_loop default (no opt-in) ignores foreign marker dir" \
        "empty result (validators stay isolated)" "got: $FIND_LOOP_IGNORES_FOREIGN_MARKER_DEFAULT"
fi

FIND_LOOP_IGNORES_FOREIGN_MARKER_OPTIN=$(
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    find_active_loop "$FIND_LOOP_IGNORES_FOREIGN_MARKER_BASE" "session_home" true
)
if [[ "$FIND_LOOP_IGNORES_FOREIGN_MARKER_OPTIN" == "$FIND_LOOP_IGNORES_FOREIGN_MARKER_BASE/2026-03-02_00-00-00" ]]; then
    pass "find_active_loop with opt-in does return the marker dir"
else
    fail "find_active_loop with opt-in does return the marker dir" \
        "$FIND_LOOP_IGNORES_FOREIGN_MARKER_BASE/2026-03-02_00-00-00" "$FIND_LOOP_IGNORES_FOREIGN_MARKER_OPTIN"
fi

# ---------------- ambiguous caller exits silently ----------------
# Empty-session caller + bg-pending.marker present: the caller might be
# the parked loop's owner invoking through a wrapper that didn't forward
# session_id, OR it might be a different session. The hook cannot tell
# them apart from the input, so the safe response is `exit 0` silently
# with no systemMessage and no on-disk mutation. The real Claude stop
# hook (which always has session_id populated) drives actual parking and
# cleanup.
echo "Test: ambiguous caller (empty session_id + marker) exits silently"
AMBIGUOUS_CALLER_REPO="$TEST_DIR/ambiguous_caller"
AMBIGUOUS_CALLER_LOOP=$(create_full_fixture "$AMBIGUOUS_CALLER_REPO")
AMBIGUOUS_CALLER_STATE="$AMBIGUOUS_CALLER_LOOP/state.md"
AMBIGUOUS_CALLER_MARKER="$AMBIGUOUS_CALLER_LOOP/bg-pending.marker"
AMBIGUOUS_CALLER_BRANCH=$(git -C "$AMBIGUOUS_CALLER_REPO" rev-parse --abbrev-ref HEAD)
AMBIGUOUS_CALLER_BASE_COMMIT=$(git -C "$AMBIGUOUS_CALLER_REPO" rev-parse HEAD)
cat > "$AMBIGUOUS_CALLER_STATE" <<EOF_AMBIGUOUS_CALLER
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.5
codex_effort: high
codex_timeout: 60
push_every_round: false
full_review_round: 5
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $AMBIGUOUS_CALLER_BRANCH
base_branch: $AMBIGUOUS_CALLER_BRANCH
base_commit: $AMBIGUOUS_CALLER_BASE_COMMIT
review_started: false
ask_codex_question: false
agent_teams: false
session_id: session_alpha
---
EOF_AMBIGUOUS_CALLER
AMBIGUOUS_CALLER_STATE_HASH_BEFORE=$(sha256sum "$AMBIGUOUS_CALLER_STATE" | awk '{print $1}')
: > "$AMBIGUOUS_CALLER_MARKER"

AMBIGUOUS_CALLER_TRANSCRIPT="$TRANSCRIPTS_DIR/ambiguous_caller.jsonl"
write_transcript "$AMBIGUOUS_CALLER_TRANSCRIPT" '{"type":"user","message":{"role":"user","content":"hello"}}'

# Hook input without any session_id key (mirrors rlcr-stop-gate.sh
# invoked without --session-id).
AMBIGUOUS_CALLER_INPUT=$(jq -c -n --arg tp "$AMBIGUOUS_CALLER_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$AMBIGUOUS_CALLER_REPO" "$AMBIGUOUS_CALLER_INPUT"
AMBIGUOUS_CALLER_SYS_MSG=$(printf '%s' "$RUN_OUTPUT" | jq -r '.systemMessage // empty' 2>/dev/null || echo "")
AMBIGUOUS_CALLER_STATE_HASH_AFTER=$(sha256sum "$AMBIGUOUS_CALLER_STATE" | awk '{print $1}')
if [[ "$RUN_EXIT_CODE" -eq 0 ]] \
   && [[ ! -f "$RUN_MARKER" ]] \
   && [[ -f "$AMBIGUOUS_CALLER_MARKER" ]] \
   && [[ "$AMBIGUOUS_CALLER_STATE_HASH_BEFORE" == "$AMBIGUOUS_CALLER_STATE_HASH_AFTER" ]] \
   && [[ -z "$AMBIGUOUS_CALLER_SYS_MSG" ]]; then
    pass "ambiguous caller exits silently; marker and state.md preserved"
else
    fail "ambiguous caller exits silently; marker and state.md preserved" \
        "exit 0 + no systemMessage + marker stays + state.md byte-identical + no Codex" \
        "exit $RUN_EXIT_CODE, codex_marker=$(test -f "$RUN_MARKER" && echo present || echo missing), bg_marker=$(test -f "$AMBIGUOUS_CALLER_MARKER" && echo present || echo missing), state_unchanged=$([[ "$AMBIGUOUS_CALLER_STATE_HASH_BEFORE" == "$AMBIGUOUS_CALLER_STATE_HASH_AFTER" ]] && echo yes || echo no), systemMessage='$AMBIGUOUS_CALLER_SYS_MSG'; output: $RUN_OUTPUT"
fi

# ---------------- malformed transcript with marker ----------------
# Non-short-circuit cleanup must not drop bg-pending.marker when the
# transcript exists but cannot be parsed. The helper is fail-closed on
# malformed JSON; that failure must NOT be treated as "no pending".
echo "Test: malformed transcript preserves bg-pending.marker"
MALFORMED_TRANSCRIPT_REPO="$TEST_DIR/malformed_transcript"
MALFORMED_TRANSCRIPT_LOOP=$(create_full_fixture "$MALFORMED_TRANSCRIPT_REPO")
MALFORMED_TRANSCRIPT_STATE="$MALFORMED_TRANSCRIPT_LOOP/state.md"
MALFORMED_TRANSCRIPT_MARKER="$MALFORMED_TRANSCRIPT_LOOP/bg-pending.marker"
MALFORMED_TRANSCRIPT_BRANCH=$(git -C "$MALFORMED_TRANSCRIPT_REPO" rev-parse --abbrev-ref HEAD)
MALFORMED_TRANSCRIPT_BASE_COMMIT=$(git -C "$MALFORMED_TRANSCRIPT_REPO" rev-parse HEAD)
cat > "$MALFORMED_TRANSCRIPT_STATE" <<EOF_MALFORMED_TRANSCRIPT
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.5
codex_effort: high
codex_timeout: 60
push_every_round: false
full_review_round: 5
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $MALFORMED_TRANSCRIPT_BRANCH
base_branch: $MALFORMED_TRANSCRIPT_BRANCH
base_commit: $MALFORMED_TRANSCRIPT_BASE_COMMIT
review_started: false
ask_codex_question: false
agent_teams: false
session_id: session_home
---
EOF_MALFORMED_TRANSCRIPT
: > "$MALFORMED_TRANSCRIPT_MARKER"

# Write a deliberately malformed transcript (truncated JSON object) so
# list_pending_background_task_ids's jq invocations fail the parse.
MALFORMED_TRANSCRIPT_TRANSCRIPT="$TRANSCRIPTS_DIR/malformed_transcript.jsonl"
printf '%s\n' '{"type":"user","message":' > "$MALFORMED_TRANSCRIPT_TRANSCRIPT"

MALFORMED_TRANSCRIPT_INPUT=$(jq -c -n --arg tp "$MALFORMED_TRANSCRIPT_TRANSCRIPT" \
    '{transcript_path:$tp, session_id:"session_home"}')
run_stop_hook_with_input "$MALFORMED_TRANSCRIPT_REPO" "$MALFORMED_TRANSCRIPT_INPUT"

if [[ -f "$MALFORMED_TRANSCRIPT_MARKER" ]]; then
    pass "malformed transcript preserves bg-pending.marker"
else
    fail "malformed transcript preserves bg-pending.marker" \
        "marker still present (cleanup must not fire on fail-closed helper)" \
        "marker was removed"
fi

# ---------------- pre-loop launches filtered by since_ts ----------------
# Transcript scan boundary: the Claude transcript is session-wide and
# can contain background launches that predate the RLCR loop. The
# helper filters launch events by `.timestamp >= since_ts` (derived
# from the loop dir basename) so only launches made after the loop
# started count as pending.
echo "Test: pre-loop launches are filtered out by since_ts"
PRE_LOOP_FILTERED_TRANSCRIPT="$TRANSCRIPTS_DIR/pre_loop_filtered.jsonl"

# The loop boundary used throughout the suite's fixtures is
# 2026-03-01 00:00:00. Build two launches: one BEFORE that boundary
# (should be filtered) and one AFTER (should still count as pending).
PRE_LOOP_FILTERED_PRE_LAUNCH=$(jq -c -n '{
    type:"user",
    timestamp:"2026-02-28T10:00:00.000Z",
    toolUseResult:{isAsync:true, agentId:"agent_pre_loop"}
}')
PRE_LOOP_FILTERED_POST_LAUNCH=$(jq -c -n '{
    type:"user",
    timestamp:"2026-03-01T10:00:00.000Z",
    toolUseResult:{isAsync:true, agentId:"agent_in_loop"}
}')
write_transcript "$PRE_LOOP_FILTERED_TRANSCRIPT" "$PRE_LOOP_FILTERED_PRE_LAUNCH" "$PRE_LOOP_FILTERED_POST_LAUNCH"

PRE_LOOP_FILTERED_SINCE="2026-03-01T00:00:00.000Z"
PRE_LOOP_FILTERED_FILTERED=$(
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    list_pending_background_task_ids "$PRE_LOOP_FILTERED_TRANSCRIPT" "$PRE_LOOP_FILTERED_SINCE" 2>/dev/null | sort -u
)
if [[ "$PRE_LOOP_FILTERED_FILTERED" == "agent_in_loop" ]]; then
    pass "list_pending_background_task_ids filters launches before since_ts"
else
    fail "list_pending_background_task_ids filters launches before since_ts" \
        "only 'agent_in_loop' (pre-loop launch excluded)" "got: $PRE_LOOP_FILTERED_FILTERED"
fi

# confirm the derive helper produces the expected ISO-8601 form
# under TZ=UTC, where local wall clock == UTC so no offset is applied.
DERIVE_LOOP_START_ISO_DERIVED=$(
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    export TZ="UTC"
    derive_loop_start_iso_ts "/tmp/.humanize/rlcr/2026-03-01_00-00-00"
)
if [[ "$DERIVE_LOOP_START_ISO_DERIVED" == "2026-03-01T00:00:00.000Z" ]]; then
    pass "derive_loop_start_iso_ts under TZ=UTC preserves the wall-clock"
else
    fail "derive_loop_start_iso_ts under TZ=UTC preserves the wall-clock" \
        "2026-03-01T00:00:00.000Z" "$DERIVE_LOOP_START_ISO_DERIVED"
fi

# setup-rlcr-loop.sh names the dir with local wall clock, so a
# non-UTC caller must see the boundary shifted into actual UTC.
# JST (UTC+9) example: 09:00 JST == 00:00 UTC.
JST_TO_UTC_DERIVED=$(
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    export TZ="Asia/Tokyo"
    derive_loop_start_iso_ts "/tmp/.humanize/rlcr/2026-03-01_09-00-00"
)
if [[ "$JST_TO_UTC_DERIVED" == "2026-03-01T00:00:00.000Z" ]]; then
    pass "derive_loop_start_iso_ts converts JST wall-clock to correct UTC"
else
    fail "derive_loop_start_iso_ts converts JST wall-clock to correct UTC" \
        "2026-03-01T00:00:00.000Z (9am JST = 0am UTC)" "$JST_TO_UTC_DERIVED"
fi

# PST (UTC-8) example. Pick March 1 which is still PST (DST
# does not start until March 8, 2026), so the offset is a fixed -8h:
# 00:00 PST == 08:00 UTC.
PST_TO_UTC_DERIVED=$(
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    export TZ="America/Los_Angeles"
    derive_loop_start_iso_ts "/tmp/.humanize/rlcr/2026-03-01_00-00-00"
)
if [[ "$PST_TO_UTC_DERIVED" == "2026-03-01T08:00:00.000Z" ]]; then
    pass "derive_loop_start_iso_ts converts PST wall-clock to correct UTC"
else
    fail "derive_loop_start_iso_ts converts PST wall-clock to correct UTC" \
        "2026-03-01T08:00:00.000Z (0am PST = 8am UTC before DST)" "$PST_TO_UTC_DERIVED"
fi

# end-to-end through the stop hook. Pre-loop launch only -> hook
# must NOT short-circuit (no pending bg "belongs" to this loop).
echo "Test: stop hook ignores pre-loop launches for this loop"
PRE_LOOP_STOP_HOOK_REPO="$TEST_DIR/pre_loop_stop_hook"
PRE_LOOP_STOP_HOOK_LOOP=$(create_full_fixture "$PRE_LOOP_STOP_HOOK_REPO")
PRE_LOOP_STOP_HOOK_MARKER="$PRE_LOOP_STOP_HOOK_LOOP/bg-pending.marker"
PRE_LOOP_STOP_HOOK_TRANSCRIPT="$TRANSCRIPTS_DIR/pre_loop_stop_hook.jsonl"
write_transcript "$PRE_LOOP_STOP_HOOK_TRANSCRIPT" "$PRE_LOOP_FILTERED_PRE_LAUNCH"
PRE_LOOP_STOP_HOOK_INPUT=$(jq -c -n --arg tp "$PRE_LOOP_STOP_HOOK_TRANSCRIPT" \
    '{transcript_path:$tp, session_id:"session_home"}')
run_stop_hook_with_input "$PRE_LOOP_STOP_HOOK_REPO" "$PRE_LOOP_STOP_HOOK_INPUT"

# With the pre-loop launch filtered out, the transcript has no in-loop
# pending bg -> no short-circuit -> no marker written -> hook proceeds
# to the normal flow (which will call Codex in this fixture).
if [[ ! -f "$PRE_LOOP_STOP_HOOK_MARKER" ]] && [[ -f "$RUN_MARKER" ]]; then
    pass "pre-loop launch does not write bg-pending.marker; Codex runs"
else
    fail "pre-loop launch does not write bg-pending.marker; Codex runs" \
        "no bg marker AND Codex invoked" \
        "bg_marker=$(test -f "$PRE_LOOP_STOP_HOOK_MARKER" && echo present || echo missing); codex_marker=$(test -f "$RUN_MARKER" && echo present || echo missing)"
fi

# ---------------- wrapper without session_id, pending bg ----------------
# Wrapper without --session-id on a repo that has NO marker: should
# behave just like the normal same-session path, i.e. a pending bg in
# the transcript writes the marker and the wrapper output surfaces the
# "background task" systemMessage. This confirms the ambiguous-caller
# guard only fires on a pre-existing marker, not on every no-session
# call.
echo "Test: wrapper without session_id, no prior marker, pending bg -> ALLOW with systemMessage"
WRAPPER_NO_SESSION_PENDING_REPO="$TEST_DIR/wrapper_no_session_pending"
create_full_fixture "$WRAPPER_NO_SESSION_PENDING_REPO" > /dev/null
WRAPPER_NO_SESSION_PENDING_LOOP="$WRAPPER_NO_SESSION_PENDING_REPO/.humanize/rlcr/2026-03-01_00-00-00"
WRAPPER_NO_SESSION_PENDING_MARKER="$WRAPPER_NO_SESSION_PENDING_LOOP/bg-pending.marker"
WRAPPER_NO_SESSION_PENDING_TRANSCRIPT="$TRANSCRIPTS_DIR/wrapper_no_session_pending.jsonl"
WRAPPER_NO_SESSION_PENDING_LAUNCH=$(jq -c -n '{
    type:"user",
    timestamp:"2026-03-01T10:00:00.000Z",
    toolUseResult:{isAsync:true, agentId:"agent_wrapper_pending"}
}')
write_transcript "$WRAPPER_NO_SESSION_PENDING_TRANSCRIPT" "$WRAPPER_NO_SESSION_PENDING_LAUNCH"

WRAPPER_NO_SESSION_PENDING_OUT="$TEST_DIR/wrapper_no_session_pending-out.txt"
set +e
(
    cd "$WRAPPER_NO_SESSION_PENDING_REPO"
    "$GATE_SCRIPT" --project-root "$WRAPPER_NO_SESSION_PENDING_REPO" --transcript-path "$WRAPPER_NO_SESSION_PENDING_TRANSCRIPT"
) > "$WRAPPER_NO_SESSION_PENDING_OUT" 2>&1
WRAPPER_NO_SESSION_PENDING_EXIT=$?
set -e

if [[ "$WRAPPER_NO_SESSION_PENDING_EXIT" -eq 0 ]] \
   && grep -q "^ALLOW:" "$WRAPPER_NO_SESSION_PENDING_OUT" \
   && grep -q "background task" "$WRAPPER_NO_SESSION_PENDING_OUT" \
   && [[ -f "$WRAPPER_NO_SESSION_PENDING_MARKER" ]]; then
    pass "wrapper without session_id + no prior marker + pending bg -> writes marker, surfaces systemMessage"
else
    WRAPPER_NO_SESSION_PENDING_BODY=$(cat "$WRAPPER_NO_SESSION_PENDING_OUT" 2>/dev/null || true)
    fail "wrapper without session_id + no prior marker + pending bg -> writes marker, surfaces systemMessage" \
        "exit 0 + ALLOW + 'background task' + marker written" \
        "exit $WRAPPER_NO_SESSION_PENDING_EXIT; marker=$(test -f "$WRAPPER_NO_SESSION_PENDING_MARKER" && echo present || echo missing); output: $WRAPPER_NO_SESSION_PENDING_BODY"
fi

# wrapper without --session-id on a repo that ALREADY has a
# marker (e.g. set up by a prior hook call). Must exit 0 silently -- no
# systemMessage, no state mutation. Mirrors the real scenario Codex
# flagged: rlcr-stop-gate.sh re-run by an unaware caller.
echo "Test: wrapper without session_id, prior marker -> silent ALLOW"
WRAPPER_NO_SESSION_PRIOR_MARKER_REPO="$TEST_DIR/wrapper_no_session_prior_marker"
WRAPPER_NO_SESSION_PRIOR_MARKER_LOOP=$(create_full_fixture "$WRAPPER_NO_SESSION_PRIOR_MARKER_REPO")
WRAPPER_NO_SESSION_PRIOR_MARKER_STATE="$WRAPPER_NO_SESSION_PRIOR_MARKER_LOOP/state.md"
WRAPPER_NO_SESSION_PRIOR_MARKER_MARKER="$WRAPPER_NO_SESSION_PRIOR_MARKER_LOOP/bg-pending.marker"
WRAPPER_NO_SESSION_PRIOR_MARKER_BRANCH=$(git -C "$WRAPPER_NO_SESSION_PRIOR_MARKER_REPO" rev-parse --abbrev-ref HEAD)
WRAPPER_NO_SESSION_PRIOR_MARKER_BASE_COMMIT=$(git -C "$WRAPPER_NO_SESSION_PRIOR_MARKER_REPO" rev-parse HEAD)
cat > "$WRAPPER_NO_SESSION_PRIOR_MARKER_STATE" <<EOF_WRAPPER_NO_SESSION_PRIOR_MARKER
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.5
codex_effort: high
codex_timeout: 60
push_every_round: false
full_review_round: 5
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $WRAPPER_NO_SESSION_PRIOR_MARKER_BRANCH
base_branch: $WRAPPER_NO_SESSION_PRIOR_MARKER_BRANCH
base_commit: $WRAPPER_NO_SESSION_PRIOR_MARKER_BASE_COMMIT
review_started: false
ask_codex_question: false
agent_teams: false
session_id: session_alpha
---
EOF_WRAPPER_NO_SESSION_PRIOR_MARKER
WRAPPER_NO_SESSION_PRIOR_MARKER_STATE_HASH_BEFORE=$(sha256sum "$WRAPPER_NO_SESSION_PRIOR_MARKER_STATE" | awk '{print $1}')
: > "$WRAPPER_NO_SESSION_PRIOR_MARKER_MARKER"

WRAPPER_NO_SESSION_PRIOR_MARKER_OUT="$TEST_DIR/wrapper_no_session_prior_marker-out.txt"
set +e
(
    cd "$WRAPPER_NO_SESSION_PRIOR_MARKER_REPO"
    "$GATE_SCRIPT" --project-root "$WRAPPER_NO_SESSION_PRIOR_MARKER_REPO"
) > "$WRAPPER_NO_SESSION_PRIOR_MARKER_OUT" 2>&1
WRAPPER_NO_SESSION_PRIOR_MARKER_EXIT=$?
set -e

WRAPPER_NO_SESSION_PRIOR_MARKER_STATE_HASH_AFTER=$(sha256sum "$WRAPPER_NO_SESSION_PRIOR_MARKER_STATE" | awk '{print $1}')
if [[ "$WRAPPER_NO_SESSION_PRIOR_MARKER_EXIT" -eq 0 ]] \
   && grep -q "^ALLOW:" "$WRAPPER_NO_SESSION_PRIOR_MARKER_OUT" \
   && ! grep -qi "parked" "$WRAPPER_NO_SESSION_PRIOR_MARKER_OUT" \
   && [[ -f "$WRAPPER_NO_SESSION_PRIOR_MARKER_MARKER" ]] \
   && [[ "$WRAPPER_NO_SESSION_PRIOR_MARKER_STATE_HASH_BEFORE" == "$WRAPPER_NO_SESSION_PRIOR_MARKER_STATE_HASH_AFTER" ]]; then
    pass "wrapper without session_id + existing marker -> silent ALLOW; marker and state preserved"
else
    WRAPPER_NO_SESSION_PRIOR_MARKER_BODY=$(cat "$WRAPPER_NO_SESSION_PRIOR_MARKER_OUT" 2>/dev/null || true)
    fail "wrapper without session_id + existing marker -> silent ALLOW; marker and state preserved" \
        "exit 0 + ALLOW: (no 'parked') + marker kept + state.md byte-identical" \
        "exit $WRAPPER_NO_SESSION_PRIOR_MARKER_EXIT; marker=$(test -f "$WRAPPER_NO_SESSION_PRIOR_MARKER_MARKER" && echo present || echo missing); state_unchanged=$([[ "$WRAPPER_NO_SESSION_PRIOR_MARKER_STATE_HASH_BEFORE" == "$WRAPPER_NO_SESSION_PRIOR_MARKER_STATE_HASH_AFTER" ]] && echo yes || echo no); output: $WRAPPER_NO_SESSION_PRIOR_MARKER_BODY"
fi

# ---------------- alive task still short-circuits ----------------
# Liveness probe positive: a pending task whose output file is open by at
# least one process (lsof exits 0) must still be treated as running.
# The short-circuit must fire and emit a systemMessage.
echo "Test: liveness probe - alive task (lsof has holder) -> still short-circuits"
ALIVE_TASK_SHORT_CIRCUITS_REPO="$TEST_DIR/alive_task_short_circuits"
ALIVE_TASK_SHORT_CIRCUITS_LOOP=$(create_full_fixture "$ALIVE_TASK_SHORT_CIRCUITS_REPO")
ALIVE_TASK_SHORT_CIRCUITS_STATE="$ALIVE_TASK_SHORT_CIRCUITS_LOOP/state.md"
ALIVE_TASK_SHORT_CIRCUITS_TRANSCRIPT="$TRANSCRIPTS_DIR/alive_task_short_circuits.jsonl"
ALIVE_TASK_SHORT_CIRCUITS_TASK_ID="agent_probe_alive"
ALIVE_TASK_SHORT_CIRCUITS_LAUNCH=$(emit_tool_use_assistant "toolu_ALIVE_TASK_SHORT_CIRCUITS" "Agent" ',"description":"x","prompt":"x"')
ALIVE_TASK_SHORT_CIRCUITS_RESULT=$(emit_async_agent_launch_result "toolu_ALIVE_TASK_SHORT_CIRCUITS" "$ALIVE_TASK_SHORT_CIRCUITS_TASK_ID")
write_transcript "$ALIVE_TASK_SHORT_CIRCUITS_TRANSCRIPT" "$ALIVE_TASK_SHORT_CIRCUITS_LAUNCH" "$ALIVE_TASK_SHORT_CIRCUITS_RESULT"

ALIVE_TASK_SHORT_CIRCUITS_UID=$(id -u)
ALIVE_TASK_SHORT_CIRCUITS_SLUG=$(basename "$TRANSCRIPTS_DIR")
ALIVE_TASK_SHORT_CIRCUITS_TASKS_DIR="/tmp/claude-${ALIVE_TASK_SHORT_CIRCUITS_UID}/${ALIVE_TASK_SHORT_CIRCUITS_SLUG}/alive_task_short_circuits/tasks"
mkdir -p "$ALIVE_TASK_SHORT_CIRCUITS_TASKS_DIR"
touch "$ALIVE_TASK_SHORT_CIRCUITS_TASKS_DIR/${ALIVE_TASK_SHORT_CIRCUITS_TASK_ID}.output"

ALIVE_TASK_SHORT_CIRCUITS_INPUT=$(jq -c -n --arg tp "$ALIVE_TASK_SHORT_CIRCUITS_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$ALIVE_TASK_SHORT_CIRCUITS_REPO" "$ALIVE_TASK_SHORT_CIRCUITS_INPUT" "" "$TEST_DIR/bin/lsof-alive"
rm -rf "/tmp/claude-${ALIVE_TASK_SHORT_CIRCUITS_UID}/${ALIVE_TASK_SHORT_CIRCUITS_SLUG}/alive_task_short_circuits" 2>/dev/null || true
assert_systemmessage_only \
    "alive task (lsof has holder) still triggers short-circuit" \
    "$ALIVE_TASK_SHORT_CIRCUITS_REPO" "$ALIVE_TASK_SHORT_CIRCUITS_STATE" "1 background task"

# ---------------- dead/orphaned task pruned ----------------
# Liveness probe negative: a pending task whose output file has no open
# file descriptors (lsof exits 1) was killed without a completion event.
# The probe must drop it so the hook proceeds to normal Codex review.
echo "Test: liveness probe - dead/orphaned task (lsof no holder) -> reaches Codex"
DEAD_TASK_PRUNED_REPO="$TEST_DIR/dead_task_pruned"
create_full_fixture "$DEAD_TASK_PRUNED_REPO" > /dev/null
DEAD_TASK_PRUNED_TRANSCRIPT="$TRANSCRIPTS_DIR/dead_task_pruned.jsonl"
DEAD_TASK_PRUNED_TASK_ID="agent_probe_dead"
DEAD_TASK_PRUNED_LAUNCH=$(emit_tool_use_assistant "toolu_DEAD_TASK_PRUNED" "Agent" ',"description":"x","prompt":"x"')
DEAD_TASK_PRUNED_RESULT=$(emit_async_agent_launch_result "toolu_DEAD_TASK_PRUNED" "$DEAD_TASK_PRUNED_TASK_ID")
write_transcript "$DEAD_TASK_PRUNED_TRANSCRIPT" "$DEAD_TASK_PRUNED_LAUNCH" "$DEAD_TASK_PRUNED_RESULT"

DEAD_TASK_PRUNED_UID=$(id -u)
DEAD_TASK_PRUNED_SLUG=$(basename "$TRANSCRIPTS_DIR")
DEAD_TASK_PRUNED_TASKS_DIR="/tmp/claude-${DEAD_TASK_PRUNED_UID}/${DEAD_TASK_PRUNED_SLUG}/dead_task_pruned/tasks"
mkdir -p "$DEAD_TASK_PRUNED_TASKS_DIR"
touch "$DEAD_TASK_PRUNED_TASKS_DIR/${DEAD_TASK_PRUNED_TASK_ID}.output"

DEAD_TASK_PRUNED_INPUT=$(jq -c -n --arg tp "$DEAD_TASK_PRUNED_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$DEAD_TASK_PRUNED_REPO" "$DEAD_TASK_PRUNED_INPUT" "" "$TEST_DIR/bin/lsof-dead"
rm -rf "/tmp/claude-${DEAD_TASK_PRUNED_UID}/${DEAD_TASK_PRUNED_SLUG}/dead_task_pruned" 2>/dev/null || true
assert_reached_codex "dead/orphaned task (lsof no holder) is pruned; Codex review runs"

# ---------------- session-resume real output path ----------------
# Session resume regression: when Claude resumes a session, the current
# transcript file has a NEW session id, but background tasks launched
# earlier physically wrote their .output files under the OLD session
# directory. The transcript launch message records the real path. The
# liveness probe must look at that real path, not at a path derived
# from the current transcript's session id, or orphaned dead tasks are
# never pruned.
echo "Test: liveness probe follows real output path from transcript on session resume"
SESSION_RESUME_REAL_PATH_REPO="$TEST_DIR/session_resume_real_path"
create_full_fixture "$SESSION_RESUME_REAL_PATH_REPO" > /dev/null
SESSION_RESUME_REAL_PATH_UID=$(id -u)
SESSION_RESUME_REAL_PATH_SLUG=$(basename "$TRANSCRIPTS_DIR")
SESSION_RESUME_REAL_PATH_OLD_SESSION="aaaaaaaa-1111-2222-3333-444444444444"
SESSION_RESUME_REAL_PATH_NEW_SESSION="bbbbbbbb-5555-6666-7777-888888888888"
SESSION_RESUME_REAL_PATH_TASK_ID="shell_resumed_session"
SESSION_RESUME_REAL_PATH_REAL_OUTPUT="/tmp/claude-${SESSION_RESUME_REAL_PATH_UID}/${SESSION_RESUME_REAL_PATH_SLUG}/${SESSION_RESUME_REAL_PATH_OLD_SESSION}/tasks/${SESSION_RESUME_REAL_PATH_TASK_ID}.output"

# Build the launch event with the real (old-session) output path embedded
# in the Claude Code launch message.
SESSION_RESUME_REAL_PATH_LAUNCH=$(emit_tool_use_assistant "toolu_SESSION_RESUME_REAL_PATH" "Bash" ',"command":"sleep 30"')
SESSION_RESUME_REAL_PATH_RESULT=$(emit_bg_shell_launch_result_with_output_path "toolu_SESSION_RESUME_REAL_PATH" "$SESSION_RESUME_REAL_PATH_TASK_ID" "$SESSION_RESUME_REAL_PATH_REAL_OUTPUT")

# Write the transcript under the NEW session id (resume session).
SESSION_RESUME_REAL_PATH_TRANSCRIPT="/tmp/claude-${SESSION_RESUME_REAL_PATH_UID}/${SESSION_RESUME_REAL_PATH_SLUG}/${SESSION_RESUME_REAL_PATH_NEW_SESSION}.jsonl"
write_transcript "$SESSION_RESUME_REAL_PATH_TRANSCRIPT" "$SESSION_RESUME_REAL_PATH_LAUNCH" "$SESSION_RESUME_REAL_PATH_RESULT"

# The real output file lives in the OLD session directory.
mkdir -p "$(dirname "$SESSION_RESUME_REAL_PATH_REAL_OUTPUT")"
touch "$SESSION_RESUME_REAL_PATH_REAL_OUTPUT"

SESSION_RESUME_REAL_PATH_INPUT=$(jq -c -n --arg tp "$SESSION_RESUME_REAL_PATH_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$SESSION_RESUME_REAL_PATH_REPO" "$SESSION_RESUME_REAL_PATH_INPUT" "" "$TEST_DIR/bin/lsof-dead"
rm -rf "/tmp/claude-${SESSION_RESUME_REAL_PATH_UID}/${SESSION_RESUME_REAL_PATH_SLUG}/${SESSION_RESUME_REAL_PATH_OLD_SESSION}" \
       "/tmp/claude-${SESSION_RESUME_REAL_PATH_UID}/${SESSION_RESUME_REAL_PATH_SLUG}/${SESSION_RESUME_REAL_PATH_NEW_SESSION}.jsonl" 2>/dev/null || true
assert_reached_codex "dead task pruned using real output path from transcript, not derived new-session path"

# ---------------- whitespace in recorded output path ----------------
# Same as session-resume real output path, but the recorded output path contains a space. The
# regex used to extract the path must not stop at the first whitespace
# token, or it will fall back to the derived new-session path and the
# dead task will never be pruned.
echo "Test: liveness probe handles whitespace in recorded output path"
WHITESPACE_OUTPUT_PATH_REPO="$TEST_DIR/whitespace_output_path"
create_full_fixture "$WHITESPACE_OUTPUT_PATH_REPO" > /dev/null
WHITESPACE_OUTPUT_PATH_UID=$(id -u)
WHITESPACE_OUTPUT_PATH_SLUG=$(basename "$TRANSCRIPTS_DIR")
WHITESPACE_OUTPUT_PATH_OLD_SESSION="aaaaaaaa-1111-2222-3333-444444444444"
WHITESPACE_OUTPUT_PATH_NEW_SESSION="bbbbbbbb-5555-6666-7777-888888888888"
WHITESPACE_OUTPUT_PATH_TASK_ID="shell_resumed_session_space"
WHITESPACE_OUTPUT_PATH_REAL_OUTPUT="/tmp/claude-${WHITESPACE_OUTPUT_PATH_UID}/${WHITESPACE_OUTPUT_PATH_SLUG}/${WHITESPACE_OUTPUT_PATH_OLD_SESSION}/tasks/with space/${WHITESPACE_OUTPUT_PATH_TASK_ID}.output"

WHITESPACE_OUTPUT_PATH_LAUNCH=$(emit_tool_use_assistant "toolu_WHITESPACE_OUTPUT_PATH" "Bash" ',"command":"sleep 30"')
WHITESPACE_OUTPUT_PATH_RESULT=$(emit_bg_shell_launch_result_with_output_path "toolu_WHITESPACE_OUTPUT_PATH" "$WHITESPACE_OUTPUT_PATH_TASK_ID" "$WHITESPACE_OUTPUT_PATH_REAL_OUTPUT")

WHITESPACE_OUTPUT_PATH_TRANSCRIPT="/tmp/claude-${WHITESPACE_OUTPUT_PATH_UID}/${WHITESPACE_OUTPUT_PATH_SLUG}/${WHITESPACE_OUTPUT_PATH_NEW_SESSION}.jsonl"
write_transcript "$WHITESPACE_OUTPUT_PATH_TRANSCRIPT" "$WHITESPACE_OUTPUT_PATH_LAUNCH" "$WHITESPACE_OUTPUT_PATH_RESULT"

mkdir -p "$(dirname "$WHITESPACE_OUTPUT_PATH_REAL_OUTPUT")"
touch "$WHITESPACE_OUTPUT_PATH_REAL_OUTPUT"

WHITESPACE_OUTPUT_PATH_INPUT=$(jq -c -n --arg tp "$WHITESPACE_OUTPUT_PATH_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$WHITESPACE_OUTPUT_PATH_REPO" "$WHITESPACE_OUTPUT_PATH_INPUT" "" "$TEST_DIR/bin/lsof-dead"
rm -rf "/tmp/claude-${WHITESPACE_OUTPUT_PATH_UID}/${WHITESPACE_OUTPUT_PATH_SLUG}/${WHITESPACE_OUTPUT_PATH_OLD_SESSION}" \
       "/tmp/claude-${WHITESPACE_OUTPUT_PATH_UID}/${WHITESPACE_OUTPUT_PATH_SLUG}/${WHITESPACE_OUTPUT_PATH_NEW_SESSION}.jsonl" 2>/dev/null || true
assert_reached_codex "dead task pruned when real output path contains whitespace"

# ---- TaskStop tool_result: task recognised completed (end-to-end) ----
# TaskStop recognition: when a background task is stopped via the TaskStop
# tool, Claude Code records a top-level .toolUseResult whose .message is
# "Successfully stopped task: <id>". Many builds do NOT also emit a
# task_notification system event for a TaskStop, so the helper must treat
# this record as terminal or the stopped task pins the loop forever. This
# is the exact regression observed in a real resumed session where a
# stopped shell kept the RLCR loop reporting "1 background task still
# running" minutes after the stop.
echo "Test: TaskStop tool_result marks the task completed -> reaches Codex"
TASKSTOP_E2E_REPO="$TEST_DIR/taskstop_e2e"
create_full_fixture "$TASKSTOP_E2E_REPO" > /dev/null
TASKSTOP_E2E_TRANSCRIPT="$TRANSCRIPTS_DIR/taskstop_e2e.jsonl"
TASKSTOP_E2E_LAUNCH=$(emit_tool_use_assistant "toolu_taskstop_e2e" "Bash" ',"command":"sleep 30"')
TASKSTOP_E2E_RESULT=$(emit_bg_shell_launch_result "toolu_taskstop_e2e" "shell_taskstop_e2e")
TASKSTOP_E2E_STOP=$(emit_task_stop_result "toolu_taskstop_e2e" "shell_taskstop_e2e")
write_transcript "$TASKSTOP_E2E_TRANSCRIPT" "$TASKSTOP_E2E_LAUNCH" "$TASKSTOP_E2E_RESULT" "$TASKSTOP_E2E_STOP"

TASKSTOP_E2E_INPUT=$(jq -c -n --arg tp "$TASKSTOP_E2E_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$TASKSTOP_E2E_REPO" "$TASKSTOP_E2E_INPUT"
assert_reached_codex "TaskStop result lets the hook proceed to Codex review"

# ---- TaskStop tool_result: helper drops task from pending ----
# Helper-level: a TaskStop'd task with no task_notification system event
# and no legacy queue-operation record must still drop out of the pending
# set. Guards the TaskStop completion source directly.
echo "Test: helper drops a TaskStop'd task with no task_notification"
TASKSTOP_HELPER_TRANSCRIPT="$TRANSCRIPTS_DIR/taskstop_helper.jsonl"
TASKSTOP_HELPER_LAUNCH=$(emit_tool_use_assistant "toolu_taskstop_helper" "Agent" ',"description":"x","prompt":"x"')
TASKSTOP_HELPER_RESULT=$(emit_async_agent_launch_result "toolu_taskstop_helper" "agent_taskstop_helper")
TASKSTOP_HELPER_STOP=$(emit_task_stop_result "toolu_taskstop_helper" "agent_taskstop_helper")
write_transcript "$TASKSTOP_HELPER_TRANSCRIPT" "$TASKSTOP_HELPER_LAUNCH" "$TASKSTOP_HELPER_RESULT" "$TASKSTOP_HELPER_STOP"

TASKSTOP_HELPER_PENDING=$(
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    list_pending_background_task_ids "$TASKSTOP_HELPER_TRANSCRIPT" 2>/dev/null
)
if [[ -z "$TASKSTOP_HELPER_PENDING" ]]; then
    pass "TaskStop result (no task_notification) removes the task from pending"
else
    fail "TaskStop result (no task_notification) removes the task from pending" \
        "empty pending list" "got: $TASKSTOP_HELPER_PENDING"
fi

# ---- TaskStop with id in message only (fallback to message parsing) ----
# Some Claude Code builds record the stopped id only inside the message
# text and omit the separate .toolUseResult.task_id field. Source 3 must
# fall back to parsing the id out of the message, or such a stopped task is
# never recognised and pins the loop forever.
echo "Test: TaskStop with id only in message still marks task completed -> reaches Codex"
TASKSTOP_MSGONLY_REPO="$TEST_DIR/taskstop_msgonly"
create_full_fixture "$TASKSTOP_MSGONLY_REPO" > /dev/null
TASKSTOP_MSGONLY_TRANSCRIPT="$TRANSCRIPTS_DIR/taskstop_msgonly.jsonl"
TASKSTOP_MSGONLY_LAUNCH=$(emit_tool_use_assistant "toolu_taskstop_msgonly" "Bash" ',"command":"sleep 30"')
TASKSTOP_MSGONLY_RESULT=$(emit_bg_shell_launch_result "toolu_taskstop_msgonly" "shell_taskstop_msgonly")
TASKSTOP_MSGONLY_STOP=$(emit_task_stop_result_message_only "toolu_taskstop_msgonly" "shell_taskstop_msgonly")
write_transcript "$TASKSTOP_MSGONLY_TRANSCRIPT" "$TASKSTOP_MSGONLY_LAUNCH" "$TASKSTOP_MSGONLY_RESULT" "$TASKSTOP_MSGONLY_STOP"

TASKSTOP_MSGONLY_INPUT=$(jq -c -n --arg tp "$TASKSTOP_MSGONLY_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$TASKSTOP_MSGONLY_REPO" "$TASKSTOP_MSGONLY_INPUT"
assert_reached_codex "TaskStop with id only in message proceeds to Codex review"

echo "Test: helper drops a TaskStop'd task whose id is only in the message"
TASKSTOP_MSGONLY_HELPER_TRANSCRIPT="$TRANSCRIPTS_DIR/taskstop_msgonly_helper.jsonl"
TASKSTOP_MSGONLY_HELPER_LAUNCH=$(emit_tool_use_assistant "toolu_taskstop_msgonly_h" "Agent" ',"description":"x","prompt":"x"')
TASKSTOP_MSGONLY_HELPER_RESULT=$(emit_async_agent_launch_result "toolu_taskstop_msgonly_h" "agent_taskstop_msgonly_h")
TASKSTOP_MSGONLY_HELPER_STOP=$(emit_task_stop_result_message_only "toolu_taskstop_msgonly_h" "agent_taskstop_msgonly_h")
write_transcript "$TASKSTOP_MSGONLY_HELPER_TRANSCRIPT" "$TASKSTOP_MSGONLY_HELPER_LAUNCH" "$TASKSTOP_MSGONLY_HELPER_RESULT" "$TASKSTOP_MSGONLY_HELPER_STOP"

TASKSTOP_MSGONLY_HELPER_PENDING=$(
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    list_pending_background_task_ids "$TASKSTOP_MSGONLY_HELPER_TRANSCRIPT" 2>/dev/null
)
if [[ -z "$TASKSTOP_MSGONLY_HELPER_PENDING" ]]; then
    pass "TaskStop result (id only in message) removes the task from pending"
else
    fail "TaskStop result (id only in message) removes the task from pending" \
        "empty pending list" "got: $TASKSTOP_MSGONLY_HELPER_PENDING"
fi

# ---- TaskStop scan tolerates structured messages on unrelated tool_results ----
# Source 3 iterates every .toolUseResult and calls `contains()` on .message.
# An unrelated tool_result whose .message is an object/array/number would make
# jq error; because the completion pipeline falls back to `completed=""`, that
# error wipes valid SDK/legacy completions and makes completed tasks pending
# again. The fix coerces .message to a string before `contains()`.
echo "Test: helper tolerates non-string .message on unrelated tool_results"
NONSTRING_MSG_REPO="$TEST_DIR/nonstring_msg"
create_full_fixture "$NONSTRING_MSG_REPO" > /dev/null
NONSTRING_MSG_TRANSCRIPT="$TRANSCRIPTS_DIR/nonstring_msg.jsonl"
NONSTRING_MSG_LAUNCH=$(emit_tool_use_assistant "toolu_nonstring" "Agent" ',"description":"x","prompt":"x"')
NONSTRING_MSG_RESULT=$(emit_async_agent_launch_result "toolu_nonstring" "agent_nonstring")
NONSTRING_MSG_COMPLETE=$(emit_sdk_task_notification "agent_nonstring" "toolu_nonstring" "completed")
NONSTRING_MSG_NOISE=$(emit_tool_result_nonstring_message "toolu_noise")
write_transcript "$NONSTRING_MSG_TRANSCRIPT" "$NONSTRING_MSG_LAUNCH" "$NONSTRING_MSG_RESULT" "$NONSTRING_MSG_COMPLETE" "$NONSTRING_MSG_NOISE"

NONSTRING_MSG_PENDING=$(
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
    list_pending_background_task_ids "$NONSTRING_MSG_TRANSCRIPT" 2>/dev/null
)
if [[ -z "$NONSTRING_MSG_PENDING" ]]; then
    pass "non-string .message on unrelated tool_result does not poison completions"
else
    fail "non-string .message on unrelated tool_result does not poison completions" \
        "empty pending list" "got: $NONSTRING_MSG_PENDING"
fi

# ---- cross-session output glob: dead task pruned when transcript has no path ----
# Fix B - cross-session output glob. On session resume the current
# transcript has a NEW session id while the task's .output file lives
# under the OLD session dir. When the launch message carries no
# extractable output path, the session-derived path points at the wrong
# (new) session and does not exist. The liveness probe must then search
# sibling session dirs under the same project slug, find the real
# (old-session) file, and let lsof prune the dead task - instead of
# failing open and pinning the loop forever.
echo "Test: cross-session output glob prunes dead task when transcript has no path"
CROSSSESSION_GLOB_REPO="$TEST_DIR/crosssession_glob"
create_full_fixture "$CROSSSESSION_GLOB_REPO" > /dev/null
CROSSSESSION_GLOB_UID=$(id -u)
CROSSSESSION_GLOB_SLUG=$(basename "$TRANSCRIPTS_DIR")
CROSSSESSION_GLOB_OLD_SESSION="aaaaaaaa-1111-2222-3333-444444444444"
CROSSSESSION_GLOB_NEW_SESSION="bbbbbbbb-5555-6666-7777-888888888888"
CROSSSESSION_GLOB_TASK_ID="shell_glob_cross_session"
CROSSSESSION_GLOB_REAL_OUTPUT="/tmp/claude-${CROSSSESSION_GLOB_UID}/${CROSSSESSION_GLOB_SLUG}/${CROSSSESSION_GLOB_OLD_SESSION}/tasks/${CROSSSESSION_GLOB_TASK_ID}.output"

# Launch result WITHOUT the embedded output path so transcript extraction
# returns empty, forcing the session-derived path (and thus the Fix B glob).
CROSSSESSION_GLOB_LAUNCH=$(emit_tool_use_assistant "toolu_glob" "Bash" ',"command":"sleep 30"')
CROSSSESSION_GLOB_RESULT=$(emit_bg_shell_launch_result "toolu_glob" "$CROSSSESSION_GLOB_TASK_ID")

CROSSSESSION_GLOB_TRANSCRIPT="/tmp/claude-${CROSSSESSION_GLOB_UID}/${CROSSSESSION_GLOB_SLUG}/${CROSSSESSION_GLOB_NEW_SESSION}.jsonl"
write_transcript "$CROSSSESSION_GLOB_TRANSCRIPT" "$CROSSSESSION_GLOB_LAUNCH" "$CROSSSESSION_GLOB_RESULT"

# Real output file lives in the OLD session dir; the NEW session dir is
# never created, so the session-derived path does not exist.
mkdir -p "$(dirname "$CROSSSESSION_GLOB_REAL_OUTPUT")"
touch "$CROSSSESSION_GLOB_REAL_OUTPUT"

CROSSSESSION_GLOB_INPUT=$(jq -c -n --arg tp "$CROSSSESSION_GLOB_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$CROSSSESSION_GLOB_REPO" "$CROSSSESSION_GLOB_INPUT" "" "$TEST_DIR/bin/lsof-dead"
rm -rf "/tmp/claude-${CROSSSESSION_GLOB_UID}/${CROSSSESSION_GLOB_SLUG}/${CROSSSESSION_GLOB_OLD_SESSION}" \
       "/tmp/claude-${CROSSSESSION_GLOB_UID}/${CROSSSESSION_GLOB_SLUG}/${CROSSSESSION_GLOB_NEW_SESSION}.jsonl" 2>/dev/null || true
assert_reached_codex "dead task pruned via cross-session glob when transcript has no output path"

# ---- cross-session output glob: alive task is NOT wrongly pruned ----
# Fix B safety property: the cross-session glob only EXPANDS where we look
# for the .output file. When the glob finds the real (old-session) file and
# lsof still sees an open fd, the task is genuinely alive and must
# short-circuit - never be pruned.
#
# This case is the gap the dead-glob test above cannot close: when the
# derived path is absent, is_bg_task_alive FAILS OPEN (returns alive) if the
# glob never finds the file. So "alive -> short-circuit" alone is a tautology
# here - it passes whether or not the glob ran. A lsof SPY is therefore
# required: the spy records the path it was asked to probe, then reports
# alive. If the glob located the old-session .output, lsof is invoked on
# that real path; if the glob was bypassed, fail-open returns before lsof
# is ever called and the probe log stays empty.
echo "Test: cross-session output glob keeps alive task (lsof holder) -> short-circuits"
CROSSSESSION_GLOB_ALIVE_REPO="$TEST_DIR/crosssession_glob_alive"
CROSSSESSION_GLOB_ALIVE_LOOP=$(create_full_fixture "$CROSSSESSION_GLOB_ALIVE_REPO")
CROSSSESSION_GLOB_ALIVE_STATE="$CROSSSESSION_GLOB_ALIVE_LOOP/state.md"
CROSSSESSION_GLOB_ALIVE_UID=$(id -u)
CROSSSESSION_GLOB_ALIVE_SLUG=$(basename "$TRANSCRIPTS_DIR")
CROSSSESSION_GLOB_ALIVE_OLD_SESSION="aaaaaaaa-1111-2222-3333-444444444444"
CROSSSESSION_GLOB_ALIVE_NEW_SESSION="bbbbbbbb-5555-6666-7777-888888888888"
CROSSSESSION_GLOB_ALIVE_TASK_ID="shell_glob_cross_session_alive"
CROSSSESSION_GLOB_ALIVE_REAL_OUTPUT="/tmp/claude-${CROSSSESSION_GLOB_ALIVE_UID}/${CROSSSESSION_GLOB_ALIVE_SLUG}/${CROSSSESSION_GLOB_ALIVE_OLD_SESSION}/tasks/${CROSSSESSION_GLOB_ALIVE_TASK_ID}.output"

# lsof spy: logs the probed path, then reports the task alive (exit 0).
CROSSSESSION_GLOB_ALIVE_LSOF_LOG="$TEST_DIR/lsof_glob_alive.log"
rm -f "$CROSSSESSION_GLOB_ALIVE_LSOF_LOG"
cat > "$TEST_DIR/bin/lsof-glob-alive-spy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$CROSSSESSION_GLOB_ALIVE_LSOF_LOG"
exit 0
EOF
chmod +x "$TEST_DIR/bin/lsof-glob-alive-spy"

# Launch result WITHOUT the embedded output path so transcript extraction
# returns empty, forcing the session-derived path (and thus the Fix B glob).
CROSSSESSION_GLOB_ALIVE_LAUNCH=$(emit_tool_use_assistant "toolu_glob_alive" "Bash" ',"command":"sleep 30"')
CROSSSESSION_GLOB_ALIVE_RESULT=$(emit_bg_shell_launch_result "toolu_glob_alive" "$CROSSSESSION_GLOB_ALIVE_TASK_ID")

CROSSSESSION_GLOB_ALIVE_TRANSCRIPT="/tmp/claude-${CROSSSESSION_GLOB_ALIVE_UID}/${CROSSSESSION_GLOB_ALIVE_SLUG}/${CROSSSESSION_GLOB_ALIVE_NEW_SESSION}.jsonl"
write_transcript "$CROSSSESSION_GLOB_ALIVE_TRANSCRIPT" "$CROSSSESSION_GLOB_ALIVE_LAUNCH" "$CROSSSESSION_GLOB_ALIVE_RESULT"

# Real output file lives in the OLD session dir; the NEW session dir is
# never created, so the session-derived path does not exist and the glob
# must find the old-session file instead.
mkdir -p "$(dirname "$CROSSSESSION_GLOB_ALIVE_REAL_OUTPUT")"
touch "$CROSSSESSION_GLOB_ALIVE_REAL_OUTPUT"

CROSSSESSION_GLOB_ALIVE_INPUT=$(jq -c -n --arg tp "$CROSSSESSION_GLOB_ALIVE_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$CROSSSESSION_GLOB_ALIVE_REPO" "$CROSSSESSION_GLOB_ALIVE_INPUT" "" "$TEST_DIR/bin/lsof-glob-alive-spy"
rm -rf "/tmp/claude-${CROSSSESSION_GLOB_ALIVE_UID}/${CROSSSESSION_GLOB_ALIVE_SLUG}/${CROSSSESSION_GLOB_ALIVE_OLD_SESSION}" \
       "/tmp/claude-${CROSSSESSION_GLOB_ALIVE_UID}/${CROSSSESSION_GLOB_ALIVE_SLUG}/${CROSSSESSION_GLOB_ALIVE_NEW_SESSION}.jsonl" 2>/dev/null || true
rm -f "$TEST_DIR/bin/lsof-glob-alive-spy"

# The task is alive, so the hook must short-circuit (no Codex).
assert_systemmessage_only \
    "alive task found via cross-session glob still short-circuits" \
    "$CROSSSESSION_GLOB_ALIVE_REPO" "$CROSSSESSION_GLOB_ALIVE_STATE" "1 background task"

# The real guard: lsof must actually have been invoked on the old-session
# .output path. An empty/non-matching log means the glob was bypassed and
# the short-circuit above only passed via fail-open (file-absent) - which
# would hide a glob regression exactly like removing Fix B.
if [[ -s "$CROSSSESSION_GLOB_ALIVE_LSOF_LOG" ]] \
   && grep -qF "$CROSSSESSION_GLOB_ALIVE_REAL_OUTPUT" "$CROSSSESSION_GLOB_ALIVE_LSOF_LOG"; then
    pass "cross-session glob located the old-session .output (lsof probed it)"
else
    fail "cross-session glob located the old-session .output (lsof probed it)" \
        "lsof probe of $CROSSSESSION_GLOB_ALIVE_REAL_OUTPUT" \
        "log empty or no match: $(cat "$CROSSSESSION_GLOB_ALIVE_LSOF_LOG" 2>/dev/null)"
fi
rm -f "$CROSSSESSION_GLOB_ALIVE_LSOF_LOG"

# ---------------- AC-25c ----------------
# Some Claude Code launch records omit the trailing
# "You will be notified when it completes." sentence. The path extractor must
# still recover the real output path from the JSON string (bounded by the
# closing quote) instead of returning no match. A no-match would make
# is_bg_task_alive fall back to the derived current-session path, so the real
# old-session output file is never probed and the dead task stays pending
# forever -- the exact session-resume regression AC-25 guards against.
echo "Test AC-25c: liveness probe recovers real path when launch message omits notification suffix"
AC25C_REPO="$TEST_DIR/ac25c"
create_full_fixture "$AC25C_REPO" > /dev/null
AC25C_UID=$(id -u)
AC25C_SLUG=$(basename "$TRANSCRIPTS_DIR")
AC25C_OLD_SESSION="aaaaaaaa-1111-2222-3333-444444444444"
AC25C_NEW_SESSION="bbbbbbbb-5555-6666-7777-888888888888"
AC25C_TASK_ID="shell_resumed_session_no_suffix"
AC25C_REAL_OUTPUT="/tmp/claude-${AC25C_UID}/${AC25C_SLUG}/${AC25C_OLD_SESSION}/tasks/${AC25C_TASK_ID}.output"

AC25C_LAUNCH=$(emit_tool_use_assistant "toolu_AC25C" "Bash" ',"command":"sleep 30"')
# Fourth arg "0" -> emit the launch message WITHOUT the notification suffix.
AC25C_RESULT=$(emit_bg_shell_launch_result_with_output_path "toolu_AC25C" "$AC25C_TASK_ID" "$AC25C_REAL_OUTPUT" 0)

AC25C_TRANSCRIPT="/tmp/claude-${AC25C_UID}/${AC25C_SLUG}/${AC25C_NEW_SESSION}.jsonl"
write_transcript "$AC25C_TRANSCRIPT" "$AC25C_LAUNCH" "$AC25C_RESULT"

mkdir -p "$(dirname "$AC25C_REAL_OUTPUT")"
touch "$AC25C_REAL_OUTPUT"

AC25C_INPUT=$(jq -c -n --arg tp "$AC25C_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$AC25C_REPO" "$AC25C_INPUT" "" "$TEST_DIR/bin/lsof-dead"
rm -rf "/tmp/claude-${AC25C_UID}/${AC25C_SLUG}/${AC25C_OLD_SESSION}" \
       "/tmp/claude-${AC25C_UID}/${AC25C_SLUG}/${AC25C_NEW_SESSION}.jsonl" 2>/dev/null || true
assert_reached_codex "AC-25c: dead task pruned when launch message omits the notification suffix"

# ---------------- AC-25d ----------------
# Task-id matching must be exact, not a substring match. When a pending id
# is a prefix of another background task id (bash_1 vs bash_10), a bare
# grep -F "$task_id" also matches the longer id's launch line. With the
# dead superstring task (bash_10) launched earlier, head -n1 used to select
# bash_10's output path, lsof then saw a closed file, and the still-running
# bash_1 was pruned -- letting the stop hook reach Codex before bash_1
# finished. The extractor must anchor on the exact backgroundTaskId value.
echo "Test AC-25d: liveness probe matches exact task id (bash_1 not confused with bash_10)"
AC25D_REPO="$TEST_DIR/ac25d"
AC25D_LOOP=$(create_full_fixture "$AC25D_REPO")
AC25D_STATE="$AC25D_LOOP/state.md"
AC25D_TRANSCRIPT="$TRANSCRIPTS_DIR/ac25d.jsonl"

# bash_10: dead (launched FIRST, output exists, no holder).
# bash_1:  alive (launched SECOND, output exists, holder present).
AC25D_DEAD_ID="bash_10"
AC25D_ALIVE_ID="bash_1"
AC25D_DEAD_OUTPUT="$TRANSCRIPTS_DIR/${AC25D_DEAD_ID}.output"
AC25D_ALIVE_OUTPUT="$TRANSCRIPTS_DIR/${AC25D_ALIVE_ID}.output"

# Dead task's launch line is written FIRST so the buggy substring grep
# (grep -F "bash_1") would encounter it before the real bash_1 line and
# pick its output path via head -n1.
AC25D_DEAD_LAUNCH=$(emit_tool_use_assistant "toolu_AC25D_dead" "Bash" ',"command":"sleep 1"')
AC25D_DEAD_RESULT=$(emit_bg_shell_launch_result_with_output_path "toolu_AC25D_dead" "$AC25D_DEAD_ID" "$AC25D_DEAD_OUTPUT")
AC25D_ALIVE_LAUNCH=$(emit_tool_use_assistant "toolu_AC25D_alive" "Bash" ',"command":"sleep 30"')
AC25D_ALIVE_RESULT=$(emit_bg_shell_launch_result_with_output_path "toolu_AC25D_alive" "$AC25D_ALIVE_ID" "$AC25D_ALIVE_OUTPUT")
write_transcript "$AC25D_TRANSCRIPT" \
    "$AC25D_DEAD_LAUNCH" "$AC25D_DEAD_RESULT" \
    "$AC25D_ALIVE_LAUNCH" "$AC25D_ALIVE_RESULT"

mkdir -p "$(dirname "$AC25D_DEAD_OUTPUT")"
touch "$AC25D_DEAD_OUTPUT" "$AC25D_ALIVE_OUTPUT"

# Selective lsof mock: alive (exit 0) only for the EXACT bash_1.output,
# dead (exit 1) for every other file (including bash_10.output). The
# */bash_1.output glob cannot match .../bash_10.output because the latter
# has "0.output" immediately after "bash_1", not ".output".
cat > "$TEST_DIR/bin/lsof-ac25d" << 'EOF'
#!/usr/bin/env bash
case "$1" in
    */bash_1.output) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TEST_DIR/bin/lsof-ac25d"

AC25D_INPUT=$(jq -c -n --arg tp "$AC25D_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$AC25D_REPO" "$AC25D_INPUT" "" "$TEST_DIR/bin/lsof-ac25d"
rm -f "$AC25D_DEAD_OUTPUT" "$AC25D_ALIVE_OUTPUT" "$AC25D_TRANSCRIPT" "$TEST_DIR/bin/lsof-ac25d" 2>/dev/null || true
# bash_1 is still alive -> short-circuit must fire and block Codex.
assert_systemmessage_only \
    "AC-25d: exact task-id match keeps alive bash_1 from being pruned as dead bash_10" \
    "$AC25D_REPO" "$AC25D_STATE" "1 background task"

# ---------------- AC-25e ----------------
# When the recorded output path contains a character that JSON must escape
# (a literal backslash in a directory name), the launch record stored in the
# transcript doubles it to "\\". The extractor must decode the JSON string
# before handing the path to lsof; reading the raw JSONL text returns the
# escaped spelling, [[ -f ]] then misses the real file, the dead task is
# treated as alive forever, and the stop hook never reaches Codex. This is
# the JSON-decode counterpart of AC-25b's whitespace case.
echo "Test AC-25e: liveness probe decodes JSON-escaped characters in recorded output path"
AC25E_REPO="$TEST_DIR/ac25e"
create_full_fixture "$AC25E_REPO" > /dev/null
AC25E_UID=$(id -u)
AC25E_SLUG=$(basename "$TRANSCRIPTS_DIR")
AC25E_OLD_SESSION="aaaaaaaa-1111-2222-3333-444444444444"
AC25E_NEW_SESSION="bbbbbbbb-5555-6666-7777-888888888888"
AC25E_TASK_ID="shell_resumed_session_backslash"
AC25E_REAL_OUTPUT="/tmp/claude-${AC25E_UID}/${AC25E_SLUG}/${AC25E_OLD_SESSION}/tasks/with\\backslash/${AC25E_TASK_ID}.output"

AC25E_LAUNCH=$(emit_tool_use_assistant "toolu_AC25E" "Bash" ',"command":"sleep 30"')
AC25E_RESULT=$(emit_bg_shell_launch_result_with_output_path "toolu_AC25E" "$AC25E_TASK_ID" "$AC25E_REAL_OUTPUT")

AC25E_TRANSCRIPT="/tmp/claude-${AC25E_UID}/${AC25E_SLUG}/${AC25E_NEW_SESSION}.jsonl"
write_transcript "$AC25E_TRANSCRIPT" "$AC25E_LAUNCH" "$AC25E_RESULT"

mkdir -p "$(dirname "$AC25E_REAL_OUTPUT")"
touch "$AC25E_REAL_OUTPUT"

AC25E_INPUT=$(jq -c -n --arg tp "$AC25E_TRANSCRIPT" '{transcript_path:$tp}')
run_stop_hook_with_input "$AC25E_REPO" "$AC25E_INPUT" "" "$TEST_DIR/bin/lsof-dead"
rm -rf "/tmp/claude-${AC25E_UID}/${AC25E_SLUG}/${AC25E_OLD_SESSION}" \
       "/tmp/claude-${AC25E_UID}/${AC25E_SLUG}/${AC25E_NEW_SESSION}.jsonl" 2>/dev/null || true
assert_reached_codex "AC-25e: dead task pruned when real output path contains a JSON-escaped backslash"

print_test_summary "Stop Hook Background-Task Allow Test Summary"
exit $?
