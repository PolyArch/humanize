#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STOP_HOOK="$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
loop_dir="$repo/.humanize/rlcr/2026-05-24_00-00-00"
mkdir -p "$loop_dir" "$tmp/bin"

git -C "$tmp" init -q repo
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test

cat > "$repo/plan.md" <<'PLAN_EOF'
# Plan

## Goal
Reach the measured target.

## Acceptance Criteria
- AC-1: Target metric is met.
PLAN_EOF
git -C "$repo" add plan.md
git -C "$repo" commit -q -m init

branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
base_commit="$(git -C "$repo" rev-parse HEAD)"
cp "$repo/plan.md" "$loop_dir/plan.md"

cat > "$loop_dir/state.md" <<EOF
---
current_round: 0
max_iterations: 0
codex_model: gpt-5.5
codex_effort: high
codex_timeout: 30
push_every_round: false
full_review_round: 2
plan_file: plan.md
plan_tracked: false
start_branch: $branch
base_branch: $branch
base_commit: $base_commit
review_started: false
ask_codex_question: false
session_id:
agent_teams: false
privacy_mode: true
strict_success: true
bitlesson_required: false
bitlesson_file: .humanize/bitlesson.md
bitlesson_allow_empty_none: true
mainline_stall_count: 0
last_mainline_verdict: unknown
drift_status: normal
started_at: 2026-05-24T00:00:00Z
---
EOF

cat > "$loop_dir/goal-tracker.md" <<'TRACKER_EOF'
# Goal Tracker

## IMMUTABLE SECTION

### Ultimate Goal
Reach the measured target.

### Acceptance Criteria
- AC-1: Target metric is met.

## MUTABLE SECTION

#### Active Tasks
- Continue.
TRACKER_EOF

cat > "$loop_dir/round-0-summary.md" <<'SUMMARY_EOF'
# Round 0 Summary

## Work Completed
- Attempted target.
SUMMARY_EOF

cat > "$loop_dir/round-0-contract.md" <<'CONTRACT_EOF'
# Round 0 Contract

Objective: reach target.
CONTRACT_EOF

cat > "$tmp/bin/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
    echo 'codex --disable hooks'
    exit 0
fi

if [[ "${1:-}" == "exec" ]]; then
    shift
    cwd=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "-C" ]]; then
            cwd="$2"
            shift 2
            continue
        fi
        shift
    done
    [[ -n "$cwd" ]] && cd "$cwd"
    prompt="$(cat)"
    path="$(printf '%s' "$prompt" | grep -oE '\.humanize/rlcr/[^` ]+/round-[0-9]+-review-result\.md' | head -1)"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'OUT_EOF'
Mainline Progress Verdict: STALLED

STOP
OUT_EOF
    exit 0
fi

if [[ "${1:-}" == "review" ]]; then
    echo 'No findings.'
    exit 0
fi

echo "unexpected fake codex args: $*" >&2
exit 2
CODEX_EOF
chmod +x "$tmp/bin/codex"

hook_json="$(
    PATH="$tmp/bin:$PATH" CLAUDE_PROJECT_DIR="$repo" bash "$STOP_HOOK" <<'JSON_EOF'
{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"/tmp","session_id":null}
JSON_EOF
)"

system_message="$(printf '%s\n' "$hook_json" | jq -r '.systemMessage // empty')"
[[ "$system_message" == "Loop: Round 1/0 - Mainline drift detected, replan required" ]] \
    || fail "unexpected systemMessage: $system_message"
[[ ! -f "$loop_dir/stop-state.md" ]] || fail "strict_success wrote stop-state.md"
grep -q '^current_round: 1$' "$loop_dir/state.md" \
    || fail "strict_success did not advance current_round"
grep -q 'Strict Success Mode Override' "$loop_dir/round-1-prompt.md" \
    || fail "strict_success did not write recovery prompt"

echo "PASS: strict_success suppresses STOP and continues"
