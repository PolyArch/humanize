# Vendored Humanize Upstream

- Source: https://github.com/PolyArch/humanize
- Branch: dev
- Imported commit: 1c45548
- Import command:

```bash
git clone --recursive --branch dev --depth 1 https://github.com/PolyArch/humanize.git humanize
```

KernelPilot patches add `humanize-kernel-agent-loop` and installer hydration
for the external `KernelWiki` and `ncu-report-skill` skill roots. Kernel
optimization loops start RLCR with `--strict-success`, which suppresses
max-iteration and stagnation exits until the acceptance target is met or the
user cancels the loop.
