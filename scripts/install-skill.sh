#!/bin/bash
#
# Install/upgrade Humanize skills for Kimi and/or Codex and configure HUMANIZE_ROOT.
#
# What this does:
# 1) Sync skills/{humanize,humanize-gen-plan,humanize-rlcr} to target skills dir(s)
# 2) Export HUMANIZE_ROOT for this process
# 3) Optionally persist HUMANIZE_ROOT in shell profile (idempotent managed block)
#
# Usage:
#   ./scripts/install-skill.sh [options]
#
# Options:
#   --repo-root PATH       Humanize repo root (default: auto-detect)
#   --target MODE          kimi|codex|both (default: kimi)
#   --skills-dir PATH      Legacy alias for target skills dir (kept for compatibility)
#   --kimi-skills-dir PATH Kimi skills dir (default: ~/.config/agents/skills)
#   --codex-skills-dir PATH Codex skills dir (default: ${CODEX_HOME:-~/.codex}/skills)
#   --humanize-root PATH   Value to write into HUMANIZE_ROOT (default: repo root)
#   --profile PATH         Profile file to update (default: auto-detect by shell)
#   --no-persist           Do not modify profile; print export command only
#   --dry-run              Print actions without writing
#   -h, --help             Show help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="kimi"
KIMI_SKILLS_DIR="${HOME}/.config/agents/skills"
CODEX_SKILLS_DIR="${CODEX_HOME:-${HOME}/.codex}/skills"
LEGACY_SKILLS_DIR=""
HUMANIZE_ROOT="$REPO_ROOT"
PROFILE_FILE=""
PERSIST_PROFILE="true"
DRY_RUN="false"

SKILL_NAMES=(
    "humanize"
    "humanize-gen-plan"
    "humanize-rlcr"
)

usage() {
    cat <<'EOF'
Install Humanize skills for Kimi and/or Codex.

Usage:
  scripts/install-skill.sh [options]

Options:
  --target MODE          kimi|codex|both (default: kimi)
  --repo-root PATH       Humanize repo root (default: auto-detect)
  --skills-dir PATH      Legacy alias for target skills dir (compat)
  --kimi-skills-dir PATH Kimi skills dir (default: ~/.config/agents/skills)
  --codex-skills-dir PATH Codex skills dir (default: ${CODEX_HOME:-~/.codex}/skills)
  --humanize-root PATH   Value to write into HUMANIZE_ROOT (default: repo root)
  --profile PATH         Profile file to update (default: auto-detect by shell)
  --no-persist           Do not modify profile; print export command only
  --dry-run              Print actions without writing
  -h, --help             Show help
EOF
}

log() {
    printf '[install-skills] %s\n' "$*"
}

die() {
    printf '[install-skills] Error: %s\n' "$*" >&2
    exit 1
}

detect_profile() {
    local shell_name
    shell_name="$(basename "${SHELL:-}")"
    case "$shell_name" in
        zsh) echo "${HOME}/.zshrc" ;;
        bash) echo "${HOME}/.bashrc" ;;
        *) echo "${HOME}/.profile" ;;
    esac
}

validate_repo() {
    [[ -d "$REPO_ROOT/skills" ]] || die "skills directory not found under repo root: $REPO_ROOT"
    [[ -d "$REPO_ROOT/scripts" ]] || die "scripts directory not found under repo root: $REPO_ROOT"
    for skill in "${SKILL_NAMES[@]}"; do
        [[ -f "$REPO_ROOT/skills/$skill/SKILL.md" ]] || die "missing $REPO_ROOT/skills/$skill/SKILL.md"
    done
}

sync_one_skill() {
    local skill="$1"
    local target_dir="$2"
    local src="$REPO_ROOT/skills/$skill"
    local dst="$target_dir/$skill"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN sync $src -> $dst"
        return
    fi

    mkdir -p "$dst"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$src/" "$dst/"
    else
        rm -rf "$dst"
        mkdir -p "$dst"
        cp -a "$src/." "$dst/"
    fi
}

sync_target() {
    local label="$1"
    local target_dir="$2"

    log "target: $label"
    log "skills dir: $target_dir"

    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$target_dir"
    fi

    for skill in "${SKILL_NAMES[@]}"; do
        log "syncing [$label] skill: $skill"
        sync_one_skill "$skill" "$target_dir"
    done
}

update_profile() {
    local profile="$1"
    local value="$2"
    local begin="# >>> humanize-kimi >>>"
    local end="# <<< humanize-kimi <<<"
    local tmp
    tmp="$(mktemp)"

    if [[ ! -f "$profile" ]]; then
        [[ "$DRY_RUN" == "true" ]] || touch "$profile"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN update profile block in $profile"
        return
    fi

    # Remove existing managed block, if any.
    awk -v begin="$begin" -v end="$end" '
        BEGIN { in_block=0 }
        $0 == begin { in_block=1; next }
        $0 == end { in_block=0; next }
        in_block == 0 { print }
    ' "$profile" > "$tmp"

    {
        cat "$tmp"
        echo ""
        echo "$begin"
        echo "export HUMANIZE_ROOT=\"$value\""
        echo "$end"
    } > "$profile"

    rm -f "$tmp"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            [[ -n "${2:-}" ]] || die "--target requires a value"
            case "$2" in
                kimi|codex|both) TARGET="$2" ;;
                *) die "--target must be one of: kimi, codex, both" ;;
            esac
            shift 2
            ;;
        --repo-root)
            [[ -n "${2:-}" ]] || die "--repo-root requires a value"
            REPO_ROOT="$2"
            shift 2
            ;;
        --skills-dir)
            [[ -n "${2:-}" ]] || die "--skills-dir requires a value"
            LEGACY_SKILLS_DIR="$2"
            shift 2
            ;;
        --kimi-skills-dir)
            [[ -n "${2:-}" ]] || die "--kimi-skills-dir requires a value"
            KIMI_SKILLS_DIR="$2"
            shift 2
            ;;
        --codex-skills-dir)
            [[ -n "${2:-}" ]] || die "--codex-skills-dir requires a value"
            CODEX_SKILLS_DIR="$2"
            shift 2
            ;;
        --humanize-root)
            [[ -n "${2:-}" ]] || die "--humanize-root requires a value"
            HUMANIZE_ROOT="$2"
            shift 2
            ;;
        --profile)
            [[ -n "${2:-}" ]] || die "--profile requires a value"
            PROFILE_FILE="$2"
            shift 2
            ;;
        --no-persist)
            PERSIST_PROFILE="false"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
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

validate_repo

if [[ -n "$LEGACY_SKILLS_DIR" ]]; then
    case "$TARGET" in
        kimi) KIMI_SKILLS_DIR="$LEGACY_SKILLS_DIR" ;;
        codex) CODEX_SKILLS_DIR="$LEGACY_SKILLS_DIR" ;;
        both)
            KIMI_SKILLS_DIR="$LEGACY_SKILLS_DIR"
            CODEX_SKILLS_DIR="$LEGACY_SKILLS_DIR"
            ;;
    esac
fi

PROFILE_FILE="${PROFILE_FILE:-$(detect_profile)}"

log "repo root: $REPO_ROOT"
log "target: $TARGET"
if [[ "$TARGET" == "kimi" || "$TARGET" == "both" ]]; then
    log "kimi skills dir: $KIMI_SKILLS_DIR"
fi
if [[ "$TARGET" == "codex" || "$TARGET" == "both" ]]; then
    log "codex skills dir: $CODEX_SKILLS_DIR"
fi
log "HUMANIZE_ROOT: $HUMANIZE_ROOT"
log "profile: $PROFILE_FILE"

case "$TARGET" in
    kimi)
        sync_target "kimi" "$KIMI_SKILLS_DIR"
        ;;
    codex)
        sync_target "codex" "$CODEX_SKILLS_DIR"
        ;;
    both)
        sync_target "kimi" "$KIMI_SKILLS_DIR"
        sync_target "codex" "$CODEX_SKILLS_DIR"
        ;;
esac

# Export for current process
export HUMANIZE_ROOT="$HUMANIZE_ROOT"

if [[ "$PERSIST_PROFILE" == "true" ]]; then
    update_profile "$PROFILE_FILE" "$HUMANIZE_ROOT"
    if [[ "$DRY_RUN" == "true" ]]; then
        log "would update profile: $PROFILE_FILE"
    else
        log "updated profile: $PROFILE_FILE"
    fi
else
    log "profile update skipped (--no-persist)"
fi

cat <<EOF

Done.

Skills synced:
EOF

if [[ "$TARGET" == "kimi" || "$TARGET" == "both" ]]; then
    cat <<EOF
  - kimi:  $KIMI_SKILLS_DIR
EOF
fi

if [[ "$TARGET" == "codex" || "$TARGET" == "both" ]]; then
    cat <<EOF
  - codex: $CODEX_SKILLS_DIR
EOF
fi

cat <<EOF

HUMANIZE_ROOT:
  $HUMANIZE_ROOT

EOF

if [[ "$PERSIST_PROFILE" == "true" ]]; then
    cat <<EOF
To apply profile changes in current shell:
  source "$PROFILE_FILE"
EOF
else
    cat <<EOF
To apply in current shell (profile unchanged):
  export HUMANIZE_ROOT="$HUMANIZE_ROOT"
EOF
fi

cat <<EOF

Manual commands to set HUMANIZE_ROOT:

export HUMANIZE_ROOT="$HUMANIZE_ROOT"

zsh:
  echo 'export HUMANIZE_ROOT="$HUMANIZE_ROOT"' >> ~/.zshrc
  source ~/.zshrc

bash:
  echo 'export HUMANIZE_ROOT="$HUMANIZE_ROOT"' >> ~/.bashrc
  source ~/.bashrc
EOF
