#!/usr/bin/env bash
#
# Tests for gen-idea dual-write contract (AC-2).
#
# Verifies the structural contract between validate-gen-idea-io.sh and commands/gen-idea.md:
#   - Validation emits DIRECTIONS_JSON_FILE on success
#   - Validation prevents write when output already exists (no partial write possible)
#   - commands/gen-idea.md contains instructions for dual-write and explore-idea hint
#
# No live Claude invocations — all tests are deterministic shell and file-content checks.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

VALIDATE_SCRIPT="$PROJECT_ROOT/scripts/validate-gen-idea-io.sh"
GEN_IDEA_CMD="$PROJECT_ROOT/commands/gen-idea.md"
VALID_SCHEMA_SCRIPT="$PROJECT_ROOT/scripts/validate-directions-json.sh"

echo "=========================================="
echo "gen-idea Dual-Write Contract Tests"
echo "=========================================="
echo ""

setup_test_dir

# Create mock git repo + plugin root for validate-gen-idea-io.sh
MOCK_REPO="$TEST_DIR/repo"
init_test_git_repo "$MOCK_REPO"
PLUGIN_ROOT="$TEST_DIR/plugin"
mkdir -p "$PLUGIN_ROOT/prompt-template/idea"
touch "$PLUGIN_ROOT/prompt-template/idea/gen-idea-template.md"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

run_validate() {
    (cd "$MOCK_REPO" && bash "$VALIDATE_SCRIPT" "$@")
}

echo "--- Positive Tests (structural contract) ---"
echo ""

# PT-1: Validation emits DIRECTIONS_JSON_FILE on success
EXIT_CODE=0
OUTPUT_DIR="$TEST_DIR/outA"
mkdir -p "$OUTPUT_DIR"
OUTPUT=$(run_validate "test idea" --output "$OUTPUT_DIR/idea.md" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT" | grep -q "DIRECTIONS_JSON_FILE:"; then
    DJSON=$(echo "$OUTPUT" | grep "DIRECTIONS_JSON_FILE:" | sed 's/DIRECTIONS_JSON_FILE: //')
    pass "DIRECTIONS_JSON_FILE: $DJSON emitted on success"
else
    fail "DIRECTIONS_JSON_FILE emitted on success" "exit 0 + DIRECTIONS_JSON_FILE" "exit=$EXIT_CODE"
fi

# PT-2: gen-idea.md contains instructions to write companion JSON
if grep -q "DIRECTIONS_JSON_FILE" "$GEN_IDEA_CMD"; then
    pass "gen-idea.md references DIRECTIONS_JSON_FILE (dual-write instruction present)"
else
    fail "gen-idea.md references DIRECTIONS_JSON_FILE" "DIRECTIONS_JSON_FILE in file" "not found"
fi

# PT-3: gen-idea.md contains explore-idea hint
if grep -q "explore-idea" "$GEN_IDEA_CMD"; then
    pass "gen-idea.md contains explore-idea hint"
else
    fail "gen-idea.md contains explore-idea hint" "explore-idea in file" "not found"
fi

# PT-4: gen-idea.md includes validate-directions-json.sh in allowed-tools
if grep -q "validate-directions-json.sh" "$GEN_IDEA_CMD"; then
    pass "gen-idea.md lists validate-directions-json.sh in allowed-tools"
else
    fail "gen-idea.md lists validate-directions-json.sh in allowed-tools" "found in allowed-tools" "not found"
fi

# PT-5: gen-idea.md exposes alternative language option
if grep -q -- "--alt-language <language-or-code>" "$GEN_IDEA_CMD"; then
    pass "gen-idea.md exposes --alt-language option"
else
    fail "gen-idea.md exposes --alt-language option" "--alt-language <language-or-code>" "not found"
fi

# PT-6: gen-idea.md reads alternative_plan_language from merged config
if grep -q "alternative_plan_language" "$GEN_IDEA_CMD"; then
    pass "gen-idea.md reads alternative_plan_language"
else
    fail "gen-idea.md reads alternative_plan_language" "alternative_plan_language" "not found"
fi

# PT-7: gen-idea.md reuses config-loader merge semantics
if grep -q "config-loader.sh" "$GEN_IDEA_CMD" && grep -q "load_merged_config" "$GEN_IDEA_CMD"; then
    pass "gen-idea.md uses config-loader merge semantics"
else
    fail "gen-idea.md uses config-loader merge semantics" "config-loader.sh + load_merged_config" "missing"
fi

# PT-8: gen-idea.md defines normalized alt language variables
if grep -q "ALT_PLAN_LANGUAGE" "$GEN_IDEA_CMD" && grep -q "ALT_PLAN_LANG_CODE" "$GEN_IDEA_CMD"; then
    pass "gen-idea.md defines ALT_PLAN_LANGUAGE and ALT_PLAN_LANG_CODE"
else
    fail "gen-idea.md defines alternative language variables" "ALT_PLAN_LANGUAGE + ALT_PLAN_LANG_CODE" "missing"
fi

# PT-9: gen-idea.md documents draft variant naming
if grep -q "idea.md -> idea_zh.md" "$GEN_IDEA_CMD"; then
    pass "gen-idea.md documents idea.md -> idea_zh.md"
else
    fail "gen-idea.md documents draft variant naming" "idea.md -> idea_zh.md" "missing"
fi

# PT-10: gen-idea.md keeps directions JSON canonical
if grep -q 'DIRECTIONS_JSON_FILE` is not translated' "$GEN_IDEA_CMD"; then
    pass "gen-idea.md states DIRECTIONS_JSON_FILE is not translated"
else
    fail "gen-idea.md states directions JSON is not translated" "DIRECTIONS_JSON_FILE is not translated" "missing"
fi

# PT-11: gen-idea.md strips --alt-language before validator invocation
if grep -q 'Keep `--alt-language` out of the validator invocation' "$GEN_IDEA_CMD"; then
    pass "gen-idea.md strips --alt-language before validator invocation"
else
    fail "gen-idea.md strips --alt-language before validator invocation" "Keep --alt-language out of validator invocation" "missing"
fi

# PT-12: gen-idea.md keeps warning path on config-loading flow
if grep -q 'Surface these warnings.*continue Phase 1\.5' "$GEN_IDEA_CMD"; then
    pass "gen-idea.md warning path continues to Phase 1.5"
else
    fail "gen-idea.md warning path continues to Phase 1.5" "continue Phase 1.5" "missing"
fi

# PT-13: gen-idea.md preflights translated draft variant collision before writes
if grep -q "DRAFT_VARIANT_FILE" "$GEN_IDEA_CMD" \
        && grep -q "Translated draft variant already exists" "$GEN_IDEA_CMD" \
        && grep -q "before any canonical outputs are written" "$GEN_IDEA_CMD"; then
    pass "gen-idea.md preflights translated draft variant collision"
else
    fail "gen-idea.md preflights translated draft variant collision" "DRAFT_VARIANT_FILE collision check before canonical writes" "missing"
fi

# PT-14: gen-idea.md does not document impossible extensionless variant output
if grep -q "output -> output_zh" "$GEN_IDEA_CMD"; then
    fail "gen-idea.md omits extensionless variant example" "no output -> output_zh example" "found"
else
    pass "gen-idea.md omits extensionless variant example"
fi

# PT-15: validate-directions-json.sh validates the valid fixture
if command -v jq &>/dev/null; then
    VALID_FIXTURE="$SCRIPT_DIR/fixtures/directions/valid.directions.json"
    EXIT_CODE=0
    bash "$VALID_SCHEMA_SCRIPT" "$VALID_FIXTURE" > /dev/null 2>&1 || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 0 ]]; then
        pass "valid fixture passes validate-directions-json.sh"
    else
        fail "valid fixture passes validate-directions-json.sh" "exit 0" "exit=$EXIT_CODE"
    fi
else
    skip "jq not available — skipping schema validation test"
fi

echo ""
echo "--- Negative Tests (no-write-on-failure contract) ---"
echo ""

# NT-1: When output already exists, validation exits non-zero (draft cannot be written)
EXIT_CODE=0
OUTPUT_DIR="$TEST_DIR/outB"
mkdir -p "$OUTPUT_DIR"
touch "$OUTPUT_DIR/existing.md"
OUTPUT=$(run_validate "test idea" --output "$OUTPUT_DIR/existing.md" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]]; then
    pass "validation fails when draft already exists (no-write contract upheld)"
else
    fail "validation fails when draft already exists" "non-zero exit" "exit 0"
fi

# NT-2: When companion JSON already exists, validation exits non-zero (neither file written)
EXIT_CODE=0
OUTPUT_DIR="$TEST_DIR/outC"
mkdir -p "$OUTPUT_DIR"
touch "$OUTPUT_DIR/idea.directions.json"
OUTPUT=$(run_validate "test idea" --output "$OUTPUT_DIR/idea.md" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]]; then
    pass "validation fails when companion already exists (no-write contract upheld)"
else
    fail "validation fails when companion already exists" "non-zero exit" "exit 0"
fi

# NT-3: gen-idea.md error handling mentions not writing OUTPUT_FILE on error
if grep -q "DIRECTIONS_JSON_FILE" "$GEN_IDEA_CMD" && grep -q "Error Handling" "$GEN_IDEA_CMD"; then
    pass "gen-idea.md Error Handling section present alongside dual-write instructions"
else
    fail "gen-idea.md Error Handling section present" "Error Handling section" "not found"
fi

echo ""
print_test_summary "gen-idea Dual-Write Contract Test Summary"
