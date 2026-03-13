# Humanize

**Current Version: 1.15.0**

> Derived from the [GAAC (GitHub-as-a-Context)](https://github.com/SihaoLiu/gaac) project.

A Claude Code plugin that provides iterative development with independent AI review. Build with confidence through continuous feedback loops.

## What is RLCR?

**RLCR** stands for **Ralph-Loop with Codex Review**, inspired by the official ralph-loop plugin and enhanced with independent Codex review. The name also reads as **Reinforcement Learning with Code Review** -- reflecting the iterative cycle where AI-generated code is continuously refined through external review feedback.

## Core Concepts

- **Iteration over Perfection** -- Instead of expecting perfect output in one shot, Humanize leverages continuous feedback loops where issues are caught early and refined incrementally.
- **One Build + One Review** -- Claude implements, Codex independently reviews. No blind spots.
- **Ralph Loop with Swarm Mode** -- Iterative refinement continues until all acceptance criteria are met. Optionally parallelize with Agent Teams.
- **Begin with the End in Mind** -- Before the loop starts, Humanize verifies that *you* understand the plan you are about to execute. See [No Wishful Coding](#no-wishful-coding) below.

## No Wishful Coding

A common failure mode in AI-assisted development is **wishful coding**: the user feeds a generated plan into an automated loop without truly understanding what it will do, hoping the AI will figure it out. This leads to wasted compute, off-track implementations, and results that nobody asked for.

Humanize takes the position that **the human must remain the architect**. An RLCR loop is a powerful amplifier -- it faithfully executes whatever plan you give it, for better or worse. If you do not understand your own plan, the loop will not save you; it will only burn tokens faster.

To enforce this principle, `start-rlcr-loop` includes a **Plan Understanding Quiz**: a brief, automated pre-flight check that asks you two technical questions about the plan's implementation details. It is not a gate -- you can always choose to proceed -- but it serves as a moment of honest self-assessment:

- **Do you know which components this plan modifies?**
- **Do you understand the technical mechanism it uses?**

If you cannot answer these questions, you probably should not be running the loop yet. Go back, read the plan, and make sure you can explain it to yourself before asking a machine to build it.

For users who have reviewed the plan and want maximum automation, `--yolo` skips the quiz and hands full control to Humanize.

## How It Works

<p align="center">
  <img src="docs/images/rlcr-workflow.svg" alt="RLCR Workflow" width="680"/>
</p>

The loop has two phases: **Implementation** (Claude works, Codex reviews summaries) and **Code Review** (Codex checks code quality with severity markers). Issues feed back into implementation until resolved.

## Install

```bash
# Add humania marketplace
/plugin marketplace add humania-org/humanize
# If you want to use development branch for experimental features
/plugin marketplace add humania-org/humanize#dev
# Then install humanize plugin
/plugin install humanize@humania
```

Requires [codex CLI](https://github.com/openai/codex) for review. See the full [Installation Guide](docs/install-for-claude.md) for prerequisites and alternative setup options.

## Quick Start

1. **Generate a plan** from your draft:
   ```bash
   /humanize:gen-plan --input draft.md --output docs/plan.md
   ```

2. **Run the loop**:
   ```bash
   /humanize:start-rlcr-loop docs/plan.md
   ```

3. **Monitor progress**:
   ```bash
   source <path/to/humanize>/scripts/humanize.sh
   humanize monitor rlcr
   ```

## Monitor Dashboard

<p align="center">
  <img src="docs/images/monitor.png" alt="Humanize Monitor" width="680"/>
</p>

## Documentation

- [Usage Guide](docs/usage.md) -- Commands, options, environment variables
- [Install for Claude Code](docs/install-for-claude.md) -- Full installation instructions
- [Install for Codex](docs/install-for-codex.md) -- Codex skill runtime setup
- [Install for Kimi](docs/install-for-kimi.md) -- Kimi CLI skill setup
- [Configuration](docs/usage.md#configuration) -- Shared config hierarchy and override rules
- [Bitter Lesson Workflow](docs/bitlesson.md) -- Project memory, selector routing, and delta validation

## License

MIT
