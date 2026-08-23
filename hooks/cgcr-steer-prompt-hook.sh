#!/usr/bin/env bash
#
# Build a CGCR [MONITOR] steer prompt from fresh monitor evidence.
#
# This hook is intentionally read-only. It does not inspect git, mutate files,
# or inject into tmux. The Claude monitor decides whether injection is allowed.
#

set -euo pipefail

MODE="approved"
GOAL_ID=""
DRIFT_STATUS="drift"
CORRECTION_COUNT=""
TRANSCRIPT_FILE=""
REASON="scope drift detected"
DEVIATION_CLASS="scope_drift"
ORIGINAL_GOAL="<one-sentence original goal>"
LATEST_USER_CONSTRAINTS="<latest relevant user constraints>"
CURRENT_CODEX_DIRECTION="<what Codex is doing now>"
OBSERVED_DEVIATION="<specific observed deviation>"
EVIDENCE_LINES=()

usage() {
    cat <<'EOF'
cgcr-steer-prompt-hook.sh - build a CGCR monitor steer prompt

Usage:
  hooks/cgcr-steer-prompt-hook.sh --goal-id ID [options]

Options:
  --goal-id ID                 MONITOR_TARGET_ID for the Codex goal
  --mode auto|approved         Prompt tag mode (default: approved)
  --drift-status drift|clean   Whether the current tick found drift (default: drift)
  --correction-count N         Prior same-goal drift-correction count
  --transcript PATH            Read-only transcript used to count prior steers
  --reason TEXT                One-line monitor reason
  --deviation-class TEXT       Deviation class, such as scope_drift
  --original-goal TEXT         Reconstructed original goal
  --latest-user-constraints TEXT
                               Latest relevant user constraints
  --current-codex-direction TEXT
                               Current Codex direction
  --observed-deviation TEXT    Specific mismatch or drift
  --evidence TEXT              Evidence line; may be repeated
  -h, --help                   Show help

If --drift-status is clean, the hook does not produce a steer prompt and prints
a RESET marker for the monitor to treat the correction count as 0.

If --drift-status is drift, the hook increments the prior same-goal correction
count by 1, then chooses the base prompt from that current count. If
--correction-count is omitted and --transcript is supplied, the hook counts prior
[MONITOR:auto] or [MONITOR:approved] prompts in that transcript with the same
goal_id. If both are omitted, it uses 0.
EOF
}

die() {
    printf '[cgcr-steer-prompt-hook] Error: %s\n' "$*" >&2
    exit 1
}

validate_nonnegative_integer() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] || die "--correction-count must be a non-negative integer"
}

append_evidence() {
    EVIDENCE_LINES+=("$1")
}

count_prior_steers_from_transcript() {
    local transcript="$1"
    local goal_id="$2"

    [[ -r "$transcript" ]] || die "transcript is not readable: $transcript"

    awk -v goal="$goal_id" '
        /\[MONITOR:(auto|approved)\]/ {
            in_monitor = 1
            if (index($0, "goal_id: " goal) > 0 || index($0, "goal_id:" goal) > 0) {
                count++
                in_monitor = 0
            }
            next
        }
        in_monitor && (index($0, "goal_id: " goal) > 0 || index($0, "goal_id:" goal) > 0) {
            count++
            in_monitor = 0
            next
        }
        in_monitor && /\[\/MONITOR\]/ {
            in_monitor = 0
        }
        END {
            print count + 0
        }
    ' "$transcript"
}

print_evidence_block() {
    printf 'evidence:\n'
    printf -- '- Original goal: %s\n' "$ORIGINAL_GOAL"
    printf -- '- Latest user constraints: %s\n' "$LATEST_USER_CONSTRAINTS"
    printf -- '- Current Codex direction: %s\n' "$CURRENT_CODEX_DIRECTION"
    printf -- '- Observed deviation: %s\n' "$OBSERVED_DEVIATION"

    local line
    for line in "${EVIDENCE_LINES[@]}"; do
        [[ -n "$line" ]] || continue
        printf -- '- %s\n' "$line"
    done
}

print_common_constraints() {
    cat <<'EOF'
constraints:
- Do not broaden scope.
- Do not introduce unrelated features, refactors, or architecture changes.
- Do not fabricate tests, data, screenshots, logs, or review results.
- Do not claim verification passed unless exact commands were run.
- Preserve useful in-scope work already completed.
- If this monitor instruction conflicts with the original user goal, pause and ask the user.

required_response:
Reply with [MONITOR-ACK] before acting.
[/MONITOR]
EOF
}

print_prompt_header() {
    printf '[MONITOR:%s]\n' "$MODE"
    printf 'goal_id: %s\n' "$GOAL_ID"
    printf 'reason: %s\n' "$REASON"
    printf 'deviation_class: %s\n' "$DEVIATION_CLASS"
    print_evidence_block
}

print_simple_guidance_prompt() {
    print_prompt_header
    cat <<'EOF'

instruction:
Return attention to the original goal before making further changes. Inspect the cited evidence, identify the next action that directly serves the original goal, and continue only on that path. Preserve useful in-scope work and stop expanding work that is not required for the original goal.

EOF
    print_common_constraints
}

print_explicit_realignment_prompt() {
    print_prompt_header
    cat <<'EOF'

instruction:
Re-align your current work to the original goal before making further changes. Identify the exact mismatch between the original goal and your current direction, then adjust your next actions so they serve the original goal directly. Preserve useful in-scope work, but stop expanding work that is not required by the original goal.

constraints:
- Do not broaden scope.
- Do not add unrelated features or refactors.
- Do not continue a tangent unless you can explain why it is necessary for the original goal.
- Do not claim verification passed unless exact commands were run.
- If this monitor instruction conflicts with the original user goal, pause and ask the user.

required_response:
Reply with [MONITOR-ACK] before acting.
[/MONITOR]
EOF
}

print_stop_and_classify_prompt() {
    print_prompt_header
    cat <<'EOF'

instruction:
Stop the current tangent before making more changes. Classify the current work into:
1. Work that directly supports the original goal.
2. Work that is unrelated or only indirectly useful.
3. Work that is uncertain and needs user confirmation.

Continue only with category 1. For category 2, stop or undo only if needed to avoid harming the goal. For category 3, ask the user before continuing.

constraints:
- Do not keep building on uncertain assumptions.
- Do not turn cleanup, refactor, exploration, or architecture changes into new goals.
- Do not hide or relabel off-target work as completed goal work.
- Do not fabricate verification.
- If you cannot recover the original goal from current context, pause and ask the user.

required_response:
Reply with [MONITOR-ACK] before acting.
[/MONITOR]
EOF
}

print_occam_prompt() {
    print_prompt_header
    cat <<'EOF'

instruction:
Before further implementation, perform an Occam review. Restate the original goal, identify the simplest sufficient path to satisfy it, and prune work that is not necessary for that path. Continue only with the smallest coherent implementation that satisfies the original goal and user constraints.

Your review should answer:
1. What is the original goal?
2. What is the simplest path that satisfies it?
3. Which current work branches are unnecessary?
4. What will you stop doing now?
5. What exact next action returns the goal to completion?

constraints:
- Prefer the simplest sufficient solution over broader architecture changes.
- Do not introduce new requirements.
- Do not continue parallel branches unless each is necessary.
- Do not preserve off-target work merely because time has already been spent.
- Do not claim completion until the original goal is actually satisfied and verification is truthful.

required_response:
Reply with [MONITOR-ACK] before acting.
[/MONITOR]
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --goal-id)
            [[ -n "${2:-}" ]] || die "--goal-id requires a value"
            GOAL_ID="$2"
            shift 2
            ;;
        --mode)
            [[ -n "${2:-}" ]] || die "--mode requires a value"
            case "$2" in
                auto|approved) MODE="$2" ;;
                *) die "--mode must be auto or approved" ;;
            esac
            shift 2
            ;;
        --drift-status)
            [[ -n "${2:-}" ]] || die "--drift-status requires a value"
            case "$2" in
                drift|clean) DRIFT_STATUS="$2" ;;
                *) die "--drift-status must be drift or clean" ;;
            esac
            shift 2
            ;;
        --correction-count)
            [[ -n "${2:-}" ]] || die "--correction-count requires a value"
            validate_nonnegative_integer "$2"
            CORRECTION_COUNT="$2"
            shift 2
            ;;
        --transcript)
            [[ -n "${2:-}" ]] || die "--transcript requires a value"
            TRANSCRIPT_FILE="$2"
            shift 2
            ;;
        --reason)
            [[ -n "${2:-}" ]] || die "--reason requires a value"
            REASON="$2"
            shift 2
            ;;
        --deviation-class)
            [[ -n "${2:-}" ]] || die "--deviation-class requires a value"
            DEVIATION_CLASS="$2"
            shift 2
            ;;
        --original-goal)
            [[ -n "${2:-}" ]] || die "--original-goal requires a value"
            ORIGINAL_GOAL="$2"
            shift 2
            ;;
        --latest-user-constraints|--latest-user-constraint)
            [[ -n "${2:-}" ]] || die "$1 requires a value"
            LATEST_USER_CONSTRAINTS="$2"
            shift 2
            ;;
        --current-codex-direction)
            [[ -n "${2:-}" ]] || die "--current-codex-direction requires a value"
            CURRENT_CODEX_DIRECTION="$2"
            shift 2
            ;;
        --observed-deviation)
            [[ -n "${2:-}" ]] || die "--observed-deviation requires a value"
            OBSERVED_DEVIATION="$2"
            shift 2
            ;;
        --evidence)
            [[ -n "${2:-}" ]] || die "--evidence requires a value"
            append_evidence "$2"
            shift 2
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

[[ -n "$GOAL_ID" ]] || die "--goal-id is required"

if [[ "$DRIFT_STATUS" == "clean" ]]; then
    cat <<EOF
RESET:
goal_id: $GOAL_ID
correction_count: 0
reason: no drift detected; continue normal monitoring
EOF
    exit 0
fi

if [[ -z "$CORRECTION_COUNT" ]]; then
    if [[ -n "$TRANSCRIPT_FILE" ]]; then
        CORRECTION_COUNT="$(count_prior_steers_from_transcript "$TRANSCRIPT_FILE" "$GOAL_ID")"
    else
        CORRECTION_COUNT="0"
    fi
fi

validate_nonnegative_integer "$CORRECTION_COUNT"

CURRENT_CORRECTION_COUNT=$((CORRECTION_COUNT + 1))
SELECTOR=$(((CURRENT_CORRECTION_COUNT - 1) % 4))

case "$SELECTOR" in
    0) print_simple_guidance_prompt ;;
    1) print_explicit_realignment_prompt ;;
    2) print_stop_and_classify_prompt ;;
    3) print_occam_prompt ;;
esac
