#!/usr/bin/env bash
#
# Tests for bitlesson-staleness.sh reference-resolution scan
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

SCANNER="$PROJECT_ROOT/scripts/bitlesson-staleness.sh"

echo "========================================"
echo "BitLesson Staleness Scanner Tests"
echo "========================================"
echo ""

setup_test_dir
PROJ="$TEST_DIR/proj"
mkdir -p "$PROJ/scripts/audio_cot" "$PROJ/scripts/emotion"
echo "# manifest_io" > "$PROJ/scripts/audio_cot/manifest_io.py"
echo "# run_infer"   > "$PROJ/scripts/emotion/run_infer.py"

KB="$PROJ/.humanize/bitlesson.md"
mkdir -p "$(dirname "$KB")"
cat > "$KB" <<'EOF'
# BitLesson Knowledge Base

## Lesson: good
Lesson ID: BL-20260101-good
Scope: scripts/audio_cot data-generating scripts (manifest_io.py)
Solution: Derive roots in `scripts/audio_cot/manifest_io.py` from __file__.
Source Rounds: round-1.

## Lesson: stale
Lesson ID: BL-20260102-stale
Scope: eval_audio_cot/scripts data-generating scripts
Solution: Canonical path is `outputs/analysis/score.json`.
Source Rounds: round-2.

## Lesson: dep
Lesson ID: BL-20260103-dep
Scope: scripts/gone things
Status: deprecated — subsystem removed
Solution: Refers to `scripts/gone/removed.py` which no longer exists.
Source Rounds: round-3.

## Lesson: bare
Lesson ID: BL-20260104-bare
Scope: the inference runner
Solution: `run_infer.py` emits the contract rows.
Source Rounds: round-4.

## Lesson: prose
Lesson ID: BL-20260105-prose
Scope: cross-cutting reporting conventions
Solution: Report GO/NO-GO verdicts and ratios like 248/275 and 2/7; cover SSU/SSR/SDP.
Source Rounds: round-5.
EOF

OUT=$(bash "$SCANNER" --bitlesson-file "$KB" --project-root "$PROJ")

if echo "$OUT" | grep -q "STALE: BL-20260102-stale"; then
    pass "flags a lesson whose cited paths do not resolve"
else
    fail "flags a lesson whose cited paths do not resolve" "STALE: BL-20260102-stale" "$OUT"
fi

if echo "$OUT" | grep -q "STALE: BL-20260101-good"; then
    fail "does not flag a lesson whose refs all resolve" "no STALE for good" "$OUT"
else
    pass "does not flag a lesson whose refs all resolve"
fi

if echo "$OUT" | grep -q "STALE: BL-20260104-bare"; then
    fail "resolves bare filenames found anywhere under root" "no STALE for bare" "$OUT"
else
    pass "resolves bare filenames found anywhere under root"
fi

if echo "$OUT" | grep -q "STALE: BL-20260103-dep"; then
    fail "skips deprecated entries" "no STALE for dep" "$OUT"
else
    pass "skips deprecated entries"
fi

if echo "$OUT" | grep -q "STALE: BL-20260105-prose"; then
    fail "ignores prose slashes and ratios (GO/NO-GO, 248/275, SSU/SSR/SDP)" "no STALE for prose" "$OUT"
else
    pass "ignores prose slashes and ratios (GO/NO-GO, 248/275, SSU/SSR/SDP)"
fi

if echo "$OUT" | grep -q "1 deprecated"; then
    pass "summary reports the deprecated/skipped count"
else
    fail "summary reports the deprecated/skipped count" "1 deprecated" "$OUT"
fi

# default is advisory: exit 0 even with a stale entry
set +e
bash "$SCANNER" --bitlesson-file "$KB" --project-root "$PROJ" >/dev/null
RC=$?
set -e
if [[ "$RC" -eq 0 ]]; then
    pass "advisory by default (exit 0) even when stale entries exist"
else
    fail "advisory by default (exit 0) even when stale entries exist" "0" "$RC"
fi

# --strict exits 2 when a stale entry exists
set +e
bash "$SCANNER" --bitlesson-file "$KB" --project-root "$PROJ" --strict >/dev/null
RC=$?
set -e
if [[ "$RC" -eq 2 ]]; then
    pass "--strict exits 2 when an entry has unresolved references"
else
    fail "--strict exits 2 when an entry has unresolved references" "2" "$RC"
fi

print_test_summary "BitLesson Staleness Scanner Test Summary"
