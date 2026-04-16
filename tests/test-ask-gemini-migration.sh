#!/usr/bin/env bash
#
# Regression checks for the Codex-native Gemini helper surface.
#
# After the Codex-facing migration, the Gemini helper and README must
# advertise the installed helper/skill name rather than the Claude-only
# slash-command form. These assertions prevent regressions in both the
# helper script and the top-level README quick-start section.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "  ${GREEN}PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "  ${RED}FAIL${NC}: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

echo "=========================================="
echo "Gemini Helper Migration Regression Tests"
echo "=========================================="
echo ""

ASK_GEMINI="$PROJECT_ROOT/scripts/ask-gemini.sh"
README="$PROJECT_ROOT/README.md"

# ========================================
# scripts/ask-gemini.sh assertions
# ========================================

if [[ ! -f "$ASK_GEMINI" ]]; then
    fail "scripts/ask-gemini.sh is missing"
elif grep -q "/humanize:ask-gemini" "$ASK_GEMINI"; then
    fail "scripts/ask-gemini.sh must not advertise /humanize:ask-gemini"
else
    pass "scripts/ask-gemini.sh does not advertise /humanize:ask-gemini"
fi

if [[ -f "$ASK_GEMINI" ]] && grep -q "^  ask-gemini.sh \[OPTIONS\] <question or task>$" "$ASK_GEMINI"; then
    pass "scripts/ask-gemini.sh USAGE line uses ask-gemini.sh invocation"
else
    fail "scripts/ask-gemini.sh USAGE line must use ask-gemini.sh invocation"
fi

if [[ -f "$ASK_GEMINI" ]] && grep -q "retry: ask-gemini.sh <your question>" "$ASK_GEMINI"; then
    pass "scripts/ask-gemini.sh retry hint uses ask-gemini.sh invocation"
else
    fail "scripts/ask-gemini.sh retry hint must use ask-gemini.sh invocation"
fi

# ========================================
# README.md assertions
# ========================================

if [[ ! -f "$README" ]]; then
    fail "README.md is missing"
elif grep -q "/humanize:ask-gemini" "$README"; then
    fail "README.md must not advertise /humanize:ask-gemini"
else
    pass "README.md does not advertise /humanize:ask-gemini"
fi

if [[ -f "$README" ]] && grep -q "Run the ask-gemini skill" "$README"; then
    pass "README.md Gemini quick-start references the ask-gemini skill"
else
    fail "README.md Gemini quick-start must reference the ask-gemini skill"
fi

# ========================================
# Scoped boundary: Claude/Kimi install guides are the only allowed
# places that may still mention /humanize: or /flow:humanize- forms.
# ========================================

ALLOWED_FILES=(
    "docs/install-for-claude.md"
    "docs/install-for-kimi.md"
    "task.md"
    "tests/test-refine-plan.sh"
    "tests/test-ask-gemini-migration.sh"
)

is_allowed() {
    local rel="$1"
    for allow in "${ALLOWED_FILES[@]}"; do
        [[ "$rel" == "$allow" ]] && return 0
    done
    return 1
}

UNEXPECTED=()
while IFS= read -r hit_file; do
    rel="${hit_file#"$PROJECT_ROOT/"}"
    case "$rel" in
        .humanize/*|.git/*|.cache/*|.codex/*) continue ;;
    esac
    if ! is_allowed "$rel"; then
        UNEXPECTED+=("$rel")
    fi
done < <(grep -rIl -E '/humanize:(ask-gemini|ask-codex|start-rlcr-loop|cancel-rlcr-loop|gen-plan|refine-plan)|/flow:humanize-' "$PROJECT_ROOT" 2>/dev/null)

if [[ ${#UNEXPECTED[@]} -eq 0 ]]; then
    pass "Only scoped Claude/Kimi docs and draft/plan artifacts mention Claude-only slash commands"
else
    fail "Unexpected Claude-only slash command references in: ${UNEXPECTED[*]}"
fi

# ========================================
# The README Gemini quick-start tells users to run the ask-gemini skill;
# install-skill.sh must actually install that skill for --target codex.
# ========================================

INSTALL_SKILL_SCRIPT="$PROJECT_ROOT/scripts/install-skill.sh"
if [[ -f "$INSTALL_SKILL_SCRIPT" ]] \
    && sed -n '/^SKILL_NAMES=(/,/^)/p' "$INSTALL_SKILL_SCRIPT" | grep -qF '"ask-gemini"'; then
    pass "install-skill.sh includes ask-gemini in SKILL_NAMES"
else
    fail "install-skill.sh includes ask-gemini in SKILL_NAMES"
fi

if [[ -f "$PROJECT_ROOT/skills/ask-gemini/SKILL.md" ]]; then
    pass "skills/ask-gemini/SKILL.md exists so install-skill.sh can sync it"
else
    fail "skills/ask-gemini/SKILL.md exists so install-skill.sh can sync it"
fi

# ========================================
# Summary
# ========================================

echo ""
echo "========================================"
echo "Gemini Migration Test Summary"
echo "========================================"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi

echo -e "${GREEN}All tests passed!${NC}"
exit 0
