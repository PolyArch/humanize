#!/usr/bin/env bash
#
# Tests for Windows/MSYS path normalization in hooks/lib/project-root.sh
#
# On MSYS/MinGW/Cygwin a single directory has two textual spellings:
#
#   git rev-parse --show-toplevel  ->  C:/Users/name/project
#   bash cd .. && pwd              ->  /c/Users/name/project
#
# MSYS realpath preserves whichever spelling it is handed rather than
# normalizing between them, so a string containment check of one against the
# other fails and setup-rlcr-loop.sh rejects a plan file that is genuinely
# inside the project.
#
# Validates:
# - to_posix_path folds drive-letter, backslash, and POSIX spellings together
# - Arbitrary drive letters work (nothing is hardcoded to C:)
# - Paths containing spaces survive normalization
# - resolve_project_root agrees with `pwd` regardless of which source it used
# - A plan genuinely outside the project is still rejected (no over-permission)
# - Normalization is a no-op on real POSIX systems
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PROJECT_ROOT_LIB="$REPO_ROOT/hooks/lib/project-root.sh"

echo "=========================================="
echo "Path Normalization Tests"
echo "=========================================="
echo ""

if [[ ! -f "$PROJECT_ROOT_LIB" ]]; then
    echo "FATAL: project-root.sh not found at $PROJECT_ROOT_LIB" >&2
    exit 1
fi

# shellcheck source=../hooks/lib/project-root.sh
source "$PROJECT_ROOT_LIB"

IS_WINDOWS_SHELL=false
if _humanize_is_windows_shell; then
    IS_WINDOWS_SHELL=true
fi

# ========================================
# Test 1: the exact reported failure
#   C:/Users/name/project vs /c/Users/name/project
# ========================================

if [[ "$IS_WINDOWS_SHELL" == "true" ]]; then
    got="$(to_posix_path 'C:/Users/name/project')"
    if [[ "$got" == "/c/Users/name/project" ]]; then
        pass "drive-letter form folds to POSIX form"
    else
        fail "drive-letter form folds to POSIX form" "expected /c/Users/name/project, got $got"
    fi

    got="$(to_posix_path '/c/Users/name/project')"
    if [[ "$got" == "/c/Users/name/project" ]]; then
        pass "POSIX form is returned unchanged (idempotent)"
    else
        fail "POSIX form is returned unchanged (idempotent)" "expected /c/Users/name/project, got $got"
    fi

    # The two spellings must be equal AFTER normalization -- this is the
    # comparison setup-rlcr-loop.sh performs.
    a="$(to_posix_path 'C:/Users/name/project')"
    b="$(to_posix_path '/c/Users/name/project')"
    if [[ "$a" == "$b" ]]; then
        pass "both spellings of one directory compare equal"
    else
        fail "both spellings of one directory compare equal" "$a != $b"
    fi
else
    skip "drive-letter folding (not a Windows shell)"
    skip "POSIX form unchanged (not a Windows shell)"
    skip "spellings compare equal (not a Windows shell)"
fi

# ========================================
# Test 2: backslashes and a non-C drive letter
#   F:\Project\Test -> /f/Project/Test
# ========================================

if [[ "$IS_WINDOWS_SHELL" == "true" ]]; then
    got="$(to_posix_path 'F:\Project\Test')"
    if [[ "$got" == "/f/Project/Test" ]]; then
        pass "backslash form with non-C drive folds correctly"
    else
        fail "backslash form with non-C drive folds correctly" "expected /f/Project/Test, got $got"
    fi

    # Claude Code exports CLAUDE_PROJECT_DIR in exactly this shape.
    got="$(to_posix_path 'F:\Project\Public')"
    if [[ "$got" == "/f/Project/Public" ]]; then
        pass "CLAUDE_PROJECT_DIR backslash shape folds correctly"
    else
        fail "CLAUDE_PROJECT_DIR backslash shape folds correctly" "expected /f/Project/Public, got $got"
    fi

    # Drive letters must not be hardcoded: sweep the alphabet.
    sweep_ok=true
    for drive in A D M Z; do
        lower=$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')
        got="$(to_posix_path "${drive}:\\some\\dir")"
        if [[ "$got" != "/${lower}/some/dir" ]]; then
            sweep_ok=false
            fail "arbitrary drive letters supported" "drive $drive gave $got"
            break
        fi
    done
    if [[ "$sweep_ok" == "true" ]]; then
        pass "arbitrary drive letters supported (A, D, M, Z)"
    fi

    got="$(to_posix_path 'C:/')"
    if [[ "$got" == "/c/" || "$got" == "/c" ]]; then
        pass "drive root folds correctly"
    else
        fail "drive root folds correctly" "expected /c or /c/, got $got"
    fi
else
    skip "backslash + non-C drive (not a Windows shell)"
    skip "CLAUDE_PROJECT_DIR shape (not a Windows shell)"
    skip "arbitrary drive letters (not a Windows shell)"
    skip "drive root (not a Windows shell)"
fi

# ========================================
# Test 3: paths containing spaces
#
# Note: setup-rlcr-loop.sh independently rejects a *plan file* path with
# spaces. The project ROOT may still contain them (e.g. C:\Users\my name),
# so normalization must not corrupt or split them.
# ========================================

if [[ "$IS_WINDOWS_SHELL" == "true" ]]; then
    got="$(to_posix_path 'C:\Users\my name\My Project')"
    if [[ "$got" == "/c/Users/my name/My Project" ]]; then
        pass "spaces in path survive normalization"
    else
        fail "spaces in path survive normalization" "expected '/c/Users/my name/My Project', got '$got'"
    fi

    got="$(to_posix_path 'C:/Program Files/some tool')"
    if [[ "$got" == "/c/Program Files/some tool" ]]; then
        pass "spaces in drive-letter form survive normalization"
    else
        fail "spaces in drive-letter form survive normalization" "expected '/c/Program Files/some tool', got '$got'"
    fi
else
    skip "spaces in backslash form (not a Windows shell)"
    skip "spaces in drive-letter form (not a Windows shell)"
fi

# ========================================
# Test 4: no-op on real POSIX systems
#
# A Linux filename may legitimately contain a backslash; rewriting it would
# corrupt a valid path.
# ========================================

if [[ "$IS_WINDOWS_SHELL" == "false" ]]; then
    got="$(to_posix_path '/home/user/project')"
    if [[ "$got" == "/home/user/project" ]]; then
        pass "POSIX path untouched on POSIX shell"
    else
        fail "POSIX path untouched on POSIX shell" "got $got"
    fi

    got="$(to_posix_path '/home/user/we\ird')"
    if [[ "$got" == '/home/user/we\ird' ]]; then
        pass "backslash in POSIX filename is preserved, not rewritten"
    else
        fail "backslash in POSIX filename is preserved, not rewritten" "got $got"
    fi
else
    skip "POSIX no-op checks (running on a Windows shell)"
    skip "POSIX backslash filename (running on a Windows shell)"
fi

# ========================================
# Test 5: empty input
# ========================================

got="$(to_posix_path '')"
if [[ -z "$got" ]]; then
    pass "empty input prints nothing"
else
    fail "empty input prints nothing" "got '$got'"
fi

# ========================================
# Test 6: resolve_project_root agrees with pwd
#
# This is the end-to-end property the bug violated: whichever source the
# resolver used, the answer must be directly comparable with a path built
# from `pwd`.
# ========================================

setup_test_dir
REPO_DIR="$TEST_DIR/proj"
mkdir -p "$REPO_DIR/docs"
(
    cd "$REPO_DIR"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "plan" > docs/plan.md
    git add -A
    git commit -qm "init"
)

PWD_FORM="$(cd "$REPO_DIR" && pwd)"

# 6a: resolver via git fallback (CLAUDE_PROJECT_DIR unset) -- the reported case
got="$(cd "$REPO_DIR" && CLAUDE_PROJECT_DIR= resolve_project_root)"
if [[ "$got" == "$PWD_FORM" ]]; then
    pass "resolve_project_root via git matches pwd form"
else
    fail "resolve_project_root via git matches pwd form" "resolver=$got pwd=$PWD_FORM"
fi

# 6b: the containment check setup-rlcr-loop.sh performs must now hold
PLAN_REAL="$(cd "$REPO_DIR/docs" && pwd)/plan.md"
if [[ "$PLAN_REAL" = "$got"/* ]]; then
    pass "plan inside project passes the containment check"
else
    fail "plan inside project passes the containment check" "plan=$PLAN_REAL root=$got"
fi

# 6c: resolver via CLAUDE_PROJECT_DIR given the drive-letter spelling
if [[ "$IS_WINDOWS_SHELL" == "true" ]]; then
    WIN_FORM="$(cygpath -w "$REPO_DIR" 2>/dev/null || true)"
    if [[ -n "$WIN_FORM" ]]; then
        got_win="$(CLAUDE_PROJECT_DIR="$WIN_FORM" resolve_project_root)"
        if [[ "$got_win" == "$PWD_FORM" ]]; then
            pass "resolve_project_root via backslash CLAUDE_PROJECT_DIR matches pwd form"
        else
            fail "resolve_project_root via backslash CLAUDE_PROJECT_DIR matches pwd form" \
                "resolver=$got_win pwd=$PWD_FORM"
        fi
    else
        skip "backslash CLAUDE_PROJECT_DIR (cygpath -w unavailable)"
    fi

    # git's own spelling, fed back in as CLAUDE_PROJECT_DIR
    GIT_FORM="$(cd "$REPO_DIR" && git rev-parse --show-toplevel)"
    got_git="$(CLAUDE_PROJECT_DIR="$GIT_FORM" resolve_project_root)"
    if [[ "$got_git" == "$PWD_FORM" ]]; then
        pass "resolve_project_root via git-spelled CLAUDE_PROJECT_DIR matches pwd form"
    else
        fail "resolve_project_root via git-spelled CLAUDE_PROJECT_DIR matches pwd form" \
            "resolver=$got_git pwd=$PWD_FORM"
    fi
else
    skip "backslash CLAUDE_PROJECT_DIR (not a Windows shell)"
    skip "git-spelled CLAUDE_PROJECT_DIR (not a Windows shell)"
fi

# ========================================
# Test 7: a plan genuinely outside the project is still rejected
#
# The fix must not turn the containment check into a rubber stamp.
# ========================================

OUTSIDE_DIR="$TEST_DIR/outside"
mkdir -p "$OUTSIDE_DIR"
echo "plan" > "$OUTSIDE_DIR/plan.md"
OUTSIDE_REAL="$(cd "$OUTSIDE_DIR" && pwd)/plan.md"

if [[ ! "$OUTSIDE_REAL" = "$got"/* ]]; then
    pass "plan outside project is still rejected"
else
    fail "plan outside project is still rejected" "outside=$OUTSIDE_REAL was accepted under root=$got"
fi

# A sibling directory sharing a name prefix must not be treated as inside.
SIBLING_DIR="$TEST_DIR/proj-evil"
mkdir -p "$SIBLING_DIR"
echo "plan" > "$SIBLING_DIR/plan.md"
SIBLING_REAL="$(cd "$SIBLING_DIR" && pwd)/plan.md"

if [[ ! "$SIBLING_REAL" = "$got"/* ]]; then
    pass "prefix-sibling directory is not treated as inside the project"
else
    fail "prefix-sibling directory is not treated as inside the project" "sibling=$SIBLING_REAL accepted under root=$got"
fi

# ========================================
# Test 8: project root containing spaces resolves end to end
# ========================================

SPACE_REPO="$TEST_DIR/my project dir"
mkdir -p "$SPACE_REPO/docs"
(
    cd "$SPACE_REPO"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "plan" > docs/plan.md
    git add -A
    git commit -qm "init"
)

SPACE_PWD="$(cd "$SPACE_REPO" && pwd)"
space_got="$(cd "$SPACE_REPO" && CLAUDE_PROJECT_DIR= resolve_project_root)"
if [[ "$space_got" == "$SPACE_PWD" ]]; then
    pass "project root with spaces resolves to the pwd form"
else
    fail "project root with spaces resolves to the pwd form" "resolver=$space_got pwd=$SPACE_PWD"
fi

SPACE_PLAN="$(cd "$SPACE_REPO/docs" && pwd)/plan.md"
if [[ "$SPACE_PLAN" = "$space_got"/* ]]; then
    pass "plan inside a spaced project root passes the containment check"
else
    fail "plan inside a spaced project root passes the containment check" "plan=$SPACE_PLAN root=$space_got"
fi

print_test_summary
