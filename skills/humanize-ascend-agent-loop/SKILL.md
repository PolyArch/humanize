---
name: humanize-ascend-agent-loop
description: "Run a Humanize Ascend NPU kernel optimization loop: optimize raw PyTorch input with optimize-torch, recover K/R/W, classify the operator family, use one clean standalone workspace, iterate with correctness and benchmark evidence, use AscendWiki when prior art is useful, and use msprof-report-skill when profiling is needed. Target is Huawei Ascend 910B2 (Da Vinci, CANN) via Ascend C or Triton-on-Ascend."
type: flow
---

# Humanize Ascend Agent Loop

Use this flow when the user wants an autonomous Ascend NPU kernel optimization
run, not a generic software feature loop. The skill gives the agent a
kernel-shaped workspace and review loop, while keeping research and profiling
tools available on demand.

The style is intentionally lightweight:

- When the user's raw input is a loop-heavy PyTorch implementation, run
  `optimize-torch` first to produce a torch.compile-friendly optimized version
  before recovering K/R/W. The original raw input becomes `R`; the optimized
  output becomes the basis for `K`.
- Use `classify-operator-family` to classify the operator family from `K` and
  record the optimization strategy candidate pool before writing the refined plan.
- Use `AscendWiki` when prior wiki notes, techniques, Ascend API constraints, or
  prior kernels would help the current design choice.
- Use `msprof-report-skill` when profiler evidence is needed to explain a
  baseline, regression, plateau, surprising win, or next optimization edit.
- When generating a Triton kernel, query AscendWiki for Triton optimization
  patterns and read the 1-2 most relevant ones before writing kernel code.
- Do not run knowledge, classification, or profiling steps just to satisfy a
  ritual. Record the reason when a tool meaningfully changes the next step.

## Input Shape

Recover or define these before starting the loop:

```text
K: kernel definition and semantics
R: correctness reference or oracle
W: workload distribution or focused benchmark case
```

When `optimize-torch` runs in step 0, `R` is the original raw input file and
`K` is derived from the optimized `_torch_opt.py` output. The two are
semantically equivalent but structurally different — `R` preserves the original
algorithm structure for correctness checks; `K` is pre-cleaned for the compiler.

Ask the user only when `K`, `R`, `W`, target NPU, comparison target, or a hard
scope constraint is missing and cannot be inferred safely. The default target
for this repo is `ascend-910b2` (Da Vinci, CANN 9.0.0).

If `W` contains multiple regimes, optimize and report them as a distribution.
If `W` is one focused shape, say so and keep dispatcher/tuning decisions simple.

## Installed Paths

The installer hydrates these paths:

```text
Humanize runtime: {{HUMANIZE_RUNTIME_ROOT}}
KernelPilot root: {{KERNELPILOT_ROOT}}
optimize-torch root: {{OPTIMIZE_TORCH_ROOT}}
classify-operator-family root: {{CLASSIFY_OPERATOR_FAMILY_ROOT}}
AscendWiki root: {{ASCENDWIKI_ROOT}}
msprof-report-skill root: {{MSPROF_SKILL_ROOT}}
```

If `{{OPTIMIZE_TORCH_ROOT}}`, `{{CLASSIFY_OPERATOR_FAMILY_ROOT}}`, `{{ASCENDWIKI_ROOT}}`, or
`{{MSPROF_SKILL_ROOT}}` was not hydrated, locate sibling skills named
`optimize-torch`, `classify-operator-family`, `AscendWiki`, and `msprof-report-skill`, or use the
KernelPilot checkout defaults under `external/optimize-torch`,
`external/classify-operator-family`,
`external/AscendWiki`, and `external/msprof-report-skill`.

## What The Loop Should Do

Run the Humanize setup inside this skill. The user should not need to manually
run `gen-plan`, `refine-plan`, or `humanize-rlcr`.

0. If the user's raw input is a PyTorch implementation with Python loops
   (for/while, tensor-dependent branches, append/cat patterns, per-sample
   iteration), run `optimize-torch` on it first (see "Using optimize-torch"
   below). This produces a torch.compile-optimized version that eliminates
   graph breaks, recompilations, and Python-side overhead.
   
   After optimization:
   - `R` (correctness reference) = the **original raw input** — it is the
     ground-truth oracle.
   - `K_raw` (the code to base the kernel on) = the **optimized output** —
     it preserves semantics but is already pre-cleaned for the compiler.
   
1. Turn the user's request into K/R/W recovery. Ask the user only when `K`, `R`,
   `W`, target NPU, comparison target, or a hard scope constraint is missing and
   cannot be inferred safely. If `optimize-torch` ran in step 0, `R` is the
   original file and `K` is derived from the `_torch_opt.py` output.
1.5. Classify the operator family from `K` using `classify-operator-family`, and
   record the family and optimization strategy reference in the refined plan.
   The reference strategies are purely advisory — every round, including the
   first, must decide its own optimization direction based on profiling
   evidence, benchmark trends, AscendWiki patterns, and prior round outcomes.
2. Turn the user's request into a small kernel-specific plan with acceptance
   checks.
3. Select or create exactly one clean standalone optimization workspace.
4. Bootstrap only the minimal scaffold, harness placeholders, ledgers, and
   refined plan needed to start RLCR.
5. Ensure the workspace is a git repository with one clean scaffold commit.
6. Start RLCR with `--strict-success` and verify that an active
   `.humanize/rlcr/<timestamp>/state.md` exists.
7. Read `.humanize/rlcr/<timestamp>/round-0-prompt.md`.
8. Only then iterate on candidate kernels with correctness and benchmark
   evidence under Humanize review. For Triton kernels, consult AscendWiki
   optimization patterns (see "Using Triton Optimization Patterns" below)
   before writing kernel code in each round.
9. Use classify-operator-family diagnostic info when tuning decisions need
   operator-family context.
10. Use AscendWiki or live upstream sources when prior art can guide a design.
11. Use msprof-report-skill when profile evidence can answer the current question.
12. Autotune or dispatch by shape only when `W` actually needs it.

This is a loop, not a fixed research checklist. A good round may be a tiny
correctness fix, a benchmark cleanup, an AscendWiki-informed redesign, an msprof
profile digest, or an autotuning pass, depending on what the evidence says.

## Pre-RLCR Bootstrap Gate

This skill has a hard ordering requirement: before RLCR is active, do not
implement candidate kernels, run long benchmarks, collect msprof reports, or
write a final report. Pre-RLCR work is limited to:

- Running `optimize-torch` on the raw PyTorch input (step 0) to produce the
  `_torch_opt.py` optimized version.
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
- If the current directory is a large framework checkout such as MindSpeed,
  vLLM-Ascend, or a CANN samples tree, create a sibling standalone workspace for
  the experiment.
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

- `K`, `R`, `W`, target NPU, comparison baseline, and hard exclusions are
  explicit. When `optimize-torch` was used, note that `R` is the original raw
  file and `K` is derived from the `_torch_opt.py` optimized version.
- Correctness tests compare candidate outputs with `R` over the relevant cases
  on device `npu` (e.g. `torch.allclose` against the torch reference).
- Benchmarks report per-case latency and enough environment metadata to compare
  attempts fairly (CANN version, device id, dtype, shape).
- Attempt ledger records tested versions, including failed correctness,
  regressions, and abandoned ideas.
- Optimization ledger records only correct versions with measured improvement.
- Lineage records why the selected candidate changed.
- External code or source-level borrowing records URL/path, commit or version,
  license/notice when relevant, and what was adapted.
- Final output names the selected kernel, benchmark result, known fallback, and
  unsupported regimes.

## Using AscendWiki

Use the `AscendWiki` skill when prior work can help answer questions like:

- Is there a known Ascend technique for this memory layout, dtype, Cube/Vector
  pipe balance, tiling choice, or scalar/MTE-bound symptom?
- What Ascend C / Triton-on-Ascend API constraint applies here (mandatory
  masking, 16-aligned blocks, BLOCK_K alignment)?
- Is the current design missing an obvious tiling or double-buffer trick?

Run commands from `{{ASCENDWIKI_ROOT}}`:

```bash
cd {{ASCENDWIKI_ROOT}}
python3 scripts/query.py "tile a matmul on the cube unit" --limit 5 --compact
python3 scripts/query.py --tag cube --type kernel --compact
python3 scripts/query.py --symptom scalar-bound --compact
python3 scripts/grep_wiki.py "mte2|mac_ratio" --only wiki
python3 scripts/get_page.py davinci-910b2 --follow-sources
```

Use the results as evidence, not as a rulebook. If a source directly shapes
implementation code, trace it back to a wiki page, artifact, official CANN doc,
or upstream source path.

## Using optimize-torch

Run `optimize-torch` on the user's raw PyTorch input **before** K/R/W recovery
when the input contains Python loops, tensor-dependent branches, iterative
indexing, append/cat patterns, per-sample computation, or other patterns that
cause graph breaks or recompilations under `torch.compile`.

### When to run

Run optimize-torch when the raw input exhibits any of these:

- Python `for`/`while` loops iterating over tensor dimensions.
- Tensor-dependent Python branches (`if x.sum() > 0: ...`).
- Iterative indexing (`out[i] = ...` inside a loop).
- Repeated `torch.cat`/`torch.stack` building tensors in a loop.
- Per-sample computation via Python list comprehensions.
- `.item()`, `.tolist()`, or scalar conversion inside the hot path.
- Any other pattern listed in the optimize-torch transformation taxonomy.

Skip when the input is already a single vectorized tensor expression, an
Ascend C kernel, or a Triton kernel — optimize-torch targets PyTorch eager
code only.

### How to run

```bash
# Read the raw input file for analysis
cat /path/to/user_raw_input.py

# Apply optimize-torch transformations (the skill itself guides this)
# The optimized output is written to: /path/to/user_raw_input_torch_opt.py
```

The optimize-torch skill rewrites loop-heavy PyTorch code using:

- Vectorized tensor expressions and broadcasting (elementwise loops).
- `sum`/`mean`/`amax`/`argmax` and other reductions (accumulation loops).
- `cumsum`/`cumprod`/`cummax` (prefix/scan loops).
- `torch.func.vmap` (batched per-sample loops).
- `gather`/`scatter`/`index_select`/`index_put` (indexed update loops).
- `torch.where`/`masked_fill` (tensor-dependent branches).
- Preallocation + single `cat`/`stack` (tensor-list building loops).

### Post-optimization contract

After optimize-torch completes:

1. The **original file is unchanged**. The optimized version is at
   `{input_filename}_torch_opt.py`.
2. The original and optimized functions produce **identical outputs** for
   representative inputs (verified by correctness tests).
3. `R` (correctness oracle) = the **original raw input file**.
4. `K_raw` (basis for kernel design) = the **optimized `_torch_opt.py` output** —
   it is already cleaned of Python-side overhead and graph breaks.
5. The optimization report records: the original loop pattern, the chosen
   transformation, any remaining loops and why they are acceptable, and
   performance evidence.

### Interaction with the loop

- optimize-torch runs **exactly once**, before RLCR starts, as part of input
  preparation.
- The optimized code feeds into `classify-operator-family` for family
  classification and strategy reference generation.
- If the optimize-torch transformation itself reveals structural insights
  (e.g. "this is really just a batched matmul + elementwise tail"), record
  them in the refined plan's feasibility hints.
- Do not re-run optimize-torch inside the RLCR loop — its job is to clean
  the PyTorch input, not to generate Ascend kernels.

## Using classify-operator-family

Classify the operator early, right after `K` is recovered. The result provides
operator family context and a strategy reference list — both are advisory inputs,
not a round-by-round plan.

Run the classifier with the kernel source or operator name extracted from `K`:

```bash
cd {{CLASSIFY_OPERATOR_FAMILY_ROOT}}
python scripts/classify_operator.py /path/to/operator.py --json
# or via stdin:
printf '%s\n' 'torch.nn.functional.scaled_dot_product_attention' | python scripts/classify_operator.py --json
```

The `--json` output provides both `family` and `optimization_strategy_reference`:

- **family**: Use this to scope AscendWiki search tags and prior-art queries
  (e.g. `--tag attention` for an attention-family kernel).
- **optimization_strategy_reference**: Record this in the refined plan's
  feasibility hints as a **reference only**. It is a curated list of strategies
  that are empirically known to apply to this operator family — consult it
  alongside other evidence, never as a preset schedule.

### Strategy Reference Is Advisory, Never Prescriptive

The reference strategies are one input among many. Every round, from round 0
onward, the loop must autonomously decide the next optimization direction by
weighing all available evidence:

- **Profiling evidence** (msprof pipe ratios, MAC utilization, MTE/Vector
  occupancy) — the strongest signal for where the bottleneck actually is.
- **Benchmark trends** (diminishing returns, shape-specific regressions,
  plateau patterns) — what the numbers say about the current state.
- **AscendWiki pattern queries** — domain knowledge matched to the current
  bottleneck symptom.
- **Prior round outcomes** — what was tried, what worked, what didn't, and why.
- **Strategy reference** — consult as a checklist or idea source, not as a
  round assignment.

Rules:

1. **Never delegate round planning to the reference list.** The reference says
   "these strategies often help for this family" — it does not say "do STRUCTURAL
   in round 0, KERNEL_FUSION in round 1."
2. **Profiling evidence takes priority.** If the reference suggests
   TILE_REFINEMENT but msprof shows the kernel is scalar-bound at 60%, address
   the scalar bottleneck first regardless of reference order.
3. **Skip inapplicable strategies without guilt.** If a reference strategy does
   not apply (e.g. KERNEL_FUSION when there is nothing to fuse), skip it and
   note the reason. The reference is a menu, not a checklist.
4. **After the reference list is fully consulted, keep going.** The loop does
   not stop. Continue iterating with autonomously chosen directions — new tile
   sizes, pipeline rearrangements, data layout changes, mixed-precision
   variants, or any Ascend-specific optimization — until acceptance criteria
   are met or the loop truly converges.

Example workflow:
1. `K` resolves to a `scaled_dot_product_attention` implementation.
2. Classifier returns `family: attention`, reference: `STRUCTURAL, KERNEL_FUSION,
   TILE_REFINEMENT, DTE_PIPELINE, MICRO_ARCH`.
3. The refined plan records these as a strategy reference.
4. Round 0: msprof baseline shows the kernel is MTE2-bound at 80%. The loop
   consults the reference and AscendWiki, decides to start with DTE_PIPELINE
   (addressing the dominant bottleneck) rather than blindly following the
   reference order. STRUCTURAL is noted as worth revisiting if pipeline changes
   don't suffice.
5. Round 1: MTE2 drops to 55%, but now Vector occupancy is at 70%. The loop
   queries AscendWiki for vector-bound patterns and tries MICRO_ARCH tuning
   (unroll factors, instruction mix).
6. Rounds continue with each direction chosen from live evidence, consulting
   the reference as one input alongside profiling, benchmarks, and wiki patterns.
7. The loop continues until acceptance criteria are met, regardless of whether
   the reference list has been fully consulted.

If the classifier output shows `source: autonomous_fallback` (low-confidence),
note the uncertainty in the plan but proceed. The strategy reference is advisory,
not a hard constraint. Never block progress on classification when the
classifier is unavailable.

## Using msprof-report-skill

Use `msprof-report-skill` when profile evidence would change the next decision.
Good triggers include:

- The baseline is unclear and a representative profile would locate the hot
  path or bottleneck pipe.
- A correct candidate regresses or plateaus.
- A candidate is unexpectedly fast or slow.
- The next edit depends on knowing whether the issue is memory (MTE2/MTE3),
  scalar/launch overhead, Cube MAC utilization, or Vector occupancy.
- A reviewer asks for profiler-backed evidence.

Capture and analyze in one step:

```bash
"{{MSPROF_SKILL_ROOT}}/helpers/run_msprof.sh" profile/run0 python3 bench.py
```

The msprof digest should be small and actionable: keep the report path, key
pipe ratios, diagnosis, and one concrete next edit in `profile-artifacts/` or
the attempt ledger. Do not block progress on profiling when compile/test/
benchmark evidence is already enough for the current step.

## Using Triton Optimization Patterns (via AscendWiki)

When the implementation language is Triton (Triton-on-Ascend), consult
AscendWiki before writing kernel code for design-level optimization guidance.
The patterns are technique pages under `wiki/techniques/` tagged with
`languages: [triton]`.

### When to consult

Consult patterns in these situations:

- **Before writing the first Triton kernel** — scan the pattern index to
  identify 1-2 patterns relevant to the operator being implemented.
- **When a kernel is correct but slow** — re-query for patterns that match the
  bottleneck symptom.
- **When choosing between implementation strategies** — use patterns as
  decision criteria (e.g. "should I fuse or delegate to a standard library?").

### How to query

List all Triton-tagged technique pages:

```bash
cd {{ASCENDWIKI_ROOT}}
python3 scripts/query.py --language triton --type technique --compact
```

Find patterns for a specific concern:

```bash
python3 scripts/query.py "fuse adjacent computations" --language triton --type technique --compact
python3 scripts/query.py "tile along longest dimension" --language triton --type technique --compact
python3 scripts/query.py "two pass scan" --language triton --type technique --compact
python3 scripts/query.py "layout regularization" --language triton --type technique --compact
```

Read a specific pattern page:

```bash
python3 scripts/get_page.py kernel-fusion --follow-sources
python3 scripts/get_page.py two-pass-scan --follow-sources
python3 scripts/get_page.py layout-regularization --follow-sources
python3 scripts/get_page.py small-dim-specialization --follow-sources
python3 scripts/get_page.py mixed-precision-accumulation --follow-sources
python3 scripts/get_page.py delegate-main-to-library --follow-sources
```

### Available pattern catalog

| Pattern | Technique page | Use when |
|---|---|---|
| Delegate main to library | `delegate-main-to-library` | Main computation is a standard op (matmul, etc.); only tail logic needs custom code |
| Two-pass scan | `two-pass-scan` | A small statistic (norm, scale) is computed first, then applied to a large tensor |
| Fuse adjacent computations | `kernel-fusion` | Multiple elementwise/reduction steps feed one output and create intermediate tensors |
| Regularize data layout | `layout-regularization` | Inputs may be non-contiguous (view, transpose, broadcast); hot path needs simple addressing |
| Tile along longest dimension | `tiling-strategy` | Operator has a long independent streaming dimension; need more parallelism |
| Specialize for small dims | `small-dim-specialization` | A small dimension value (e.g. 4, 8) dominates real traffic; manual unrolling wins |
| Mixed-precision accumulation | `mixed-precision-accumulation` | Bandwidth-bound; store in bf16/fp16, accumulate in fp32 |

### Usage rules

- **Read the index first** — query `--language triton --type technique` to see
  available patterns, then read only the 1-2 most relevant pages.
- **Patterns are advisory, not mandatory** — use them as design heuristics, not
  rigid rules. A pattern may be inapplicable to the current operator.
- **Record in the refined plan** — when a pattern shapes the implementation
  strategy, note which pattern and why in the refined plan's feasibility hints.
- **Re-query when stuck** — if repeated rounds hit the same bottleneck, query
  AscendWiki for patterns matching that symptom.

## Progress Checks

- If an attempt hangs or times out, reduce to the smallest executable shape or
  tile under a hard timeout before target-size benchmarking.
- If repeated rounds hit the same blocker, narrow the next round to a smaller
  falsifiable milestone or reset the design.
- If a correct candidate is far below target, use either prior art, profiling,
  or a simpler baseline comparison to decide whether the lineage is worth
  continuing.
- **Direction selection**: Every round must choose its optimization direction
  from live evidence (profiling, benchmarks, AscendWiki patterns, prior
  outcomes), not from a preset strategy sequence. The strategy reference from
  `classify-operator-family` is one input to consult — never the sole
  decision driver. If profiling evidence contradicts the reference, follow
  the evidence.

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
