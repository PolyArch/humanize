# Install Humanize Skills for Codex

This guide explains how to install Humanize for Codex CLI, including the skill runtime (`$CODEX_HOME/skills`) and the native Codex `Stop` hook (`$CODEX_HOME/hooks.json`).

## Quick Install (Recommended)

One-line install from anywhere:

```bash
tmp_dir="$(mktemp -d)" && git clone --depth 1 https://github.com/PolyArch/humanize.git "$tmp_dir/humanize" && "$tmp_dir/humanize/scripts/install-skills-codex.sh"
```

From the Humanize repo root:

```bash
./scripts/install-skills-codex.sh
```

Or use the unified installer directly:

```bash
./scripts/install-skill.sh --target codex
```

This will:
- Sync the CGCR-only `humanize` runtime skill and the `humanize-cgcr` launcher
  into `${CODEX_HOME:-~/.codex}/skills`
- Remove stale Humanize Codex skills such as `humanize-gen-plan`,
  `humanize-refine-plan`, `humanize-rlcr`, and `humanize-codex-goal` when they
  were installed by an older Humanize setup
- Copy runtime dependencies into `${CODEX_HOME:-~/.codex}/skills/humanize`
- Install/update native Humanize Stop hooks in `${CODEX_HOME:-~/.codex}/hooks.json`
- Enable the native Codex hooks feature (`hooks` on current Codex, `codex_hooks` on older builds) in `${CODEX_HOME:-~/.codex}/config.toml` when `codex` is available
- Seed `~/.config/humanize/config.json` with a Codex/OpenAI `bitlesson_model` when that key is not already set
- Mark the install as `provider_mode: "codex-only"` when using `--target codex`
- Install the CGCR Codex-side launcher skill, `humanize-cgcr`
- Register the local `flow@humanize-local` Codex plugin so slash commands such
  as `/flow:humanize-cgcr` appear in Codex after restart
- Copy Claude-side `monitor-codex-goal` functionality into the Humanize runtime
  bundle when available so the launcher can start Claude with the plugin
  surface; it is not installed as a Codex executor skill

Requires Codex CLI `0.114.0` or newer for native hooks. Older Codex builds are not supported by the Codex install path.

## Verify

```bash
ls -la "${CODEX_HOME:-$HOME/.codex}/skills"
```

Expected directories:
- `humanize`
- `humanize-cgcr`

Runtime dependencies in `humanize/`:
- `scripts/`
- `hooks/`
- `prompt-template/`
- `templates/`
- `config/`
- `agents/`
- `commands/` and `skills/` when installed from a source checkout, so the
  Codex-side CGCR launcher can start Claude Code with the monitor command

Installed files/directories:
- `${CODEX_HOME:-~/.codex}/skills/humanize/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/humanize-cgcr/SKILL.md`
- `${CODEX_HOME:-~/.codex}/skills/humanize/scripts/`
- `${CODEX_HOME:-~/.codex}/skills/humanize/hooks/`
- `${CODEX_HOME:-~/.codex}/skills/humanize/prompt-template/`
- `${CODEX_HOME:-~/.codex}/skills/humanize/templates/`
- `${CODEX_HOME:-~/.codex}/skills/humanize/config/`
- `${CODEX_HOME:-~/.codex}/skills/humanize/agents/`
- `${CODEX_HOME:-~/.codex}/skills/humanize/commands/monitor-codex-goal.md`
- `${CODEX_HOME:-~/.codex}/skills/humanize/skills/monitor-codex-goal/SKILL.md`
- `${CODEX_HOME:-~/.codex}/marketplaces/humanize-local/plugins/flow/commands/humanize-cgcr.md`
- `${CODEX_HOME:-~/.codex}/hooks.json`
- `${XDG_CONFIG_HOME:-~/.config}/humanize/config.json` (created or updated only when Humanize config keys are unset)

Verify native hooks:

```bash
codex features list | rg '^(hooks|codex_hooks)\s'
sed -n '1,220p' "${CODEX_HOME:-$HOME/.codex}/hooks.json"
codex plugin list | rg 'flow@humanize-local|humanize-local'
```

Expected:
- `hooks` or `codex_hooks` is `true`
- `hooks.json` contains `loop-codex-stop-hook.sh`
- `flow@humanize-local` is installed and enabled
- `${XDG_CONFIG_HOME:-~/.config}/humanize/config.json` contains `bitlesson_model` set to a Codex/OpenAI model such as `gpt-5.5`
- for `--target codex`, `${XDG_CONFIG_HOME:-~/.config}/humanize/config.json` also contains `provider_mode: "codex-only"`

Restart Codex after install or update. Codex loads plugin slash commands when a
new CLI session starts.

## Optional: Install for Both Codex and Kimi

```bash
./scripts/install-skill.sh --target both
```

## Codex Goal with Claude Review

CGCR is the active Codex install mode. Codex `/goal` implements and a separate
Claude Code session monitors with `/humanize:monitor-codex-goal`.

Installer semantics:

- `humanize-cgcr` is installed for the Codex flow/runtime.
- `monitor-codex-goal` is Claude-side monitor functionality.
- `monitor-codex-goal` may be copied into the Humanize runtime bundle or Claude
  plugin surface for the CGCR launcher.
- monitor-codex-goal should not be treated as a Codex executor skill.
- Older RLCR and `humanize-codex-goal` entrypoint skills are intentionally
  removed from this CGCR-only Codex install.

Command distinction:

- In Codex, use `/flow:humanize-cgcr <long task prompt>` to create the
  two-tmux topology and prepared prompts automatically.
- Use `/humanize:cgcr` as the public CGCR command name. The lower-level Claude
  monitor command remains `/humanize:monitor-codex-goal`.

`/flow:*` is not a Codex built-in namespace. The Codex installer registers it
through the local `flow@humanize-local` plugin under
`${CODEX_HOME:-~/.codex}/marketplaces/humanize-local`.

This Codex install is CGCR-only. Do not expect RLCR slash commands or the old
`humanize-codex-goal` flow to be present after reinstall.

## Useful Options

```bash
# Preview without writing
./scripts/install-skills-codex.sh --dry-run

# Custom Codex skills dir
./scripts/install-skills-codex.sh --codex-skills-dir /custom/codex/skills

# Reinstall only the native hooks/config
./scripts/install-codex-hooks.sh
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
