---
name: humanize-mlu-agent-loop
description: "Run a Humanize Cambricon MLU kernel optimization loop: recover K/R/W, use one clean standalone workspace, iterate with correctness and benchmark evidence, use MLUWiki when prior art is useful, and use cnperf-report-skill when profiling is needed. Target is Cambricon MLU (IPU/NRAM, Cambricon Neuware) via Triton-on-MLU or BANG-C."
type: flow
---

# Humanize MLU Agent Loop

Use this flow when the user wants an autonomous Cambricon MLU kernel
optimization run, not a generic software feature loop. The skill gives the agent
a kernel-shaped workspace and review loop, while keeping research and profiling
tools available on demand.

The style is intentionally lightweight:

- Use `MLUWiki` when prior wiki notes, MLU techniques (retiling, persistent
  loop, libdevice substitution), or prior MLU kernels would help the current
  design choice.
- Use `cnperf-report-skill` when profiler evidence is needed to explain a
  baseline, regression, plateau, surprising win, or next optimization edit.
- Do not run knowledge or profiling steps just to satisfy a ritual. Record the
  reason when a tool meaningfully changes the next step.

## Input Shape

Recover or define these before starting the loop:

```text
K: kernel definition and semantics
R: correctness reference or oracle
W: workload distribution or focused benchmark case
```

Ask the user only when `K`, `R`, `W`, target MLU, comparison target, or a hard
scope constraint is missing and cannot be inferred safely. The default target
for this repo is `cambricon-mlu` (IPU cores in MLU clusters, NRAM = 512 KB per
IPU core, single-dim grid limit 65535).

If `W` contains multiple regimes, optimize and report them as a distribution.
If `W` is one focused shape, say so and keep dispatcher/tuning decisions simple.

## Installed Paths

The installer hydrates these paths:

```text
Humanize runtime: {{HUMANIZE_RUNTIME_ROOT}}
KernelPilot root: {{KERNELPILOT_ROOT}}
MLUWiki root: {{MLUWIKI_ROOT}}
cnperf-report-skill root: {{CNPERF_SKILL_ROOT}}
```

If `{{MLUWIKI_ROOT}}` or `{{CNPERF_SKILL_ROOT}}` was not hydrated, locate
sibling skills named `MLUWiki` and `cnperf-report-skill`, or use the
KernelPilot checkout defaults under `external/MLUWiki` and
`external/cnperf-report-skill`.

## What The Loop Should Do

Run the Humanize setup inside this skill. The user should not need to manually
run `gen-plan`, `refine-plan`, or `humanize-rlcr`.

1. Turn the user's request into a small kernel-specific plan with acceptance
   checks.
2. Select or create exactly one clean standalone optimization workspace.
3. Bootstrap only the minimal scaffold, harness placeholders, ledgers, and
   refined plan needed to start RLCR.
4. Ensure the workspace is a git repository with one clean scaffold commit.
5. Start RLCR with `--strict-success` and verify that an active
   `.humanize/rlcr/<timestamp>/state.md` exists.
6. Read `.humanize/rlcr/<timestamp>/round-0-prompt.md`.
7. Only then iterate on candidate kernels with correctness and benchmark
   evidence under Humanize review.
8. Use MLUWiki or live upstream sources when prior art can guide a design.
9. Use cnperf-report-skill when profile evidence can answer the current
   question.
10. Autotune or dispatch by shape only when `W` actually needs it.

This is a loop, not a fixed research checklist. A good round may be a tiny
correctness fix, a benchmark cleanup, an MLUWiki-informed redesign, a cnperf
profile digest, or an autotuning pass, depending on what the evidence says.

## Pre-RLCR Bootstrap Gate

This skill has a hard ordering requirement: before RLCR is active, do not
implement candidate kernels, run long benchmarks, collect cnperf reports, or
write a final report. Pre-RLCR work is limited to:

- Choosing the workspace root.
- Writing the scaffold, refined plan, empty or placeholder harness files, and
  ledgers.
- Creating `.gitignore` entries that keep `.humanize*` untracked.
- Initializing git and committing the scaffold.
- Running `setup-rlcr-loop.sh`.

If the workspace has no git repository, initialize it before the scaffold
commit:

```bash
git init
git add .gitignore README.md workloads/ src/ bindings/ tests/ benchmarks/ dispatch/ ledgers/ profile-artifacts/
git commit -m "Initialize kernel optimization workspace"
```

Adjust the path list to match the scaffold that actually exists, and add
optional build files such as `setup.py` or `python/` only if they exist, but do
not add `.humanize/`. If git has no user identity configured, set a local
identity such as `git config user.name KernelPilot` and `git config user.email
kernelpilot@example.invalid`.

After `setup-rlcr-loop.sh` succeeds, immediately verify that RLCR is active:

```bash
find .humanize/rlcr -maxdepth 2 -name state.md -print
```

If no `state.md` is present, stop and report that RLCR did not start. Do not
continue into kernel implementation outside the Humanize loop.

## Workspace Root

Use one workspace root for the whole loop. This is the directory that contains
`README.md`, `src/`, `tests/`, `benchmarks/`, `ledgers/`, and `.humanize/`.

Selection rules:

- If the current directory is already an empty or intended optimization
  workspace, use the current directory directly.
- If the current directory is a large framework checkout such as
  vLLM-MLU, torch_mlu, or a Cambricon Neuware samples tree, create a sibling
  standalone workspace for the experiment.
- If the current directory already contains `.humanize/`, `ledgers/`, `src/`,
  or a prior scaffold for this task, do not create another nested repo. Continue
  from that root unless the user explicitly asks for a fresh workspace.
- Never create a git repository inside another optimization repository. If a
  nested repo already exists, stop and report the split before continuing.
- Run Humanize/RLCR from the same workspace root that contains the kernel code
  and ledgers. Do not keep RLCR state in one repo while committing code in
  another.

Create this skeleton in the chosen workspace root:

```text
.gitignore
.humanize/kernel-agent/refined-plan.md
README.md
workloads/
src/<task_name>/
bindings/
tests/
benchmarks/
dispatch/
ledgers/attempt-ledger.md
ledgers/optimization-ledger.md
ledgers/lineage.jsonl
ledgers/research-digest.md
ledgers/tuning-decisions.md
benchmarks/performance-map.json
profile-artifacts/README.md
```

Keep the source framework checkout read-only unless the user explicitly asks
for an in-place framework patch.

Before the first scaffold commit, `.gitignore` should protect local Humanize
state:

```gitignore
.humanize*
```

The refined plan file should exist for RLCR but remain untracked by default:

```bash
git check-ignore .humanize/kernel-agent/refined-plan.md
if git ls-files --error-unmatch .humanize/kernel-agent/refined-plan.md >/dev/null 2>&1; then
  git rm --cached .humanize/kernel-agent/refined-plan.md
fi
```

Commit the scaffold and harness files from the workspace root, not
`.humanize/` loop state. This commit must exist before running RLCR setup.

## Lightweight Acceptance Checks

The refined plan should keep these checks visible without turning them into a
large ceremony:

- `K`, `R`, `W`, target MLU, comparison baseline, and hard exclusions are
  explicit.
- Correctness tests compare candidate outputs with `R` over the relevant cases
  on `device="mlu"` (after `import torch_mlu`), e.g. `torch.allclose` against
  the torch reference. Synchronize with `torch.mlu.synchronize()`, never
  `torch.cuda.synchronize()`.
- Benchmarks report per-case latency and enough environment metadata to compare
  attempts fairly (Cambricon Neuware version, triton-mlu release, device id,
  dtype, shape).
- Attempt ledger records tested versions, including failed correctness,
  regressions, and abandoned ideas.
- Optimization ledger records only correct versions with measured improvement.
- Lineage records why the selected candidate changed.
- External code or source-level borrowing records URL/path, commit or version,
  license/notice when relevant, and what was adapted.
- Final output names the selected kernel, benchmark result, known fallback, and
  unsupported regimes.

MLU-specific reminders that often surface as round-0 acceptance checks:

- fp64 is not supported on MLU; cast inputs and accumulators to fp32 on the
  host before kernel launch.
- A single-dim grid is capped at 65535; for larger workloads build a persistent
  loop sized by `TOTAL_CORE_NUM // num_warps` and step through tiles inside the
  kernel.
- Every load with a partial tile needs a mask; reduce loads need an `other=`
  identity matching the reduce op (0.0 for sum, -inf for max, +inf for min).

## Using MLUWiki

Use the `MLUWiki` skill when prior work can help answer questions like:

- Is there a known MLU technique for this memory layout, dtype, NRAM budget,
  pipe ratio, tiling choice, or symptom (NRAM-OOR, grid overflow, mask-missing
  tail garbage)?
- What Triton-on-MLU / `tl.extra.mlu.libdevice` API constraint applies here
  (mandatory masking, 128-byte stride-1 minimum, `num_warps in {1, 4}`,
  `num_stages in {1, 3}`, no fp64)?
- Is the current design missing an obvious tiling, persistent-loop, or
  libdevice fast_* substitution?

Run commands from `{{MLUWIKI_ROOT}}`:

```bash
cd {{MLUWIKI_ROOT}}
python3 scripts/query.py "tile a matmul on the mlu" --limit 5 --compact
python3 scripts/query.py --tag mlu --type kernel --compact
python3 scripts/query.py --symptom nram-oor --compact
python3 scripts/query.py --language libdevice --compact
python3 scripts/grep_wiki.py "fast_silu|fast_rcp|atomic_add" --only wiki
python3 scripts/get_page.py cambricon-mlu-arch --follow-sources
python3 scripts/get_page.py mlu-libdevice --follow-sources
```

Use the results as evidence, not as a rulebook. If a source directly shapes
implementation code, trace it back to a wiki page, artifact, official Cambricon
doc, or upstream source path.

## Using cnperf-report-skill

Use `cnperf-report-skill` when profile evidence would change the next
decision. Good triggers include:

- The baseline is unclear and a representative profile would locate the hot
  path or bottleneck pipe.
- A correct candidate regresses or plateaus.
- A candidate is unexpectedly fast or slow.
- The next edit depends on knowing whether the issue is NRAM utilization, DMA
  pipe ratio, scalar/launch overhead, math-pipe occupancy, or tail effects.
- A reviewer asks for profiler-backed evidence.

Capture and analyze in one step (the helper name follows whichever
cnperf-report-skill release is installed; consult its docs):

```bash
"{{CNPERF_SKILL_ROOT}}/helpers/run_cnperf.sh" profile/run0 python3 bench.py
```

The cnperf digest should be small and actionable: keep the report path, key
pipe ratios (NRAM utilization, math/IO pipe ratio), diagnosis, and one concrete
next edit in `profile-artifacts/` or the attempt ledger. Map signals to next
levers using the `[[perf-analyzer]]` page in MLUWiki. Do not block progress on
profiling when compile/test/benchmark evidence is already enough for the
current step.

## Progress Checks

- If an attempt hangs or times out, reduce to the smallest executable shape or
  tile under a hard timeout before target-size benchmarking.
- If repeated rounds hit the same blocker, narrow the next round to a smaller
  falsifiable milestone or reset the design.
- If a correct candidate is far below target, use either prior art, profiling,
  or a simpler baseline comparison to decide whether the lineage is worth
  continuing.

## RLCR Startup

After writing and committing the workspace scaffold, start the loop from inside
the chosen workspace root:

```bash
"{{HUMANIZE_RUNTIME_ROOT}}/scripts/setup-rlcr-loop.sh" .humanize/kernel-agent/refined-plan.md --yolo --strict-success
```

If setup exits non-zero, report the error instead of bypassing the gate. The
loop uses Humanize's configured review model and strict-success mode by default,
so max-iteration and stagnation checks trigger recovery prompts rather than
ending the run before the acceptance target is met. The caller may still pass
explicit overrides such as `--max` or a model flag.

After setup succeeds:

1. Read `.humanize/rlcr/<timestamp>/round-0-prompt.md`.
2. Execute the current round.
3. Commit changes.
4. Write the required round summary.
5. Stop normally so the Humanize Stop hook can review.

If the hook blocks exit, follow the generated next-round prompt.
