---
name: optimize-torch
description: Optimize loop-heavy PyTorch tensor functions for torch.compile and AI accelerator backends. Use when reviewing or rewriting PyTorch code that has Python for/while loops, tensor-dependent branches, iterative indexing, append/cat patterns, per-sample computation, graph breaks, recompilations, or poor Inductor fusion/performance.
---

# Optimize Torch Inductor Loops

## Goal

Rewrite PyTorch computation so `torch.compile` can capture larger stable graphs, TorchInductor can fuse and schedule tensor work, and the target accelerator sees fewer small kernels and CPU round trips.

Preserve numerics first. The optimized function must keep the same observable outputs as the original eager function for the covered inputs, including return structure, shape, dtype, device, values within documented tolerances, and gradients when training is involved. Only change algorithmic structure after adding or identifying reference tests for shapes, dtypes, devices, tolerances, gradients, and edge cases.

## Workflow

1. Establish a baseline:
   - Keep the original eager function as the oracle.
   - Do not overwrite the input source file. Write the optimized implementation to a new file in the same directory named `{input_filename}_torch_opt.py`, where `{input_filename}` is the original file stem without its extension.
   - Save or compute baseline outputs before rewriting.
   - Add focused tests for representative and boundary shapes.
   - Benchmark with warmup, synchronization, and realistic input distributions.

2. Classify every loop:
   - Independent elementwise loop.
   - Reduction or prefix/scan loop.
   - Batched per-row/per-sample loop.
   - Indexed gather/scatter/update loop.
   - Tensor-list or repeated `cat`/`stack` loop.
   - Recurrence where iteration `t` depends on `t-1`.
   - Early-exit or data-dependent control-flow loop.
   - Small static loop over a fixed Python constant.

3. Define the equivalence contract:
   - Compare the original and optimized functions on identical inputs.
   - Check nested return structures, shapes, dtypes, devices, strides or layout when relevant, and numeric values.
   - Use exact equality for integer, boolean, index, mask, and shape-like outputs.
   - Use explicit `rtol`/`atol` tolerances for floating and complex outputs, and document any expected numerical associativity differences.
   - Compare gradients with the same tolerance rules when the function participates in training.

4. Apply the narrowest valid transformation from the taxonomy below.

5. Re-run correctness tests, then re-run compile diagnostics and performance tests.

6. Stop when the graph is stable, no important loop remains on the Python side, and the performance gain justifies any readability cost.

## Transformation Taxonomy

### Independent Elementwise Loops

Replace per-index loops with vectorized tensor expressions and broadcasting.

```python
# Before
out = torch.empty_like(x)
for i in range(x.shape[0]):
    out[i] = x[i] * scale + bias

# After
out = x * scale + bias
```

Use `torch.where`, `masked_fill`, `clamp`, `minimum`, `maximum`, and boolean masks instead of Python `if` inside an elementwise loop.

```python
# Before
for i in range(x.numel()):
    y[i] = a[i] if mask[i] else b[i]

# After
y = torch.where(mask, a, b)
```

### Reductions

Replace accumulation loops with tensor reductions.

Use `sum`, `mean`, `prod`, `amax`, `amin`, `argmax`, `argmin`, `norm`, `logsumexp`, `count_nonzero`, `any`, and `all` when the loop combines values along one or more dimensions.

```python
# Before
s = torch.zeros(x.shape[0], device=x.device, dtype=x.dtype)
for j in range(x.shape[1]):
    s = s + x[:, j]

# After
s = x.sum(dim=1)
```

For grouped reductions, prefer `scatter_add`, `scatter_reduce`, `index_add`, or `bincount` over Python loops over groups.

### Prefix and Cumulative Loops

Replace associative prefix computations with built-ins when possible:

- Running sums/products: `cumsum`, `cumprod`
- Running extrema: `cummax`, `cummin`
- Cumulative log-domain sums: `logcumsumexp`

When the recurrence has an algebraic closed form, derive the batched expression explicitly. If no closed form exists, keep a static loop only when the trip count is small and fixed, or use structured control flow if it is supported by the target PyTorch/backend combination.

### Batched Per-Sample Loops

Use native batched operators first. If the loop calls a pure tensor function independently per sample and no native batched form exists, use `torch.func.vmap`.

```python
def one_sample(x_i, w_i):
    return (x_i @ w_i).relu()

# Before
ys = [one_sample(x[i], w[i]) for i in range(x.shape[0])]
y = torch.stack(ys)

# After
y = torch.func.vmap(one_sample)(x, w)
```

Make the mapped function pure: no mutation of Python containers, no printing, no data-dependent Python branching, and no shape changes per sample.

### Gather, Scatter, and Indexed Updates

Replace loops that select or update by index with tensor indexing primitives:

- Selection: `index_select`, `gather`, `take_along_dim`, advanced indexing
- Update/add: `scatter`, `scatter_add`, `scatter_reduce`, `index_put`, `index_add`
- Dense category expansion: `one_hot` when category cardinality is moderate and known

Avoid Python loops over tokens, heads, groups, experts, bins, or blocks if the loop body only moves or combines tensor slices.

### Branches

Use `torch.where` for elementwise selection.

Use structured control flow such as `torch.cond` only for coarse tensor-level branches where both branches return compatible tensor structures. Keep branch functions side-effect-free and avoid changing rank, dtype, or device between branches.

Avoid tensor-dependent Python conditions:

```python
# Bad for graph capture
if x.sum() > 0:
    y = a(x)
else:
    y = b(x)
```

Prefer tensorized masking, or structured control flow when masking would compute too much unused work.

### Tensor Lists and Repeated Concatenation

Do not build tensors by repeated `torch.cat` inside a loop. This creates repeated allocation and graph complexity.

Prefer one of:

- Compute the full result directly with broadcasting or indexing.
- Precompute all slices and call one `stack`/`cat`.
- Preallocate and use a tensor update primitive when semantics require placement by index.
- Use `torch._foreach_*` operations for uniform elementwise updates over many same-shaped tensors, if the backend supports them.

### Small Static Loops

It is acceptable to keep a loop when all are true:

- Trip count is a small Python constant.
- No tensor value controls the loop count.
- Shapes and dtypes are stable.
- The compiled graph contains the loop body without graph breaks.
- Unrolling does not produce excessive compile time or code size.

For larger static repeated blocks, consider compiling only the repeated region or using regional compilation if compile latency becomes the bottleneck.

### Recurrences and Early Exit

For loops where each step depends on previous tensor results:

1. Look for an associative or closed-form rewrite first.
2. Replace early exit with a fixed maximum iteration count plus an `active` mask when the extra work is acceptable.
3. Use structured loop control only when available and tested on the target backend.
4. Keep the loop outside `torch.compile` only as a last resort, and isolate the compiled tensor-heavy body inside it.

## Inductor-Friendly Coding Rules

Keep values on device. Do not move tensors through Python scalars or host containers inside compiled regions:

- Avoid `.item()`, `.tolist()`, `float(tensor)`, `int(tensor)`, `bool(tensor)`.
- Avoid NumPy conversion or CPU-only helper code.
- Avoid Python `print`, logging, exception construction from tensor values, or assertions that depend on tensor values.

Keep graph structure stable:

- Avoid data-dependent output rank or shape.
- Avoid boolean indexing that compacts to unknown length if a fixed-shape mask can be used instead.
- Avoid changing dtype, device, or memory layout conditionally.
- Avoid creating many tiny tensors in Python loops.
- Avoid Python dictionaries/lists whose length or keys depend on tensor values.

Prefer compiler-visible tensor operations:

- Use ATen/PyTorch ops over custom Python math.
- Use views, broadcasting, matmul, reductions, gather/scatter, and masks.
- Keep constants as Python literals only when they do not affect graph specialization; otherwise pass them explicitly as inputs or buffers.
- Confirm that the target accelerator backend supports the rewritten ops. If not, rewrite to supported ATen primitives or add a proper custom op with meta/fake tensor behavior.

## Review Checklist

Before handing off an optimized version, verify:

- The original input file remains unchanged, and the optimized code is written beside it as `{input_filename}_torch_opt.py`.
- Eager original and optimized outputs match for representative inputs.
- Output parity covers return structure, shape, dtype, device, and value equality or documented tolerance.
- Gradients match if the function participates in training.
- Recompiles are explained and limited.
- Dynamic shapes are intentional and tested.
- Benchmark includes warmup and device synchronization.
- The optimized code reduces Python-side iteration, allocations, and tiny kernels.
- The transformation is documented when it changes numerical associativity, precision, or execution order.

## Output Style

When reporting an optimization, describe:

- The original loop pattern.
- The chosen transformation and why it is compiler-friendly.
- Any remaining loop and why it is acceptable.
- Correctness checks proving pre-conversion and post-conversion outputs match, plus performance evidence.
- Risks such as changed reduction order, extra masked work, backend op support, or compile-time growth.
