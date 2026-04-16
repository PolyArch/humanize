# Humanize

**Current Version: 1.16.5**

> Derived from the [GAAC (GitHub-as-a-Context)](https://github.com/SihaoLiu/gaac) project.

A Codex-centered workflow for iterative development with independent AI review. Build with confidence through continuous feedback loops.

## What is RLCR?

**RLCR** stands for **Ralph-Loop with Codex Review**, inspired by the official ralph-loop plugin and enhanced with independent Codex review. The name also reads as **Reinforcement Learning with Code Review** -- reflecting the iterative cycle where AI-generated code is continuously refined through external review feedback.

## Core Concepts

- **Iteration over Perfection** -- Instead of expecting perfect output in one shot, Humanize leverages continuous feedback loops where issues are caught early and refined incrementally.
- **One Build + One Review** -- One agent implements, Codex independently reviews. No blind spots.
- **Ralph Loop with Swarm Mode** -- Iterative refinement continues until all acceptance criteria are met. Optionally parallelize with Agent Teams.
- **Begin with the End in Mind** -- Before the loop starts, Humanize verifies that *you* understand the plan you are about to execute. The human must remain the architect. ([Details](docs/usage.md#begin-with-the-end-in-mind))

## How It Works

<p align="center">
  <img src="docs/images/rlcr-workflow.svg" alt="RLCR Workflow" width="680"/>
</p>

The loop has two phases: **Implementation** (the build agent works, Codex reviews summaries) and **Code Review** (Codex checks code quality with severity markers). Issues feed back into implementation until resolved.


## Install

### Codex CLI

```bash
./scripts/install-skills-codex.sh
# Or with the unified installer:
./scripts/install-skill.sh --target codex
```

Requires Codex CLI `0.114.0` or newer. See [Install for Codex](docs/install-for-codex.md) for the full setup and verification steps.

## Quick Start

### Codex Build, Codex Review

Codex implements the code and Codex independently reviews in a fully Codex-native workflow.

In Codex CLI, Humanize flows are invoked by asking Codex to run the installed skill.

1. **Generate a plan** from your draft:
   ```bash
   Run the humanize-gen-plan skill with --input draft.md --output docs/plan.md
   ```

2. **Refine an annotated plan**:
   ```bash
   Run the humanize-refine-plan skill with --input docs/plan.md
   ```

3. **Run the loop**:
   ```bash
   Run the humanize-rlcr skill with --plan-file docs/plan.md
   ```

4. **Consult Gemini** for deep web research (requires Gemini CLI):
   ```bash
   Run the ask-gemini skill with your research question
   ```

### Monitoring

Monitor progress in another terminal:

```bash
source <path/to/humanize>/scripts/humanize.sh # Or add to your .bashrc or .zshrc
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
- [Install for Codex](docs/install-for-codex.md) -- Codex skill runtime setup
- [Install for Kimi](docs/install-for-kimi.md) -- Kimi CLI skill setup
- [Configuration](docs/usage.md#configuration) -- Shared config hierarchy and override rules
- [Bitter Lesson Workflow](docs/bitlesson.md) -- Project memory, selector routing, and delta validation

## License

MIT
