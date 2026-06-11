#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KERNELPILOT_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)"

kernelwiki_dir="$KERNELPILOT_ROOT/external/KernelWiki"
ncu_skill_dir="$KERNELPILOT_ROOT/external/ncu-report-skill"
install_script="$PROJECT_ROOT/scripts/install-skill.sh"
claude_install_script="$PROJECT_ROOT/scripts/install-skills-claude.sh"
kernel_skill="$PROJECT_ROOT/skills/humanize-kernel-agent-loop/SKILL.md"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "$kernelwiki_dir/SKILL.md" ]] || fail "missing KernelWiki skill"
[[ -f "$kernelwiki_dir/scripts/query.py" ]] || fail "missing KernelWiki query helper"
[[ -d "$kernelwiki_dir/sources/prs" ]] || fail "missing KernelWiki PR pages"
[[ -d "$kernelwiki_dir/artifacts/prs" ]] || fail "missing KernelWiki PR artifacts"
[[ -f "$kernelwiki_dir/queries/by-repo.md" ]] || fail "missing KernelWiki query indices"

[[ -f "$ncu_skill_dir/SKILL.md" ]] || fail "missing ncu-report-skill"
[[ -f "$ncu_skill_dir/reference/01-workflow.md" ]] || fail "missing ncu-report-skill workflow reference"
[[ -f "$ncu_skill_dir/reference/08-b200-metric-names.md" ]] || fail "missing ncu-report-skill B200 metric reference"
[[ -f "$ncu_skill_dir/helpers/analyze_reports.py" ]] || fail "missing ncu-report-skill analyzer helper"
[[ -f "$ncu_skill_dir/helpers/ncu_utils.py" ]] || fail "missing ncu-report-skill shared helper"

grep -q 'KERNELWIKI_ROOT' "$install_script" \
    || fail "install script does not hydrate KernelWiki root"
grep -q 'NCU_REPORT_SKILL_ROOT' "$install_script" \
    || fail "install script does not hydrate ncu-report-skill root"
grep -q 'sync_kernelwiki_skill' "$install_script" \
    || fail "install script does not sync KernelWiki"
grep -q 'sync_ncu_report_skill' "$install_script" \
    || fail "install script does not sync ncu-report-skill"
grep -q 'KernelWiki' "$claude_install_script" \
    || fail "Claude installer does not link KernelWiki"
grep -q 'ncu-report-skill' "$claude_install_script" \
    || fail "Claude installer does not link ncu-report-skill"

grep -q 'KernelWiki' "$kernel_skill" \
    || fail "kernel agent loop does not call KernelWiki"
grep -q 'ncu-report-skill' "$kernel_skill" \
    || fail "kernel agent loop does not call ncu-report-skill"
grep -q '{{KERNELWIKI_ROOT}}' "$kernel_skill" \
    || fail "kernel agent loop does not expose KernelWiki root"
grep -q '{{NCU_REPORT_SKILL_ROOT}}' "$kernel_skill" \
    || fail "kernel agent loop does not expose ncu-report-skill root"

python3 -m py_compile \
    "$kernelwiki_dir/scripts/query.py" \
    "$kernelwiki_dir/scripts/get_page.py" \
    "$ncu_skill_dir/helpers/analyze_reports.py" \
    "$ncu_skill_dir/helpers/extract_stall_hotspots.py"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
"$install_script" --target codex \
    --codex-skills-dir "$tmp_dir/skills" \
    --codex-config-dir "$tmp_dir/codex" \
    --command-bin-dir "$tmp_dir/bin" \
    --dry-run >/dev/null

echo "PASS: KernelWiki and ncu-report-skill are wired"
