* 🚀 [Humanize2](https://github.com/humanfia/humanize2) is under active developments and we are looking for your feedbacks! 
* ✨ Now humanize has a [cool homepage](https://humanfia.ai/)!

# Humanize

**Current Version: 1.16.0**

> Derived from the [GAAC (GitHub-as-a-Context)](https://github.com/SihaoLiu/gaac) project.

A Claude Code plugin that provides iterative development with independent AI review. Build with confidence through continuous feedback loops.

## What is RLCR?

**RLCR** stands for **Ralph-Loop with Codex Review**, inspired by the official ralph-loop plugin and enhanced with independent Codex review. The name also reads as **Reinforcement Learning with Code Review** -- reflecting the iterative cycle where AI-generated code is continuously refined through external review feedback.

## Optional: Codex Goal with Claude Review

Humanize also supports an optional reverse workflow, **CGCR** (Codex Goal with Claude Review), for cases where Codex `/goal` is the executor and Claude Code is a read-only reviewer/monitor.

- `/humanize:start-rlcr-loop` = Claude Code implements, Codex reviews
- `/humanize:cgcr` = public CGCR command wrapper
- `/humanize:monitor-codex-goal` in Claude Code = lower-level monitor command
- `/goal` or the CGCR goal contract in Codex = execute the CGCR goal
- `$humanize-cgcr` in the Codex terminal = start the two-tmux CGCR topology
- `/flow:humanize-cgcr` = lower-level Codex flow shim used by the launcher

CGCR is additive and does not replace RLCR. See [CGCR](docs/cgcr.md).
It is not a dual-executor system: Claude Code must not implement or repair code
directly in CGCR.

### Install CGCR For Codex

CGCR needs `codex`, `claude`, and `tmux` available on PATH. Install the Codex
runtime from this repository:

```bash
./scripts/install-skills-codex.sh
```

Or install from a fresh clone:

```bash
tmp_dir="$(mktemp -d)" && git clone --depth 1 https://github.com/PolyArch/humanize.git "$tmp_dir/humanize" && "$tmp_dir/humanize/scripts/install-skills-codex.sh"
```

Then restart Codex. The installer registers the local `flow@humanize-local`
plugin and the `$humanize-cgcr` Codex terminal command. Codex loads local
commands only when a new CLI session starts.

Verify:

```bash
ls -la "${CODEX_HOME:-$HOME/.codex}/skills/humanize"
ls -la "${CODEX_HOME:-$HOME/.codex}/skills/humanize-cgcr"
codex plugin list | rg 'flow@humanize-local|humanize-local'
```

### Use CGCR

Open Codex in the target repository. In the **Codex terminal input**, type:

```text
$humanize-cgcr <your long task prompt>
```

Recommended long task prompt format:

```text
Task:
Describe the concrete outcome Codex should deliver.

Tools and skills:
Name required local tools, commands, skills, docs, or services Codex should use.

Key flow:
List the important investigation, implementation, verification, and handoff
steps that must happen in order.

Constraints and stop conditions:
State scope boundaries, forbidden changes, approval points, and when Codex
should stop, ask, or emit closeout instead of continuing.

Notes:
Add repo-specific paths, environment details, known risks, and anything the
Claude monitor should pay attention to.
```

Do not type this inside tmux. This command is the launcher: it creates the tmux
session for you, starts Codex and Claude in separate tmux windows, and submits
the prepared prompts automatically.

If the Codex terminal command is not available, restart Codex after install.
For manual fallback, use the installed launcher directly:

```text
"${CODEX_HOME:-$HOME/.codex}/skills/humanize/scripts/setup-cgcr.sh" --task "<your long task prompt>"
```

In Codex startup context, `$humanize-cgcr` delegates to the installed
`humanize-cgcr` launcher flow. The launcher creates a tmux session with two
windows and a `.humanize/cgcr/<run-id>/` resource directory:

- `codex-goal` runs a generated `start-codex.sh` launcher, which starts Codex
  with the prepared `/goal` prompt.
- `claude-monitor` runs a generated `start-claude.sh` launcher, then starts the
  Claude monitor command.
- `resources.json` records the tmux session, pane targets, launcher files, and
  prompt files.

The command output includes the tmux session name. Attach to inspect the run:

```bash
tmux attach -t <tmux-session>
```

Inside tmux there are two windows: `codex-goal` and `claude-monitor`. Press
`Ctrl-b` then `n` for next window, `p` for previous window, `0` or `1` for a
numbered window, or `w` for the window list.

When the goal is complete, clean up the CGCR tmux session through the run
resource cleanup path:

```bash
"${CODEX_HOME:-$HOME/.codex}/skills/humanize/scripts/cleanup-cgcr.sh" --session <tmux-session>
```

For advanced options such as `--goal-id`, `--session`, `--cadence`,
`--principles`, and `--notify-only`, see [Install for Codex](docs/install-for-codex.md)
and [CGCR](docs/cgcr.md).

## Core Concepts

- **Iteration over Perfection** -- Instead of expecting perfect output in one shot, Humanize leverages continuous feedback loops where issues are caught early and refined incrementally.
- **One Build + One Review** -- Claude implements, Codex independently reviews. No blind spots.
- **Ralph Loop with Swarm Mode** -- Iterative refinement continues until all acceptance criteria are met. Optionally parallelize with Agent Teams.
- **Begin with the End in Mind** -- Before the loop starts, Humanize verifies that *you* understand the plan you are about to execute. The human must remain the architect. ([Details](docs/usage.md#begin-with-the-end-in-mind))

## How It Works

<p align="center">
  <img src="docs/images/rlcr-workflow.svg" alt="RLCR Workflow" width="680"/>
</p>

The loop has two phases: **Implementation** (Claude works, Codex reviews summaries) and **Code Review** (Codex checks code quality with severity markers). Issues feed back into implementation until resolved.


## Install

```bash
# Add PolyArch marketplace
/plugin marketplace add PolyArch/humanize
# If you want to use development branch for experimental features
/plugin marketplace add PolyArch/humanize#dev
# Then install humanize plugin
/plugin install humanize@PolyArch
```

Requires [codex CLI](https://github.com/openai/codex) for review. See the full [Installation Guide](docs/install-for-claude.md) for prerequisites and alternative setup options.

For Codex-side `/flow:*` commands, run the Codex installer
(`./scripts/install-skills-codex.sh`) and restart Codex so the local
`flow@humanize-local` plugin is loaded.

## Quick Start

1. **Generate an idea draft** from a loose thought (optional — skip if you already have a draft):
   ```bash
   /humanize:gen-idea "add undo/redo to the editor"
   ```
   Output goes to `.humanize/ideas/<slug>-<timestamp>.md` by default. Pass a `.md` path to expand existing rough notes. `--n` controls how many parallel directions explore the idea (default 6).

2. **Generate a plan** from your draft:
   ```bash
   /humanize:gen-plan --input draft.md --output docs/plan.md
   ```

3. **Refine an annotated plan** before implementation when reviewers add comments (`CMT:` ... `ENDCMT`, `<cmt>` ... `</cmt>`, or `<comment>` ... `</comment>`):
   ```bash
   /humanize:refine-plan --input docs/plan.md
   ```

4. **Run the loop**:
   ```bash
   /humanize:start-rlcr-loop docs/plan.md
   ```

5. **Consult Gemini** for deep web research (requires Gemini CLI):
   ```bash
   /humanize:ask-gemini What are the latest best practices for X?
   ```

6. **Monitor progress (in another terminal, not inside Claude Code)**:
   ```bash
   source <path/to/humanize>/scripts/humanize.sh # Or just add it into your .bashec or .zshrc
   humanize monitor rlcr       # RLCR loop
   humanize monitor skill      # All skill invocations (codex + gemini)
   humanize monitor codex      # Codex invocations only
   humanize monitor gemini     # Gemini invocations only
   ```

## Monitor Dashboard

<p align="center">
  <img src="docs/images/monitor.png" alt="Humanize Monitor" width="680"/>
</p>

## Documentation

- [Usage Guide](docs/usage.md) -- Commands, options, environment variables
- [CGCR](docs/cgcr.md) -- Canonical Codex Goal with Claude Review workflow
- [Codex Goal with Claude Review](docs/codex-goal-claude-review.md) -- Long-form CGCR workflow notes
- [Install for Claude Code](docs/install-for-claude.md) -- Full installation instructions
- [Install for Codex](docs/install-for-codex.md) -- Codex skill runtime setup
- [Install for Kimi](docs/install-for-kimi.md) -- Kimi CLI skill setup
- [Configuration](docs/usage.md#configuration) -- Shared config hierarchy and override rules
- [Bitter Lesson Workflow](docs/bitlesson.md) -- Project memory, selector routing, and delta validation

## License

MIT

# humanize-cgcr
