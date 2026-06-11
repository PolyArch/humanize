#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_FILE="$PROJECT_ROOT/skills/humanize-kernel-agent-loop/SKILL.md"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "$SKILL_FILE" ]] || fail "missing kernel-agent-loop skill"

grep -q '## Pre-RLCR Bootstrap Gate' "$SKILL_FILE" \
    || fail "skill does not define a pre-RLCR bootstrap gate"
grep -q 'candidate kernels' "$SKILL_FILE" \
    || fail "skill does not forbid candidate implementation before RLCR"
grep -q 'git init' "$SKILL_FILE" \
    || fail "skill does not instruct non-git workspaces to initialize git"
grep -q 'git commit -m "Initialize kernel optimization workspace"' "$SKILL_FILE" \
    || fail "skill does not require an initial scaffold commit"
grep -q 'find .humanize/rlcr -maxdepth 2 -name state.md -print' "$SKILL_FILE" \
    || fail "skill does not verify active RLCR state"
grep -q 'If no `state.md` is present, stop and report' "$SKILL_FILE" \
    || fail "skill does not fail closed when RLCR setup does not create state"
grep -q -- '--strict-success' "$SKILL_FILE" \
    || fail "skill does not start RLCR in strict-success mode"

python3 - "$SKILL_FILE" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
pre_gate = text.index("## Pre-RLCR Bootstrap Gate")
startup = text.index("## RLCR Startup")
if pre_gate > startup:
    print("FAIL: bootstrap gate appears after RLCR startup", file=sys.stderr)
    sys.exit(1)

what_loop = text.index("## What The Loop Should Do")
start_rlcr = text.index("Start RLCR with `--strict-success`", what_loop)
iterate = text.index("Only then iterate on candidate kernels", what_loop)
if start_rlcr > iterate:
    print("FAIL: skill lists kernel iteration before RLCR startup", file=sys.stderr)
    sys.exit(1)
PY

echo "PASS: kernel-agent-loop skill gates work on active RLCR"
