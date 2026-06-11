#!/usr/bin/env bash
#
# Install/upgrade KernelPilot Humanize for Claude Code.
#
# Claude Code plugin installation copies the plugin into ~/.claude/plugins/cache
# but does not hydrate SKILL.md placeholders. This wrapper performs the normal
# marketplace install, exposes KernelWiki and ncu-report-skill as Claude skills,
# hydrates the installed plugin cache, and verifies the result.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HUMANIZE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KERNELPILOT_ROOT="$(cd "$HUMANIZE_ROOT/.." && pwd)"
KERNELWIKI_ROOT="${KERNELWIKI_ROOT:-}"
NCU_REPORT_SKILL_ROOT="${NCU_REPORT_SKILL_ROOT:-}"
# Optional Ascend NPU skills. Absent on NVIDIA-only checkouts (soft-resolved).
ASCENDWIKI_ROOT="${ASCENDWIKI_ROOT:-}"
MSPROF_SKILL_ROOT="${MSPROF_SKILL_ROOT:-}"
CLAUDE_BIN="${CLAUDE_BIN:-}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
INSTALL_PIP="true"
DISABLE_POLYARCH="true"
DRY_RUN="false"

usage() {
    cat <<'EOF'
Install KernelPilot Humanize for Claude Code.

Usage:
  humanize/scripts/install-skills-claude.sh [options]

Options:
  --kernelpilot-root PATH     KernelPilot checkout root (default: auto-detect)
  --kernelwiki-root PATH      KernelWiki checkout root (default: external/KernelWiki)
  --ncu-report-skill-root PATH
                              ncu-report-skill checkout root (default: external/ncu-report-skill)
  --ascendwiki-root PATH      AscendWiki checkout root (optional; default: external/AscendWiki)
  --msprof-skill-root PATH    msprof-report-skill checkout root (optional; default: external/msprof-report-skill)
  --claude-bin PATH           Claude Code binary (default: claude or ~/.local/bin/claude)
  --claude-config-dir PATH    Claude config dir (default: ~/.claude)
  --skip-pip                  Do not run pip install for KernelWiki requirements
  --keep-polyarch-enabled     Do not disable an existing humanize@PolyArch install
  --dry-run                   Print actions without writing
  -h, --help                  Show this help
EOF
}

log() {
    printf '[install-claude-skills] %s\n' "$*"
}

die() {
    printf '[install-claude-skills] Error: %s\n' "$*" >&2
    exit 1
}

resolve_claude_bin() {
    if [[ -n "$CLAUDE_BIN" ]]; then
        [[ -x "$CLAUDE_BIN" ]] || die "Claude binary is not executable: $CLAUDE_BIN"
        return
    fi
    if command -v claude >/dev/null 2>&1; then
        CLAUDE_BIN="$(command -v claude)"
        return
    fi
    if [[ -x "${HOME}/.local/bin/claude" ]]; then
        CLAUDE_BIN="${HOME}/.local/bin/claude"
        return
    fi
    die "Claude Code CLI not found; pass --claude-bin PATH"
}

plugin_version() {
    python3 - "$HUMANIZE_ROOT/.claude-plugin/plugin.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
print(json.loads(path.read_text(encoding="utf-8"))["version"])
PY
}

hydrate_plugin_cache() {
    local plugin_root="$1"

    [[ -d "$plugin_root/skills" ]] || die "installed plugin skills not found: $plugin_root/skills"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN hydrate skills under $plugin_root/skills"
        return
    fi

    python3 - "$plugin_root" "$KERNELPILOT_ROOT" "$KERNELWIKI_ROOT" "$NCU_REPORT_SKILL_ROOT" "$ASCENDWIKI_ROOT" "$MSPROF_SKILL_ROOT" <<'PY'
import pathlib
import sys

plugin_root = pathlib.Path(sys.argv[1])
kernelpilot_root = pathlib.Path(sys.argv[2])
kernelwiki_root = pathlib.Path(sys.argv[3])
ncu_report_skill_root = pathlib.Path(sys.argv[4])
ascendwiki_root = sys.argv[5]
msprof_skill_root = sys.argv[6]

replacements = {
    "{{HUMANIZE_RUNTIME_ROOT}}": str(plugin_root),
    "{{KERNELPILOT_ROOT}}": str(kernelpilot_root),
    "{{KERNELWIKI_ROOT}}": str(kernelwiki_root),
    "{{NCU_REPORT_SKILL_ROOT}}": str(ncu_report_skill_root),
}

# Ascend roots are optional; only register replacements when resolved so an
# NVIDIA-only install leaves the Ascend skill's placeholders untouched (and the
# Ascend loop skill, if present, still hydrates cleanly).
if ascendwiki_root:
    replacements["{{ASCENDWIKI_ROOT}}"] = ascendwiki_root
if msprof_skill_root:
    replacements["{{MSPROF_SKILL_ROOT}}"] = msprof_skill_root

for path in sorted((plugin_root / "skills").glob("*/SKILL*.md")):
    text = path.read_text(encoding="utf-8")
    updated = text
    for old, new in replacements.items():
        updated = updated.replace(old, new)
    if updated != text:
        path.write_text(updated, encoding="utf-8")
PY
}

verify_no_placeholders() {
    local plugin_root="$1"

    if grep -R '{{HUMANIZE_RUNTIME_ROOT}}\|{{KERNELPILOT_ROOT}}\|{{KERNELWIKI_ROOT}}\|{{NCU_REPORT_SKILL_ROOT}}' "$plugin_root/skills" >/dev/null 2>&1; then
        grep -R -n '{{HUMANIZE_RUNTIME_ROOT}}\|{{KERNELPILOT_ROOT}}\|{{KERNELWIKI_ROOT}}\|{{NCU_REPORT_SKILL_ROOT}}' "$plugin_root/skills" >&2 || true
        die "unhydrated placeholders remain in Claude plugin skills"
    fi
}

sync_plugin_cache_from_source() {
    local plugin_root="$1"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN sync local plugin source into $plugin_root"
        return
    fi

    mkdir -p "$plugin_root"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete --exclude '.git' "$HUMANIZE_ROOT/" "$plugin_root/"
    else
        local tmp_root
        tmp_root="$(mktemp -d "$(dirname "$plugin_root")/.plugin_sync_tmp.XXXXXX")"
        if cp -a "$HUMANIZE_ROOT/." "$tmp_root/"; then
            rm -rf "$tmp_root/.git"
            rm -rf "$plugin_root"
            mv "$tmp_root" "$plugin_root"
        else
            rm -rf "$tmp_root"
            die "failed to copy local plugin source into $plugin_root"
        fi
    fi
}

link_skill() {
    local skill_name="$1"
    local target="$2"
    local skills_dir="$CLAUDE_CONFIG_DIR/skills"
    local link_path="$skills_dir/$skill_name"

    [[ -f "$target/SKILL.md" ]] || die "$skill_name skill not found: $target/SKILL.md"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN link $link_path -> $target"
        return
    fi

    mkdir -p "$skills_dir"
    if [[ -L "$link_path" ]]; then
        rm "$link_path"
    elif [[ -e "$link_path" ]]; then
        die "$link_path exists and is not a symlink; move it aside before reinstalling"
    fi
    ln -s "$target" "$link_path"
}

resolve_external_skill_roots() {
    if [[ -z "$KERNELWIKI_ROOT" ]]; then
        KERNELWIKI_ROOT="$KERNELPILOT_ROOT/external/KernelWiki"
    fi
    if [[ -z "$NCU_REPORT_SKILL_ROOT" ]]; then
        NCU_REPORT_SKILL_ROOT="$KERNELPILOT_ROOT/external/ncu-report-skill"
    fi

    KERNELWIKI_ROOT="$(cd "$KERNELWIKI_ROOT" 2>/dev/null && pwd || true)"
    NCU_REPORT_SKILL_ROOT="$(cd "$NCU_REPORT_SKILL_ROOT" 2>/dev/null && pwd || true)"

    [[ -n "$KERNELWIKI_ROOT" ]] || die "could not resolve KernelWiki root"
    [[ -f "$KERNELWIKI_ROOT/SKILL.md" ]] || die "KernelWiki skill not found: $KERNELWIKI_ROOT/SKILL.md"
    [[ -f "$KERNELWIKI_ROOT/scripts/query.py" ]] || die "KernelWiki query script not found: $KERNELWIKI_ROOT/scripts/query.py"
    [[ -d "$KERNELWIKI_ROOT/sources/prs" ]] || die "KernelWiki PR pages not found: $KERNELWIKI_ROOT/sources/prs"
    [[ -n "$NCU_REPORT_SKILL_ROOT" ]] || die "could not resolve ncu-report-skill root"
    [[ -f "$NCU_REPORT_SKILL_ROOT/SKILL.md" ]] || die "ncu-report-skill not found: $NCU_REPORT_SKILL_ROOT/SKILL.md"
    [[ -d "$NCU_REPORT_SKILL_ROOT/reference" ]] || die "ncu-report-skill reference docs not found: $NCU_REPORT_SKILL_ROOT/reference"

    # Ascend skills are OPTIONAL. Default to the external checkout, soft-resolve,
    # and warn (do not die) when absent so NVIDIA-only installs still succeed.
    if [[ -z "$ASCENDWIKI_ROOT" ]]; then
        ASCENDWIKI_ROOT="$KERNELPILOT_ROOT/external/AscendWiki"
    fi
    if [[ -z "$MSPROF_SKILL_ROOT" ]]; then
        MSPROF_SKILL_ROOT="$KERNELPILOT_ROOT/external/msprof-report-skill"
    fi
    ASCENDWIKI_ROOT="$(cd "$ASCENDWIKI_ROOT" 2>/dev/null && pwd || true)"
    MSPROF_SKILL_ROOT="$(cd "$MSPROF_SKILL_ROOT" 2>/dev/null && pwd || true)"
    if [[ -z "$ASCENDWIKI_ROOT" || ! -f "$ASCENDWIKI_ROOT/SKILL.md" ]]; then
        log "[warn] AscendWiki not found; skipping (Ascend NPU skills disabled)"
        ASCENDWIKI_ROOT=""
    fi
    if [[ -z "$MSPROF_SKILL_ROOT" || ! -f "$MSPROF_SKILL_ROOT/SKILL.md" ]]; then
        log "[warn] msprof-report-skill not found; skipping (Ascend NPU skills disabled)"
        MSPROF_SKILL_ROOT=""
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernelpilot-root)
            [[ -n "${2:-}" ]] || die "--kernelpilot-root requires a value"
            KERNELPILOT_ROOT="$2"
            shift 2
            ;;
        --kernelwiki-root)
            [[ -n "${2:-}" ]] || die "--kernelwiki-root requires a value"
            KERNELWIKI_ROOT="$2"
            shift 2
            ;;
        --ncu-report-skill-root)
            [[ -n "${2:-}" ]] || die "--ncu-report-skill-root requires a value"
            NCU_REPORT_SKILL_ROOT="$2"
            shift 2
            ;;
        --ascendwiki-root)
            [[ -n "${2:-}" ]] || die "--ascendwiki-root requires a value"
            ASCENDWIKI_ROOT="$2"
            shift 2
            ;;
        --msprof-skill-root)
            [[ -n "${2:-}" ]] || die "--msprof-skill-root requires a value"
            MSPROF_SKILL_ROOT="$2"
            shift 2
            ;;
        --claude-bin)
            [[ -n "${2:-}" ]] || die "--claude-bin requires a value"
            CLAUDE_BIN="$2"
            shift 2
            ;;
        --claude-config-dir)
            [[ -n "${2:-}" ]] || die "--claude-config-dir requires a value"
            CLAUDE_CONFIG_DIR="$2"
            shift 2
            ;;
        --skip-pip)
            INSTALL_PIP="false"
            shift
            ;;
        --keep-polyarch-enabled)
            DISABLE_POLYARCH="false"
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

KERNELPILOT_ROOT="$(cd "$KERNELPILOT_ROOT" 2>/dev/null && pwd || true)"
[[ -n "$KERNELPILOT_ROOT" ]] || die "could not resolve KernelPilot root"
[[ -f "$KERNELPILOT_ROOT/.claude-plugin/marketplace.json" ]] || die "KernelPilot marketplace not found: $KERNELPILOT_ROOT/.claude-plugin/marketplace.json"
resolve_external_skill_roots

resolve_claude_bin
VERSION="$(plugin_version)"
PLUGIN_ROOT="$CLAUDE_CONFIG_DIR/plugins/cache/KernelPilot/humanize/$VERSION"

log "kernelpilot root: $KERNELPILOT_ROOT"
log "kernelwiki root: $KERNELWIKI_ROOT"
log "ncu-report-skill root: $NCU_REPORT_SKILL_ROOT"
log "ascendwiki root: ${ASCENDWIKI_ROOT:-<disabled>}"
log "msprof-report-skill root: ${MSPROF_SKILL_ROOT:-<disabled>}"
log "claude binary: $CLAUDE_BIN"
log "claude config dir: $CLAUDE_CONFIG_DIR"
log "plugin cache root: $PLUGIN_ROOT"

if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN claude plugin marketplace add ./"
    log "DRY-RUN claude plugin install humanize@KernelPilot"
else
    (
        cd "$KERNELPILOT_ROOT"
        "$CLAUDE_BIN" plugin marketplace add ./ >/dev/null 2>&1 || "$CLAUDE_BIN" plugin marketplace update KernelPilot
        "$CLAUDE_BIN" plugin install humanize@KernelPilot >/dev/null 2>&1 || "$CLAUDE_BIN" plugin update humanize@KernelPilot
    )
fi

if [[ "$DISABLE_POLYARCH" == "true" && "$DRY_RUN" != "true" ]]; then
    "$CLAUDE_BIN" plugin disable humanize@PolyArch >/dev/null 2>&1 || true
fi

sync_plugin_cache_from_source "$PLUGIN_ROOT"
link_skill "KernelWiki" "$KERNELWIKI_ROOT"
link_skill "ncu-report-skill" "$NCU_REPORT_SKILL_ROOT"
if [[ -n "$ASCENDWIKI_ROOT" ]]; then link_skill "AscendWiki" "$ASCENDWIKI_ROOT"; fi
if [[ -n "$MSPROF_SKILL_ROOT" ]]; then link_skill "msprof-report-skill" "$MSPROF_SKILL_ROOT"; fi

if [[ "$INSTALL_PIP" == "true" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN python3 -m pip install -r $KERNELWIKI_ROOT/requirements.txt"
    else
        python3 -m pip install -r "$KERNELWIKI_ROOT/requirements.txt"
    fi
fi

hydrate_plugin_cache "$PLUGIN_ROOT"

if [[ "$DRY_RUN" != "true" ]]; then
    verify_no_placeholders "$PLUGIN_ROOT"
    "$CLAUDE_BIN" plugin details humanize@KernelPilot >/dev/null
fi

EXTERNAL_SKILLS_SUMMARY="  $CLAUDE_CONFIG_DIR/skills/KernelWiki -> $KERNELWIKI_ROOT
  $CLAUDE_CONFIG_DIR/skills/ncu-report-skill -> $NCU_REPORT_SKILL_ROOT"
if [[ -n "$ASCENDWIKI_ROOT" ]]; then
    EXTERNAL_SKILLS_SUMMARY="$EXTERNAL_SKILLS_SUMMARY
  $CLAUDE_CONFIG_DIR/skills/AscendWiki -> $ASCENDWIKI_ROOT"
fi
if [[ -n "$MSPROF_SKILL_ROOT" ]]; then
    EXTERNAL_SKILLS_SUMMARY="$EXTERNAL_SKILLS_SUMMARY
  $CLAUDE_CONFIG_DIR/skills/msprof-report-skill -> $MSPROF_SKILL_ROOT"
fi

cat <<EOF

Done.

Claude Code plugin:
  humanize@KernelPilot $VERSION

Hydrated runtime root:
  $PLUGIN_ROOT

External skills:
$EXTERNAL_SKILLS_SUMMARY
EOF
