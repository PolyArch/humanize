# Install Humanize for Claude Code

## Prerequisites

- [codex](https://github.com/openai/codex) -- OpenAI Codex CLI (for review). Verify with `codex --version`.
- `jq` -- JSON processor. Verify with `jq --version`.
- `git` -- Git version control. Verify with `git --version`.
- `tmux` -- Optional, required only for Codex Goal with Claude Review monitoring.

## Option 1: Git Marketplace (Recommended)

Start Claude Code and run:

```bash
# Add the marketplace
/plugin marketplace add git@github.com:PolyArch/humanize.git

# Install the plugin
/plugin install humanize@PolyArch
```

## Option 2: Local Development

If you have the plugin cloned locally:

```bash
claude --plugin-dir /path/to/humanize
```

## Option 3: Try Experimental Features (dev branch)

The `dev` branch contains experimental features that are not yet released to `main`. To try them locally:

```bash
git clone https://github.com/PolyArch/humanize.git
cd humanize
git checkout dev
```

Then start Claude Code with the local plugin directory:

```bash
claude --plugin-dir /path/to/humanize
```

Note: The `dev` branch may contain unstable or incomplete features. For production use, stick with Option 1 (Git Marketplace) which tracks the stable `main` branch.

## Verify Installation

After installing, you should see Humanize commands available:

```
/humanize:start-rlcr-loop
/humanize:gen-plan
/humanize:refine-plan
/humanize:ask-codex
/humanize:cgcr
/humanize:monitor-codex-goal
```

`/humanize:cgcr` is the public CGCR command name. The lower-level
`/humanize:monitor-codex-goal` command belongs to the same workflow: Codex
`/goal` implements while Claude Code monitors as a read-only reviewer. CGCR is
not RLCR. The Codex side uses `/goal`, `/flow:humanize-codex-goal`, or
`/flow:humanize-cgcr` for the two-tmux topology.

## Monitor Setup (Optional)

Add the monitoring helper to your shell for real-time progress tracking:

```bash
# Add to your .bashrc or .zshrc
source ~/.claude/plugins/cache/PolyArch/humanize/<LATEST.VERSION>/scripts/humanize.sh
```

Then use:

```bash
humanize monitor rlcr   # Monitor RLCR loop
```

## Optional: Codex Goal with Claude Review

CGCR reverses the RLCR roles:

- RLCR: `/humanize:start-rlcr-loop` means Claude Code implements and Codex reviews.
- CGCR: `/humanize:cgcr` means Codex `/goal` implements and Claude Code reviews.

Recommended first monitor run:

```text
/humanize:cgcr --discover --notify-only
```

For the simpler end-to-end startup, install Humanize for Codex and run
`/flow:humanize-cgcr <long task prompt>` from Codex. That flow creates the
Codex and Claude monitor tmux windows and prepares both prompts.

The Claude monitor must stay read-only except for gated `[MONITOR]` tmux
injection. See [CGCR](cgcr.md).

## Other Install Guides

- [Install for Codex](install-for-codex.md)
- [Install for Kimi](install-for-kimi.md)

## Next Steps

See the [Usage Guide](usage.md) for detailed command reference and configuration options.
