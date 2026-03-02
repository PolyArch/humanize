# Install Humanize Skills for Codex

This guide explains how to install the Humanize skills for Codex skill runtime (`$CODEX_HOME/skills`).

## Quick Install (Recommended)

From the Humanize repo root:

```bash
./scripts/install-skills-codex.sh
```

Or use the unified installer directly:

```bash
./scripts/install-skill.sh --target codex
```

This will:
- Sync `humanize`, `humanize-gen-plan`, and `humanize-rlcr` into `${CODEX_HOME:-~/.codex}/skills`
- Configure `HUMANIZE_ROOT` in your shell profile
- Use RLCR defaults: `codex exec` with `gpt-5.2:xhigh`, `codex review` with `gpt-5.2:high`

## Verify

```bash
ls -la "${CODEX_HOME:-$HOME/.codex}/skills"
```

Expected directories:
- `humanize`
- `humanize-gen-plan`
- `humanize-rlcr`

## Optional: Install for Both Codex and Kimi

```bash
./scripts/install-skill.sh --target both
```

## Useful Options

```bash
# Preview without writing
./scripts/install-skills-codex.sh --dry-run

# Custom Codex skills dir
./scripts/install-skills-codex.sh --codex-skills-dir /custom/codex/skills

# Do not edit shell profile
./scripts/install-skills-codex.sh --no-persist
```

## Troubleshooting

If scripts are not found from installed skills:

```bash
echo "$HUMANIZE_ROOT"
ls -la "$HUMANIZE_ROOT/scripts"
```

If `HUMANIZE_ROOT` is wrong, update it in your shell profile and restart your terminal.
