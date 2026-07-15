#!/usr/bin/env bash
#
# Deterministic project-root resolver for all humanize hooks and scripts.
#
# Resolution priority:
#   1. CLAUDE_PROJECT_DIR (set by Claude Code, stable across `cd` within a session)
#   2. git rev-parse --show-toplevel (nearest enclosing repo)
#   3. Non-zero return.
#
# pwd is intentionally NOT used as a fallback: it drifts with `cd`
# invocations during a session and silently causes state.md lookups
# under .humanize/rlcr/ to miss the active loop directory.
#
# The resolved path is passed through realpath so symlinked prefixes
# (e.g. /Users/x vs /private/Users/x on macOS, or /var vs /private/var)
# do not diverge between setup-time and hook-time resolution.
#
# On MSYS/MinGW/Cygwin the resolved path is additionally normalized to the
# POSIX spelling, because a single directory has two textual forms there
# (C:/x and /c/x) that never compare equal. See `to_posix_path`.
#
# Path-comparison sites in validators must mirror this by canonicalizing
# the user-provided side as well; use the companion `canonicalize_path`
# helper below.
#

if [[ -n "${_HUMANIZE_PROJECT_ROOT_SOURCED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_HUMANIZE_PROJECT_ROOT_SOURCED=1

# _humanize_is_windows_shell
#
# True under MSYS/MinGW/Cygwin, where the same filesystem location has two
# spellings. False everywhere else, which keeps `to_posix_path` a no-op on
# real POSIX systems -- a Linux filename may legitimately contain a
# backslash, and must not be rewritten.
#
_humanize_is_windows_shell() {
    case "${OSTYPE:-}" in
        msys | cygwin | win32) return 0 ;;
    esac
    case "$(uname -s 2>/dev/null || true)" in
        MINGW* | MSYS* | CYGWIN*) return 0 ;;
    esac
    return 1
}

# to_posix_path
#
# Normalizes a Windows path spelling to the MSYS/Cygwin POSIX form so that
# paths originating from different sources can be compared as strings:
#
#   C:\Users\x\proj -> /c/Users/x/proj
#   C:/Users/x/proj -> /c/Users/x/proj
#   /c/Users/x/proj -> /c/Users/x/proj   (already POSIX, returned unchanged)
#
# This matters because the two sides of a containment check come from
# sources that disagree: `git rev-parse --show-toplevel` and CLAUDE_PROJECT_DIR
# yield the drive-letter form, while bash `pwd` yields the POSIX form. MSYS
# realpath preserves whichever form it is handed instead of normalizing
# between them, so canonicalization alone does not make them comparable.
#
# Any drive letter and any path are supported; nothing is hardcoded.
#
# Empty input prints nothing and returns 0.
#
to_posix_path() {
    local path="$1"
    if [[ -z "$path" ]]; then
        return 0
    fi

    if ! _humanize_is_windows_shell; then
        printf '%s\n' "$path"
        return 0
    fi

    # Only drive-letter or backslash spellings need rewriting. A bare
    # drive-relative path such as `C:foo` is deliberately left alone: it
    # resolves against a per-drive working directory this helper cannot know.
    case "$path" in
        [A-Za-z]:[\\/]* | [A-Za-z]: | *\\*) ;;
        *)
            printf '%s\n' "$path"
            return 0
            ;;
    esac

    if command -v cygpath >/dev/null 2>&1; then
        local converted
        if converted=$(cygpath -u "$path" 2>/dev/null) && [[ -n "$converted" ]]; then
            printf '%s\n' "$converted"
            return 0
        fi
    fi

    # Fallback for a Windows shell without cygpath: rewrite by hand.
    path="${path//\\//}"
    if [[ "$path" =~ ^([A-Za-z]):(/.*)?$ ]]; then
        local drive="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[2]:-}"
        drive=$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')
        path="/${drive}${rest}"
    fi
    printf '%s\n' "$path"
}

# resolve_project_root
#
# Prints the resolved project root to stdout. Returns 0 on success,
# 1 when neither CLAUDE_PROJECT_DIR nor a git toplevel is available.
#
# Callers that must have a project root should handle the failure:
#
#   PROJECT_ROOT="$(resolve_project_root)" || exit 0   # hook: allow natural stop
#   PROJECT_ROOT="$(resolve_project_root)" || {        # setup: hard error
#       echo "Error: cannot determine humanize project root" >&2
#       exit 1
#   }
#
resolve_project_root() {
    local root="${CLAUDE_PROJECT_DIR:-}"
    if [[ -z "$root" ]]; then
        root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    fi
    if [[ -z "$root" ]]; then
        return 1
    fi

    # Both sources speak the drive-letter dialect on Windows: Claude Code
    # exports CLAUDE_PROJECT_DIR as `F:\Project\Public`, and git prints
    # `F:/Project/Public`. Normalize before canonicalizing so the result is
    # comparable with paths built from `pwd`.
    root="$(to_posix_path "$root")"

    local canonical
    canonical=$(canonicalize_path "$root")
    printf '%s\n' "${canonical:-$root}"
}

# canonicalize_path_prefix
#
# Resolves symlinks ONLY in the parent directory and reattaches the
# original basename verbatim. This is the right helper for comparing
# user-supplied filenames against an expected path inside a known
# directory: a symlink at /tmp/alias pointing at /real/loop/state.md
# MUST NOT canonicalize to /real/loop/state.md for comparison purposes,
# because `mv` operates on the link path itself. Resolving only the
# parent still lets a symlinked project prefix (e.g. /var vs /private/var
# on macOS) match a canonical expected path.
#
# If realpath on the parent fails, falls back to returning the input
# path unchanged (prefix cannot be canonicalized -> caller's comparison
# will correctly fail against a canonical expected path).
#
# Empty input prints nothing and returns 0.
#
canonicalize_path_prefix() {
    local path="$1"
    if [[ -z "$path" ]]; then
        return 0
    fi

    path="$(to_posix_path "$path")"

    local parent base parent_real
    parent=$(dirname -- "$path")
    base=$(basename -- "$path")

    if parent_real=$(realpath "$parent" 2>/dev/null) && [[ -n "$parent_real" ]]; then
        parent_real="$(to_posix_path "$parent_real")"
        printf '%s/%s\n' "${parent_real%/}" "$base"
        return 0
    fi

    # The python3 fallback is POSIX-only. A native Windows interpreter reads
    # `/c/x` as drive-relative and answers `C:\c\x` -- a different directory
    # -- so on a Windows shell we prefer returning the normalized input over
    # a confidently wrong answer. MSYS always ships realpath, so this costs
    # nothing in practice.
    if ! _humanize_is_windows_shell && command -v python3 >/dev/null 2>&1; then
        parent_real=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$parent" 2>/dev/null || true)
        if [[ -n "$parent_real" ]]; then
            printf '%s/%s\n' "${parent_real%/}" "$base"
            return 0
        fi
    fi

    printf '%s\n' "$path"
}

# canonicalize_path
#
# Prints the realpath of the input path. If the path itself does not
# exist yet (common for write validation before the file is created),
# canonicalizes the parent directory and reattaches the basename.
# If realpath is unavailable and python3 is missing, prints the input
# path verbatim.
#
# SECURITY NOTE: This helper dereferences symlinks at the leaf when
# the leaf exists. Do NOT use it to authorize a user-supplied path
# against an expected filename -- use canonicalize_path_prefix instead,
# which only resolves the parent.
#
# Empty input prints nothing and returns 0.
#
canonicalize_path() {
    local path="$1"
    if [[ -z "$path" ]]; then
        return 0
    fi

    path="$(to_posix_path "$path")"

    local canonical=""

    if canonical=$(realpath "$path" 2>/dev/null) && [[ -n "$canonical" ]]; then
        to_posix_path "$canonical"
        return 0
    fi

    # Path does not exist: canonicalize parent, reattach basename.
    local parent base
    parent=$(dirname -- "$path")
    base=$(basename -- "$path")
    if canonical=$(realpath "$parent" 2>/dev/null) && [[ -n "$canonical" ]]; then
        canonical="$(to_posix_path "$canonical")"
        printf '%s/%s\n' "${canonical%/}" "$base"
        return 0
    fi

    # POSIX-only fallback; see the note in canonicalize_path_prefix.
    if ! _humanize_is_windows_shell && command -v python3 >/dev/null 2>&1; then
        canonical=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null || true)
        if [[ -n "$canonical" ]]; then
            printf '%s\n' "$canonical"
            return 0
        fi
    fi

    printf '%s\n' "$path"
}
