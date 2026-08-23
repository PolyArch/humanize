#!/usr/bin/env bash
#
# Cleanup script for Humanize CGCR runs.
#
# The cleanup order is:
#   1. Resolve the run resources.json.
#   2. Capture rollout evidence from Codex and Claude tmux panes.
#   3. Require terminal markers unless --force is supplied.
#   4. Kill the CGCR tmux session unless --no-kill is supplied.
#   5. Write cleanup.json and refresh rollout.md/closeout.md.
#

set -euo pipefail

SESSION_NAME=""
RUN_DIR=""
RESOURCE_FILE=""
PROJECT_ROOT=""
FORCE="false"
NO_KILL="false"
CAPTURE_LINES="2000"

usage() {
    cat <<'EOF'
cleanup-cgcr.sh - capture rollout evidence and release CGCR runtime resources

Usage:
  scripts/cleanup-cgcr.sh --session NAME [--project-root DIR] [options]
  scripts/cleanup-cgcr.sh --run-dir DIR [options]
  scripts/cleanup-cgcr.sh --resource-file FILE [options]

Options:
  --session NAME        CGCR tmux session name, e.g. humanize-cgcr-20260607-165113
  --project-root DIR    Repo root used when resolving --session
  --run-dir DIR         CGCR run directory containing resources.json
  --resource-file FILE  Explicit resources.json path
  --capture-lines N     Number of pane history lines to capture (default: 2000)
  --force               Cleanup even if terminal markers are missing
  --no-kill             Write rollout files but leave tmux session running
  -h, --help            Show this help

Outputs written under the run directory:
  rollout.md
  closeout.md
  cleanup.json
  codex-pane-final.txt
  claude-monitor-final.txt

Exit codes:
  0 - cleanup completed
  1 - resource resolution failed
  2 - terminal markers missing and --force was not supplied
  3 - cleanup failed
EOF
}

die() {
    local code="$1"
    shift
    printf '[cleanup-cgcr] Error: %s\n' "$*" >&2
    exit "$code"
}

log() {
    printf '[cleanup-cgcr] %s\n' "$*"
}

json_get() {
    local file="$1"
    local key="$2"
    python3 - "$file" "$key" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(sys.argv[2], "")
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

json_escape() {
    python3 - "$1" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1]))
PY
}

resolve_project_root_from_session() {
    local session="$1"
    local pane_path=""

    if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$session" 2>/dev/null; then
        pane_path="$(tmux display-message -p -t "${session}:codex-goal.0" '#{pane_current_path}' 2>/dev/null || true)"
        if [[ -z "$pane_path" ]]; then
            pane_path="$(tmux list-panes -t "$session" -F '#{pane_current_path}' 2>/dev/null | head -n 1 || true)"
        fi
    fi

    if [[ -n "$pane_path" ]]; then
        git -C "$pane_path" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$pane_path"
        return
    fi

    git rev-parse --show-toplevel 2>/dev/null || pwd
}

resolve_resource_for_session() {
    local session="$1"
    local root="$2"

    [[ -d "$root/.humanize/cgcr" ]] || return 1

    python3 - "$root/.humanize/cgcr" "$session" <<'PY'
import json
import pathlib
import sys

base = pathlib.Path(sys.argv[1])
session = sys.argv[2]
matches = []
for path in sorted(base.glob("*/resources.json")):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        continue
    if data.get("tmux_session") == session:
        matches.append(path)

if len(matches) == 1:
    print(matches[0])
    sys.exit(0)
if len(matches) > 1:
    print("\n".join(str(p) for p in matches), file=sys.stderr)
    sys.exit(2)
sys.exit(1)
PY
}

capture_pane() {
    local target="$1"
    local output_file="$2"
    local session="$3"

    if [[ -n "$target" ]] && command -v tmux >/dev/null 2>&1 && tmux has-session -t "$session" 2>/dev/null; then
        tmux capture-pane -t "$target" -p -S "-$CAPTURE_LINES" > "$output_file" 2>/dev/null || {
            printf 'capture failed for target: %s\n' "$target" > "$output_file"
        }
    else
        printf 'tmux session not available: %s\n' "$session" > "$output_file"
    fi
}

write_rollout_files() {
    local terminal_ok="$1"
    local terminal_reason="$2"
    local cleanup_status="$3"
    local ended_at="$4"

    cat > "$ROLLOUT_FILE" <<EOF
# CGCR Rollout

- workflow: CGCR
- goal_id: $GOAL_ID
- repo: $REPO_PATH
- branch: $BRANCH_NAME
- tmux_session: $SESSION_NAME
- codex_target: $CODEX_TARGET
- claude_monitor_target: $CLAUDE_TARGET
- created_at: $CREATED_AT
- rollout_at: $ended_at
- terminal_gate: $terminal_ok
- terminal_reason: $terminal_reason
- cleanup_status: $cleanup_status

## Captured Artifacts

- codex pane: $CODEX_CAPTURE
- claude monitor pane: $CLAUDE_CAPTURE
- cleanup metadata: $CLEANUP_FILE
- resources: $RESOURCE_FILE

## Resource Recovery

The rollout captures pane evidence before resource release. The tmux session is
eligible for cleanup only after Codex emits [GOAL-CLOSEOUT] or reaches a visible
goal terminal state, and Claude monitor emits TERMINAL or cancels the recurring
monitor schedule.
EOF

    cat > "$CLOSEOUT_FILE" <<EOF
# CGCR Closeout

- goal_id: $GOAL_ID
- tmux_session: $SESSION_NAME
- repo: $REPO_PATH
- branch: $BRANCH_NAME
- cleanup_status: $cleanup_status
- terminal_gate: $terminal_ok
- terminal_reason: $terminal_reason

## Codex Final Pane

\`\`\`text
$(tail -n 120 "$CODEX_CAPTURE")
\`\`\`

## Claude Monitor Final Pane

\`\`\`text
$(tail -n 120 "$CLAUDE_CAPTURE")
\`\`\`
EOF
}

write_cleanup_json() {
    local terminal_ok="$1"
    local terminal_reason="$2"
    local cleanup_status="$3"
    local session_exists_after="$4"
    local ended_at="$5"

    cat > "$CLEANUP_FILE" <<EOF
{
  "workflow": "CGCR",
  "goal_id": $(json_escape "$GOAL_ID"),
  "repo": $(json_escape "$REPO_PATH"),
  "branch": $(json_escape "$BRANCH_NAME"),
  "tmux_session": $(json_escape "$SESSION_NAME"),
  "codex_target": $(json_escape "$CODEX_TARGET"),
  "claude_monitor_target": $(json_escape "$CLAUDE_TARGET"),
  "resource_file": $(json_escape "$RESOURCE_FILE"),
  "run_dir": $(json_escape "$RUN_DIR"),
  "created_at": $(json_escape "$CREATED_AT"),
  "cleanup_at": $(json_escape "$ended_at"),
  "terminal_gate": $terminal_ok,
  "terminal_reason": $(json_escape "$terminal_reason"),
  "force": $FORCE,
  "no_kill": $NO_KILL,
  "cleanup_status": $(json_escape "$cleanup_status"),
  "session_exists_after": $session_exists_after,
  "codex_capture": $(json_escape "$CODEX_CAPTURE"),
  "claude_capture": $(json_escape "$CLAUDE_CAPTURE")
}
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session)
            [[ -n "${2:-}" ]] || die 1 "--session requires a value"
            SESSION_NAME="$2"
            shift 2
            ;;
        --project-root)
            [[ -n "${2:-}" ]] || die 1 "--project-root requires a value"
            PROJECT_ROOT="$2"
            shift 2
            ;;
        --run-dir)
            [[ -n "${2:-}" ]] || die 1 "--run-dir requires a value"
            RUN_DIR="$2"
            shift 2
            ;;
        --resource-file)
            [[ -n "${2:-}" ]] || die 1 "--resource-file requires a value"
            RESOURCE_FILE="$2"
            shift 2
            ;;
        --capture-lines)
            [[ -n "${2:-}" ]] || die 1 "--capture-lines requires a value"
            CAPTURE_LINES="$2"
            shift 2
            ;;
        --force)
            FORCE="true"
            shift
            ;;
        --no-kill)
            NO_KILL="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die 1 "unknown option: $1"
            ;;
    esac
done

[[ "$CAPTURE_LINES" =~ ^[0-9]+$ ]] || die 1 "--capture-lines must be a positive integer"

if [[ -n "$RESOURCE_FILE" && -n "$RUN_DIR" ]]; then
    die 1 "use only one of --resource-file or --run-dir"
fi

if [[ -n "$RUN_DIR" ]]; then
    RESOURCE_FILE="$RUN_DIR/resources.json"
fi

if [[ -z "$RESOURCE_FILE" ]]; then
    [[ -n "$SESSION_NAME" ]] || die 1 "one of --session, --run-dir, or --resource-file is required"
    if [[ -z "$PROJECT_ROOT" ]]; then
        PROJECT_ROOT="$(resolve_project_root_from_session "$SESSION_NAME")"
    fi
    RESOURCE_FILE="$(resolve_resource_for_session "$SESSION_NAME" "$PROJECT_ROOT")" || {
        die 1 "could not resolve resources.json for session $SESSION_NAME under $PROJECT_ROOT/.humanize/cgcr"
    }
fi

[[ -f "$RESOURCE_FILE" ]] || die 1 "resources.json not found: $RESOURCE_FILE"
RUN_DIR="$(cd "$(dirname "$RESOURCE_FILE")" && pwd)"
RESOURCE_FILE="$RUN_DIR/resources.json"

WORKFLOW="$(json_get "$RESOURCE_FILE" workflow)"
[[ "$WORKFLOW" == "CGCR" ]] || die 1 "resource file is not a CGCR run: $RESOURCE_FILE"

GOAL_ID="$(json_get "$RESOURCE_FILE" goal_id)"
CREATED_AT="$(json_get "$RESOURCE_FILE" created_at)"
REPO_PATH="$(json_get "$RESOURCE_FILE" repo)"
BRANCH_NAME="$(json_get "$RESOURCE_FILE" branch)"
SESSION_FROM_RESOURCE="$(json_get "$RESOURCE_FILE" tmux_session)"
CODEX_TARGET="$(json_get "$RESOURCE_FILE" codex_target)"
CLAUDE_TARGET="$(json_get "$RESOURCE_FILE" claude_monitor_target)"

[[ -n "$SESSION_FROM_RESOURCE" ]] || die 1 "tmux_session missing in $RESOURCE_FILE"
if [[ -n "$SESSION_NAME" && "$SESSION_NAME" != "$SESSION_FROM_RESOURCE" ]]; then
    die 1 "session mismatch: argument=$SESSION_NAME resource=$SESSION_FROM_RESOURCE"
fi
SESSION_NAME="$SESSION_FROM_RESOURCE"

ROLLOUT_FILE="$RUN_DIR/rollout.md"
CLOSEOUT_FILE="$RUN_DIR/closeout.md"
CLEANUP_FILE="$RUN_DIR/cleanup.json"
CODEX_CAPTURE="$RUN_DIR/codex-pane-final.txt"
CLAUDE_CAPTURE="$RUN_DIR/claude-monitor-final.txt"

if [[ -f "$CLEANUP_FILE" ]]; then
    EXISTING_STATUS="$(json_get "$CLEANUP_FILE" cleanup_status 2>/dev/null || true)"
    EXISTING_SESSION_EXISTS="$(json_get "$CLEANUP_FILE" session_exists_after 2>/dev/null || true)"
    if [[ "$EXISTING_STATUS" == "released" && "$EXISTING_SESSION_EXISTS" == "false" ]]; then
        if ! command -v tmux >/dev/null 2>&1 || ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
            cat <<EOF
CGCR cleanup already complete.
  status: released
  run_dir: $RUN_DIR
  rollout: $ROLLOUT_FILE
  closeout: $CLOSEOUT_FILE
  cleanup: $CLEANUP_FILE
EOF
            exit 0
        fi
    fi
fi

ENDED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log "capturing rollout evidence for $SESSION_NAME"
capture_pane "$CODEX_TARGET" "$CODEX_CAPTURE" "$SESSION_NAME"
capture_pane "$CLAUDE_TARGET" "$CLAUDE_CAPTURE" "$SESSION_NAME"

CODEX_TERMINAL="false"
CLAUDE_TERMINAL="false"
grep -qE '\[GOAL-CLOSEOUT\]|Goal achieved|Goal complete|Goal blocked' "$CODEX_CAPTURE" && CODEX_TERMINAL="true"
grep -qE 'TERMINAL|recurring cron cancelled|CronDelete|Cancelled [A-Za-z0-9_-]+' "$CLAUDE_CAPTURE" && CLAUDE_TERMINAL="true"

TERMINAL_OK="false"
TERMINAL_REASON="codex_terminal=$CODEX_TERMINAL claude_terminal=$CLAUDE_TERMINAL"
if [[ "$CODEX_TERMINAL" == "true" && "$CLAUDE_TERMINAL" == "true" ]]; then
    TERMINAL_OK="true"
fi

if [[ "$TERMINAL_OK" != "true" && "$FORCE" != "true" ]]; then
    write_cleanup_json "false" "$TERMINAL_REASON" "blocked" "true" "$ENDED_AT"
    write_rollout_files "false" "$TERMINAL_REASON" "blocked" "$ENDED_AT"
    die 2 "terminal markers missing ($TERMINAL_REASON); use --force to cleanup anyway"
fi

if [[ "$NO_KILL" == "true" ]]; then
    CLEANUP_STATUS="captured_no_kill"
    SESSION_EXISTS_AFTER="true"
    log "no-kill requested; tmux session left running"
else
    if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log "killing tmux session $SESSION_NAME"
        tmux kill-session -t "$SESSION_NAME" || die 3 "tmux kill-session failed: $SESSION_NAME"
    fi

    if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        CLEANUP_STATUS="failed_session_still_exists"
        SESSION_EXISTS_AFTER="true"
        write_cleanup_json "$TERMINAL_OK" "$TERMINAL_REASON" "$CLEANUP_STATUS" "$SESSION_EXISTS_AFTER" "$ENDED_AT"
        write_rollout_files "$TERMINAL_OK" "$TERMINAL_REASON" "$CLEANUP_STATUS" "$ENDED_AT"
        die 3 "tmux session still exists after kill: $SESSION_NAME"
    else
        CLEANUP_STATUS="released"
        SESSION_EXISTS_AFTER="false"
    fi
fi

write_cleanup_json "$TERMINAL_OK" "$TERMINAL_REASON" "$CLEANUP_STATUS" "$SESSION_EXISTS_AFTER" "$ENDED_AT"
write_rollout_files "$TERMINAL_OK" "$TERMINAL_REASON" "$CLEANUP_STATUS" "$ENDED_AT"

cat <<EOF
CGCR cleanup complete.
  status: $CLEANUP_STATUS
  run_dir: $RUN_DIR
  rollout: $ROLLOUT_FILE
  closeout: $CLOSEOUT_FILE
  cleanup: $CLEANUP_FILE
EOF
