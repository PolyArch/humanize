# Install Humanize Skills for Codex

This guide explains how to install KernelPilot's Humanize bundle for Codex CLI,
including the skill runtime (`$CODEX_HOME/skills`), external KernelWiki /
ncu-report-skill skills, and the native Codex `Stop` hook
(`$CODEX_HOME/hooks.json`).

## Quick Install (Recommended)

One-line install from anywhere:

```bash
tmp_dir="$(mktemp -d)" && git clone --recurse-submodules https://github.com/BBuf/kernel-pilot.git "$tmp_dir/kernel-pilot" && "$tmp_dir/kernel-pilot/humanize/scripts/install-skills-codex.sh"
```

From the KernelPilot repo root:

```bash
humanize/scripts/install-skills-codex.sh
```

Or use the unified installer directly:

```bash
humanize/scripts/install-skill.sh --target codex
```

This will:
- Sync `humanize`, `humanize-gen-plan`, `humanize-refine-plan`,
  `humanize-rlcr`, `humanize-kernel-agent-loop`, `KernelWiki`, and
  `ncu-report-skill` into `${CODEX_HOME:-~/.codex}/skills`
- Copy runtime dependencies into `${CODEX_HOME:-~/.codex}/skills/humanize`
- Install/update native Humanize Stop hooks in `${CODEX_HOME:-~/.codex}/hooks.json`
- Enable the native `hooks` feature in `${CODEX_HOME:-~/.codex}/config.toml` when `codex` is available
- Seed `~/.config/humanize/config.json` with a Codex/OpenAI `bitlesson_model` when that key is not already set
- Mark that target's runtime config as `provider_mode: "codex-only"` when
  using `--target codex`, so helper model routing stays on the Codex/OpenAI
  path for that Codex installation.
- Use RLCR defaults: `codex exec` with `gpt-5.5:high`, `codex review` with `gpt-5.5:high`

Requires Codex CLI `0.114.0` or newer for native hooks. The hooks feature was renamed to `hooks`; older Codex builds that still expose `codex_hooks` are not supported by the Codex install path.

## Verify

```bash
ls -la "${CODEX_HOME:-$HOME/.codex}/skills"
```

Expected directories:
- `humanize`
- `humanize-gen-plan`
- `humanize-refine-plan`
- `humanize-rlcr`
- `humanize-kernel-agent-loop`
- `KernelWiki`
- `ncu-report-skill`

Runtime dependencies in `humanize/`:
- `scripts/`
- `hooks/`
- `prompt-template/`
- `templates/`
- `config/`
- `agents/`

Installed files/directories:
- `${CODEX_HOME:-~/.codex}/skills/humanize/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/humanize-gen-plan/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/humanize-refine-plan/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/humanize-rlcr/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/humanize-kernel-agent-loop/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/KernelWiki/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/ncu-report-skill/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/humanize/scripts/`
- `${CODEX_HOME:-~/.codex}/skills/humanize/hooks/`
- `${CODEX_HOME:-~/.codex}/skills/humanize/prompt-template/`
- `${CODEX_HOME:-~/.codex}/skills/humanize/templates/`
- `${CODEX_HOME:-~/.codex}/skills/humanize/config/`
- `${CODEX_HOME:-~/.codex}/skills/humanize/agents/`
- `${CODEX_HOME:-~/.codex}/hooks.json`
- `${XDG_CONFIG_HOME:-~/.config}/humanize/config.json` (created or updated only when Humanize config keys are unset)

Verify native hooks:

```bash
codex features list | rg '^hooks\s'
sed -n '1,220p' "${CODEX_HOME:-$HOME/.codex}/hooks.json"
```

Expected:
- `hooks` is present in `codex features list`
- `hooks.json` contains `loop-codex-stop-hook.sh`
- `${XDG_CONFIG_HOME:-~/.config}/humanize/config.json` contains `bitlesson_model` set to a Codex/OpenAI model such as `gpt-5.5`
- for `--target codex`, `${XDG_CONFIG_HOME:-~/.config}/humanize/config.json`
  also contains `provider_mode: "codex-only"` for that Codex runtime

## Useful Options

```bash
# Preview without writing
humanize/scripts/install-skills-codex.sh --dry-run

# Custom Codex skills dir
humanize/scripts/install-skills-codex.sh --codex-skills-dir /custom/codex/skills

# Reinstall only the native hooks/config
humanize/scripts/install-codex-hooks.sh
```

## Troubleshooting

If scripts are not found from installed skills:

```bash
ls -la "${CODEX_HOME:-$HOME/.codex}/skills/humanize/scripts"
```

If native exit gating does not trigger:

```bash
codex features enable hooks
sed -n '1,220p' "${CODEX_HOME:-$HOME/.codex}/hooks.json"
```

If the installer reports that your config or installed Codex still uses `codex_hooks`, upgrade Codex first or change `${CODEX_HOME:-~/.codex}/config.toml` to `[features]\nhooks = true`.
