#!/usr/bin/env bash
#
# Setup script for the Codex-side /flow:humanize-cgcr launcher.
#
# Starts the two-tmux CGCR topology:
#   - Codex pane/window executes /goal
#   - Claude Code pane/window monitors with /humanize:monitor-codex-goal
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RUNTIME_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

TASK_TEXT=""
GOAL_ID=""
SESSION_NAME=""
CADENCE="30m"
PRINCIPLES="no fake data; no placeholder stubs; no fabricated results; do not broaden scope"
NOTIFY_ONLY="false"
PREPARE_ONLY="false"
START_DELAY="${HUMANIZE_CGCR_START_DELAY:-0}"
START_TIMEOUT="${HUMANIZE_CGCR_START_TIMEOUT:-45}"

usage() {
    cat <<'EOF'
setup-cgcr.sh - start Humanize CGCR in two tmux windows

Usage:
  scripts/setup-cgcr.sh --task "<long task prompt>" [options]

Options:
  --task TEXT       Long task prompt for Codex /goal (required)
  --goal-id ID      Explicit MONITOR_TARGET_ID
  --session NAME    Explicit tmux session name
  --cadence DURATION
                   Monitor cadence, e.g. 10m, 30m, 1h (default: 30m)
  --principles TEXT Extra Claude monitor principles
  --notify-only     Start monitor with --notify-only
  --prepare-only    Create .humanize/cgcr resources without starting tmux
  -h, --help        Show help
EOF
}

die() {
    printf '[setup-cgcr] Error: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[setup-cgcr] %s\n' "$*"
}

slugify() {
    local input="$1"
    local slug
    slug="$(printf '%s' "$input" | head -c 48 | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')"
    [[ -n "$slug" ]] || slug="task"
    printf '%s' "$slug"
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

wait_for_pane_text() {
    local target="$1"
    local needle="$2"
    local timeout="$3"
    local desc="$4"
    local elapsed=0

    while (( elapsed < timeout )); do
        if tmux capture-pane -t "$target" -p -S -120 2>/dev/null | grep -qF -- "$needle"; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    die "timed out after ${timeout}s waiting for $desc in $target"
}

wait_for_pane_any_text() {
    local target="$1"
    local timeout="$2"
    local desc="$3"
    shift 3
    local elapsed=0
    local pane_text
    local needle

    while (( elapsed < timeout )); do
        pane_text="$(tmux capture-pane -t "$target" -p -S -120 2>/dev/null || true)"
        for needle in "$@"; do
            if grep -qF -- "$needle" <<<"$pane_text"; then
                return 0
            fi
        done
        sleep 1
        elapsed=$((elapsed + 1))
    done

    log "timed out after ${timeout}s waiting for $desc in $target"
    return 1
}

tmux_paste_literal() {
    local target="$1"
    local text="$2"
    local safe_target="${target//[^A-Za-z0-9_.-]/-}"
    local buffer_name="humanize-cgcr-$$-${safe_target}"

    tmux set-buffer -b "$buffer_name" -- "$text"
    tmux paste-buffer -d -b "$buffer_name" -t "$target"
}

tmux_submit() {
    local target="$1"
    tmux send-keys -t "$target" C-m
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)
            [[ -n "${2:-}" ]] || die "--task requires a value"
            TASK_TEXT="$2"
            shift 2
            ;;
        --goal-id)
            [[ -n "${2:-}" ]] || die "--goal-id requires a value"
            GOAL_ID="$2"
            shift 2
            ;;
        --session)
            [[ -n "${2:-}" ]] || die "--session requires a value"
            SESSION_NAME="$2"
            shift 2
            ;;
        --cadence)
            [[ -n "${2:-}" ]] || die "--cadence requires a value"
            CADENCE="$2"
            shift 2
            ;;
        --principles)
            [[ -n "${2:-}" ]] || die "--principles requires a value"
            PRINCIPLES="$2"
            shift 2
            ;;
        --notify-only)
            NOTIFY_ONLY="true"
            shift
            ;;
        --prepare-only)
            PREPARE_ONLY="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ -n "$TASK_TEXT" ]] || { usage; die "--task is required"; }
if ! [[ "$START_TIMEOUT" =~ ^[0-9]+$ ]]; then
    die "HUMANIZE_CGCR_START_TIMEOUT must be an integer number of seconds"
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TASK_SLUG="$(slugify "$TASK_TEXT")"
[[ -n "$GOAL_ID" ]] || GOAL_ID="cgcr-${TIMESTAMP}-${TASK_SLUG}"
[[ -n "$SESSION_NAME" ]] || SESSION_NAME="humanize-cgcr-${TIMESTAMP}"

if ! [[ "$SESSION_NAME" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    die "--session may contain only letters, digits, dot, underscore, and hyphen"
fi
if ! [[ "$GOAL_ID" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    die "--goal-id may contain only letters, digits, dot, underscore, colon, and hyphen"
fi

RUN_DIR="$PROJECT_ROOT/.humanize/cgcr/${TIMESTAMP}-${TASK_SLUG}"
TASK_FILE="$RUN_DIR/task.md"
CODEX_PROMPT_FILE="$RUN_DIR/codex-goal-prompt.md"
MONITOR_COMMAND_FILE="$RUN_DIR/claude-monitor-command.txt"
CODEX_LAUNCHER_FILE="$RUN_DIR/start-codex.sh"
CLAUDE_LAUNCHER_FILE="$RUN_DIR/start-claude.sh"
RESOURCE_FILE="$RUN_DIR/resources.json"
README_FILE="$RUN_DIR/README.md"

mkdir -p "$RUN_DIR"

BRANCH="$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || true)"
[[ -n "$BRANCH" ]] || BRANCH="unknown"

CODEX_TARGET="${SESSION_NAME}:codex-goal.0"
CLAUDE_TARGET="${SESSION_NAME}:claude-monitor.0"
CODEX_CLI_COMMAND="codex --yolo \"\$(cat $(shell_quote "$CODEX_PROMPT_FILE"))\""
CODEX_START_COMMAND="$(shell_quote "$CODEX_LAUNCHER_FILE")"
if [[ -f "$RUNTIME_ROOT/commands/monitor-codex-goal.md" ]]; then
    CLAUDE_START_COMMAND="claude --dangerously-skip-permissions --plugin-dir $(shell_quote "$RUNTIME_ROOT")"
else
    CLAUDE_START_COMMAND="claude --dangerously-skip-permissions"
fi
CLAUDE_WINDOW_COMMAND="$(shell_quote "$CLAUDE_LAUNCHER_FILE")"

cat > "$TASK_FILE" <<EOF
# CGCR Task

MONITOR_TARGET_ID: $GOAL_ID

$(printf '%s\n' "$TASK_TEXT")
EOF

cat > "$CODEX_PROMPT_FILE" <<EOF
/goal $(printf '%s' "$TASK_TEXT")

MONITOR_TARGET_ID: $GOAL_ID

MONITOR CONTRACT:
A separate Claude Code monitor is running in a different tmux pane/window.
It may observe this run through the Codex transcript, git diff/log/status, and
the tmux pane target: $CODEX_TARGET.
If a message starts with [MONITOR], reply with [MONITOR-ACK] before acting.
Never claim tests passed unless the exact commands were run.
Do not use fake data, placeholder stubs, fabricated results, mock-only logic,
or TODO-only code unless explicitly requested.
Do not broaden scope. If monitor feedback conflicts with the original goal,
pause and ask the user.

At the start, emit:
[GOAL-BINDING]
MONITOR_TARGET_ID: $GOAL_ID
repo: $PROJECT_ROOT
branch: $BRANCH
codex_session_id: unknown
tmux_target: $CODEX_TARGET
started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)

During execution, emit [CHECKPOINT:<phase-name>] blocks with objective,
files_touched, commands_run, verification, current_risk, and next_step.

At the end, emit [GOAL-CLOSEOUT] with outcome, files_changed, commits,
commands_run, tests_or_verification, known_risks, and followups.
EOF

MONITOR_COMMAND="/humanize:cgcr --discover --expect-goal $GOAL_ID --cadence $CADENCE --budget 0.1 --principles $(shell_quote "$PRINCIPLES")"
if [[ "$NOTIFY_ONLY" == "true" ]]; then
    MONITOR_COMMAND="$MONITOR_COMMAND --notify-only"
fi
printf '%s\n' "$MONITOR_COMMAND" > "$MONITOR_COMMAND_FILE"

cat > "$CODEX_LAUNCHER_FILE" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd $(shell_quote "$PROJECT_ROOT")
exec $CODEX_CLI_COMMAND
EOF

cat > "$CLAUDE_LAUNCHER_FILE" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd $(shell_quote "$PROJECT_ROOT")
exec $CLAUDE_START_COMMAND
EOF
chmod +x "$CODEX_LAUNCHER_FILE" "$CLAUDE_LAUNCHER_FILE"

cat > "$README_FILE" <<EOF
# CGCR Run

- goal_id: $GOAL_ID
- repo: $PROJECT_ROOT
- branch: $BRANCH
- tmux_session: $SESSION_NAME
- codex_target: $CODEX_TARGET
- claude_monitor_target: $CLAUDE_TARGET
- codex_start_command: $CODEX_START_COMMAND
- codex_cli_command: $CODEX_CLI_COMMAND
- claude_start_command: $CLAUDE_START_COMMAND
- claude_window_command: $CLAUDE_WINDOW_COMMAND
- task_file: $TASK_FILE
- codex_prompt_file: $CODEX_PROMPT_FILE
- monitor_command_file: $MONITOR_COMMAND_FILE
- codex_launcher_file: $CODEX_LAUNCHER_FILE
- claude_launcher_file: $CLAUDE_LAUNCHER_FILE

Attach:

\`\`\`bash
tmux attach -t $SESSION_NAME
\`\`\`

Codex runs in the \`codex-goal\` window. Claude Code monitor runs in the
\`claude-monitor\` window. Do not implement from Claude Code.
EOF

write_resource_file() {
    local codex_pane_id="$1"
    local claude_pane_id="$2"
    cat > "$RESOURCE_FILE" <<EOF
{
  "workflow": "CGCR",
  "goal_id": "$(json_escape "$GOAL_ID")",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "repo": "$(json_escape "$PROJECT_ROOT")",
  "branch": "$(json_escape "$BRANCH")",
  "tmux_session": "$(json_escape "$SESSION_NAME")",
  "codex_target": "$(json_escape "$CODEX_TARGET")",
  "codex_pane_id": "$(json_escape "$codex_pane_id")",
  "codex_start_command": "$(json_escape "$CODEX_START_COMMAND")",
  "codex_cli_command": "$(json_escape "$CODEX_CLI_COMMAND")",
  "codex_launcher_file": "$(json_escape "$CODEX_LAUNCHER_FILE")",
  "claude_monitor_target": "$(json_escape "$CLAUDE_TARGET")",
  "claude_monitor_pane_id": "$(json_escape "$claude_pane_id")",
  "claude_start_command": "$(json_escape "$CLAUDE_START_COMMAND")",
  "claude_window_command": "$(json_escape "$CLAUDE_WINDOW_COMMAND")",
  "claude_launcher_file": "$(json_escape "$CLAUDE_LAUNCHER_FILE")",
  "task_file": "$(json_escape "$TASK_FILE")",
  "codex_prompt_file": "$(json_escape "$CODEX_PROMPT_FILE")",
  "monitor_command_file": "$(json_escape "$MONITOR_COMMAND_FILE")",
  "cadence": "$(json_escape "$CADENCE")",
  "notify_only": $NOTIFY_ONLY,
  "prepared_only": $PREPARE_ONLY
}
EOF
}

if [[ "$PREPARE_ONLY" == "true" ]]; then
    write_resource_file "not-started" "not-started"
    cat <<EOF
CGCR resources prepared.
  run_dir: $RUN_DIR
  goal_id: $GOAL_ID
  codex_target: $CODEX_TARGET
  monitor_cmd: $MONITOR_COMMAND_FILE
EOF
    exit 0
fi

command -v tmux >/dev/null 2>&1 || die "tmux is required"
command -v codex >/dev/null 2>&1 || die "codex is required"
command -v claude >/dev/null 2>&1 || die "claude is required"

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    die "tmux session already exists: $SESSION_NAME"
fi

log "creating tmux session: $SESSION_NAME"
tmux new-session -d -s "$SESSION_NAME" -n codex-goal -c "$PROJECT_ROOT"
tmux new-window -t "$SESSION_NAME" -n claude-monitor -c "$PROJECT_ROOT"

CODEX_PANE_ID="$(tmux display-message -p -t "$CODEX_TARGET" '#{pane_id}')"
CLAUDE_PANE_ID="$(tmux display-message -p -t "$CLAUDE_TARGET" '#{pane_id}')"
write_resource_file "$CODEX_PANE_ID" "$CLAUDE_PANE_ID"

tmux_paste_literal "$CODEX_TARGET" "$CODEX_START_COMMAND"
tmux_submit "$CODEX_TARGET"

tmux_paste_literal "$CLAUDE_TARGET" "$CLAUDE_WINDOW_COMMAND"
tmux_submit "$CLAUDE_TARGET"

if [[ "$START_DELAY" != "0" ]]; then
    sleep "$START_DELAY"
fi
wait_for_pane_text "$CLAUDE_TARGET" "bypass permissions on" "$START_TIMEOUT" "Claude Code prompt readiness"

tmux_paste_literal "$CLAUDE_TARGET" "$MONITOR_COMMAND"
wait_for_pane_text "$CLAUDE_TARGET" "$GOAL_ID" "$START_TIMEOUT" "rendered monitor command"
tmux_submit "$CLAUDE_TARGET"
if ! wait_for_pane_any_text "$CLAUDE_TARGET" 8 "Claude monitor command start" "esc to interrupt" "Skill(humanize:cgcr)" "Thought for" "Frosting"; then
    log "monitor command did not visibly start after first submit; retrying monitor submit once"
    tmux_submit "$CLAUDE_TARGET"
    wait_for_pane_any_text "$CLAUDE_TARGET" "$START_TIMEOUT" "Claude monitor command start" "esc to interrupt" "Skill(humanize:cgcr)" "Thought for" "Frosting" \
        || die "monitor command did not visibly start after retry"
fi

cat <<EOF
CGCR started.
  run_dir: $RUN_DIR
  goal_id: $GOAL_ID
  tmux_session: $SESSION_NAME
  codex_target: $CODEX_TARGET
  monitor_pane: $CLAUDE_TARGET

Attach with:
  tmux attach -t $SESSION_NAME
EOF
