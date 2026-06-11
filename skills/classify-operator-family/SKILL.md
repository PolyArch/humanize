---
name: classify-operator-family
description: Return the optimization strategy reference for a PyTorch-style operator code snippet, API call, formula, or operator name. Use when the user provides an operator and asks for optimization strategies; first classify the operator family, then query op_family.md for that family's strategy reference.
---

# Operator Family Strategy Pool

## Goal

Return the optimization strategy reference for an input operator code snippet or operator name.

Valid families are: `attention`, `matmul`, `softmax`, `norm`, `reduction`, `elementwise`, `elementwise_complex`, `convolution`, `pooling`, `scan`, `sort_search`, `fusion_simple`, and `recurrent`.

Valid optimization strategy labels are read from `references/op_family.md`, currently including `STRUCTURAL`, `KERNEL_FUSION`, `TILE_REFINEMENT`, `DTE_PIPELINE`, `MICRO_ARCH`, `ALGORITHM_SUBSTITUTION`, `HARDWARE_DISPATCH`, `FINE_TUNING`, and `EXPLORATION`.

## Quick Start

Prefer the bundled classifier because it enforces the required order:

```bash
python scripts/classify_operator.py /path/to/operator.py
printf '%s\n' 'torch.nn.functional.softmax(x, dim=-1)' | python scripts/classify_operator.py
```

The default output is only the ordered optimization strategy reference for the classified family.

Example:

```text
ALGORITHM_SUBSTITUTION, HARDWARE_DISPATCH, MICRO_ARCH, DTE_PIPELINE, FINE_TUNING
```

Use `--explain` when you also need the classified family, matched source, and pattern. Use `--json` when another tool needs structured output with both `family` and `optimization_strategy_reference`.

## Resolution Order

1. Classify the operator family with `references/op_family.md` first.
   - Parse the markdown table from top to bottom.
   - Match the listed Torch operators against operator identity signals: a bare operator name, a direct one-call expression, a function/class/kernel name, or an explicit registration/schema name.
   - Do not classify a multi-step implementation body from `op_family.md` merely because it contains primitive calls such as `softmax`, `sum`, or `exp`; treat that as not confidently classified and continue to the JSON rules.
   - Treat slash-separated entries as alternatives.
   - Treat wildcard entries such as `reduce_*` as operator-name wildcards.
2. Use `references/classification_rules.json` only when `op_family.md` cannot classify the input.
   - Normalize by lowercasing, collapsing repeated whitespace, and stripping namespaces such as `torch.`, `aten::`, `prim::`, `nn.`, and `nn.functional.` when useful.
   - Evaluate JSON families by ascending `priority`.
   - For each family, try `operator_patterns` before `formula_patterns`.
   - First confident match wins; the priority order already encodes the listed disambiguation rules.
3. If neither source matches, make an autonomous best-effort choice from the valid family list.
   - Use any available operator name, comments, surrounding file path, benchmark context, or semantic hints.
   - Prefer a plausible specific family over a generic one when the signal is clear.
   - If the input is opaque and provides no usable signal, return `elementwise` as the final fallback.
   - Never return `unknown`; the result must be one of the valid families.
4. Query `references/op_family.md` by the resolved family and return the third-column `优化策略参考（按优先顺序）`.
   - Preserve the strategy order from the table.
   - Return the strategy reference, not the family, unless the user explicitly asks for evidence or explanation.

## Manual Use

When not running the script, inspect `references/op_family.md` first for direct operator identity matches. Only load `references/classification_rules.json` after the direct table cannot confidently classify the input. For fallback matching, use Python/PCRE-style regular expressions with case-insensitive and dot-matches-newline behavior.

If both direct and JSON matching fail, independently choose the most plausible valid family from available context. Then look up that family in `references/op_family.md` and return only its optimization strategy reference unless the user explicitly asks for evidence or explanation.
