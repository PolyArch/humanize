#!/usr/bin/env bash
#
# bitlesson-staleness.sh — advisory scan of a BitLesson knowledge base for
# entries whose cited file references no longer resolve under the project root.
# Lesson content usually survives a refactor; the paths it cites do not, and the
# stop gate only checks Delta format, so entries silently rot.
#
# Detection is anchored on a known file extension (prose rarely produces
# `word.ext` tokens, unlike "GO/NO-GO" or "248/275"): `dir/file.py` is checked
# verbatim against the root, bare `file.py` anywhere under it. Fenced blocks,
# ellipses, and entries marked `Status: deprecated` are skipped. Extensionless
# directory references are not verified — cite a concrete file to have it checked.
#
# Exit: 0 (advisory). With --strict: 2 if any entry has unresolved references.

set -euo pipefail

BITLESSON_FILE=""
PROJECT_ROOT=""
STRICT="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bitlesson-file) BITLESSON_FILE="${2:-}"; shift 2 ;;
        --project-root)   PROJECT_ROOT="${2:-}"; shift 2 ;;
        --strict)         STRICT="true"; shift ;;
        -h|--help)
            echo "Usage: bitlesson-staleness.sh --bitlesson-file <path> [--project-root <path>] [--strict]"
            exit 0 ;;
        *) echo "Error: Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$BITLESSON_FILE" || ! -f "$BITLESSON_FILE" ]]; then
    echo "Error: --bitlesson-file must point to an existing file" >&2
    exit 1
fi

# Derive the project root the same way bitlesson-select.sh does.
if [[ -z "$PROJECT_ROOT" ]]; then
    dir="$(cd "$(dirname "$BITLESSON_FILE")" && pwd -P)"
    if git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1; then
        PROJECT_ROOT="$(git -C "$dir" rev-parse --show-toplevel)"
    elif [[ "$(basename "$dir")" == ".humanize" ]]; then
        PROJECT_ROOT="$(cd "$dir/.." && pwd -P)"
    else
        PROJECT_ROOT="$dir"
    fi
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
    echo "Error: Project root is not a directory: $PROJECT_ROOT" >&2
    exit 1
fi

# All file basenames under the root (one pass), used to resolve bare filenames.
ALL_BASENAMES="$(find "$PROJECT_ROOT" -path '*/.git' -prune -o -type f -print 2>/dev/null | sed 's#.*/##' | sort -u || true)"

# Per lesson block emit tab-separated records:
#   META <key> <deprecated:0|1>
#   CAND <S|F> <key> <token>     (S = has a slash, checked verbatim; F = bare name)
extract_candidates() {
    awk '
        BEGIN { EXT = "\\.(py|sh|md|json|js|ts|tsx|jsx|yaml|yml|toml|txt|sql|cfg|ini|c|cc|cpp|h|hpp|go|rs|rb|java)" }
        function flush(   i) {
            if (label == "") return
            key = (id != "" ? id : label)
            printf "META\t%s\t%d\n", key, dep
            if (!dep) for (i = 1; i <= nc; i++) printf "CAND\t%s\t%s\t%s\n", ctype[i], key, ctok[i]
            delete ctok; delete ctype; delete seen; nc = 0; dep = 0; id = ""; label = ""
        }
        /^```/ || /^~~~/ { fence = !fence; next }
        fence { next }
        /^##[[:space:]]*Lesson:/ { flush(); label = $0; sub(/^##[[:space:]]*Lesson:[[:space:]]*/, "", label); next }
        label == "" { next }
        {
            if ($0 ~ /^Lesson ID:/) { id = $0; sub(/^Lesson ID:[[:space:]]*/, "", id); gsub(/^[[:space:]]+|[[:space:]]+$/, "", id) }
            if (tolower($0) ~ /^status:[[:space:]]*deprecated/) dep = 1
            line = $0
            gsub(/[`(),"<>;\047]/, " ", line)   # markdown/punct delimiters incl. backtick, apostrophe
            n = split(line, toks, /[[:space:]]+/)
            for (j = 1; j <= n; j++) {
                t = toks[j]
                sub(/:[0-9]+(-[0-9]+)?$/, "", t)        # trailing :line / :line-range
                gsub(/^[.,:;]+|[.,:;]+$/, "", t)        # surrounding punctuation
                if (t == "") continue
                if (index(t, "...") > 0) continue       # ellipsis / abbreviated path
                if (t ~ (EXT "/")) continue             # prose join e.g. score.py/labeler.py
                if (t !~ (EXT "$")) continue            # must end in a known extension
                if (t !~ /^[A-Za-z0-9._\/-]+$/) continue
                ttype = (index(t, "/") > 0) ? "S" : "F"
                if ((ttype t) in seen) continue
                seen[ttype t] = 1
                ctype[++nc] = ttype; ctok[nc] = t
            }
        }
        END { flush() }
    ' "$BITLESSON_FILE"
}

declare -A UNRESOLVED
ORDER=()
TOTAL=0
DEPRECATED=0

while IFS=$'\t' read -r rec a b c; do
    if [[ "$rec" == "META" ]]; then
        TOTAL=$((TOTAL + 1))
        [[ "$b" == "1" ]] && DEPRECATED=$((DEPRECATED + 1))
    else  # CAND: a=type, b=key, c=token
        if [[ "$a" == "S" ]]; then
            [[ -e "$PROJECT_ROOT/$c" || -e "$c" ]] && continue
        else
            grep -qxF -- "$c" <<<"$ALL_BASENAMES" && continue
        fi
        [[ -n "${UNRESOLVED[$b]:-}" ]] || ORDER+=("$b")
        UNRESOLVED[$b]+="${UNRESOLVED[$b]:+$'\n'}$c"
    fi
done < <(extract_candidates)

for key in ${ORDER[@]+"${ORDER[@]}"}; do
    echo "STALE: $key"
    printf '%s\n' "${UNRESOLVED[$key]}" | sed 's/^/  - /'
done

echo ""
echo "BitLesson staleness: scanned $TOTAL entries ($DEPRECATED deprecated, skipped); ${#ORDER[@]} with unresolved references."

if [[ "$STRICT" == "true" && "${#ORDER[@]}" -gt 0 ]]; then
    exit 2
fi
exit 0
