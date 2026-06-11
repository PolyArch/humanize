#!/usr/bin/env python3
"""Return an operator family's optimization strategy reference.

The operator is first classified into a family using op_family.md, JSON rules,
then best-effort fallback. The final answer is the optimization strategy
reference for that family from op_family.md.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


DEFAULT_REFERENCES = Path(__file__).resolve().parents[1] / "references"
FAMILY_ORDER = (
    "attention",
    "matmul",
    "softmax",
    "norm",
    "reduction",
    "elementwise",
    "elementwise_complex",
    "convolution",
    "pooling",
    "scan",
    "sort_search",
    "fusion_simple",
    "recurrent",
)

AUTONOMOUS_FALLBACK_RULES: tuple[tuple[str, str, str], ...] = (
    (
        "attention",
        r"\b(?:attn|attention|sdpa|flash|qkv|query|key|value|kv[_ ]?cache|multi[_ ]?head|mha)\b",
        "attention-related naming cue",
    ),
    (
        "fusion_simple",
        r"\b(?:fused?|fusion|post|pre|tail|mix|residual|bias|dropout[_ ]?add|norm[_ ]?act|linear[_ ]?act)\b",
        "fused or post-processing naming cue",
    ),
    (
        "recurrent",
        r"\b(?:rnn|lstm|gru|recurrent|recurrence|hidden|state|cell|causal[_ ]?conv|time[_ ]?step)\b",
        "recurrent/state naming cue",
    ),
    (
        "convolution",
        r"\b(?:conv|convolution|depthwise|dwconv|kernel|filter|stride|padding|dilation|nchw|nhwc)\b",
        "convolution naming cue",
    ),
    (
        "matmul",
        r"\b(?:matmul|gemm|mm|bmm|addmm|linear|dense|fc|fully[_ ]?connected)\b",
        "matrix multiply naming cue",
    ),
    (
        "softmax",
        r"\b(?:softmax|log[_ ]?softmax|logsumexp|probabilities|probs|logits)\b",
        "softmax naming cue",
    ),
    (
        "norm",
        r"\b(?:norm|normalize|normalization|rms|layer[_ ]?norm|batch[_ ]?norm|group[_ ]?norm|variance|epsilon)\b",
        "normalization naming cue",
    ),
    (
        "pooling",
        r"\b(?:pool|pooling|adaptive[_ ]?pool|global[_ ]?avg|global[_ ]?max|downsample)\b",
        "pooling naming cue",
    ),
    (
        "scan",
        r"\b(?:scan|prefix|cumsum|cumprod|cumulative|running[_ ]?(?:sum|product|total))\b",
        "scan/prefix naming cue",
    ),
    (
        "sort_search",
        r"\b(?:sort|argsort|topk|top[_ ]?k|kth|searchsorted|bucketize|rank|partition)\b",
        "sort/search naming cue",
    ),
    (
        "reduction",
        r"\b(?:reduce|reduction|sum|mean|amax|amin|argmax|argmin|aggregate|accum|count)\b",
        "reduction naming cue",
    ),
    (
        "elementwise_complex",
        r"\b(?:gelu|silu|swiglu|geglu|reglu|glu|mish|swish|gate|gating)\b",
        "complex activation/gating naming cue",
    ),
    (
        "elementwise",
        r"\b(?:elementwise|pointwise|relu|sigmoid|tanh|exp|log|sqrt|where|clamp|add|mul|div|sub)\b",
        "elementwise naming cue",
    ),
)


@dataclass(frozen=True)
class Classification:
    family: str
    source: str
    matched: str | None = None
    pattern_type: str | None = None


@dataclass(frozen=True)
class OpFamilyRow:
    family: str
    operators: list[str]
    optimization_candidate_pool: list[str]


@dataclass(frozen=True)
class StrategyResult:
    classification: Classification
    optimization_candidate_pool: list[str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Return the optimization strategy reference for an operator "
            "family using op_family.md, classification_rules.json, then best-effort fallback."
        )
    )
    parser.add_argument(
        "input",
        nargs="?",
        help="Path to an operator code file. If omitted, code is read from stdin.",
    )
    parser.add_argument(
        "--text",
        help="Operator code or name passed directly on the command line.",
    )
    parser.add_argument(
        "--references",
        type=Path,
        default=DEFAULT_REFERENCES,
        help="Directory containing op_family.md and classification_rules.json.",
    )
    parser.add_argument(
        "--explain",
        action="store_true",
        help="Print strategy pool plus the classified family, rule source, and matched term/pattern.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print structured JSON output.",
    )
    return parser.parse_args()


def read_input(args: argparse.Namespace) -> str:
    if args.text is not None:
        return args.text
    if args.input:
        return Path(args.input).read_text(encoding="utf-8")
    return sys.stdin.read()


def strip_namespaces(text: str) -> str:
    namespaces = (
        r"torch\.nn\.functional\.",
        r"torch\.nn\.",
        r"nn\.functional\.",
        r"torch\.",
        r"aten::",
        r"prim::",
        r"nn\.",
    )
    return re.sub(r"\b(?:" + "|".join(namespaces) + r")", "", text)


def normalized_variants(text: str) -> list[str]:
    lower = text.lower()
    collapsed = re.sub(r"\s+", " ", lower)
    stripped = strip_namespaces(collapsed)
    return dedupe([lower, collapsed, stripped])


def dedupe(values: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    unique: list[str] = []
    for value in values:
        if value not in seen:
            unique.append(value)
            seen.add(value)
    return unique


def parse_op_family_rows(pp_text: str) -> list[OpFamilyRow]:
    rows: list[OpFamilyRow] = []
    for line in pp_text.splitlines():
        line = line.strip()
        if not line.startswith("|") or "---" in line or "family" in line.lower():
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if len(cells) < 3:
            continue
        operators = [op.strip().lower() for op in cells[0].split("/") if op.strip()]
        family = cells[1].strip().lower()
        candidate_pool = [strategy.strip() for strategy in cells[2].split(",") if strategy.strip()]
        if operators and family and candidate_pool:
            rows.append(
                OpFamilyRow(
                    family=family,
                    operators=operators,
                    optimization_candidate_pool=candidate_pool,
                )
            )
    return rows


def pp_candidate_texts(text: str) -> list[str]:
    """Return operator identity snippets suitable for op_family.md direct matching."""
    candidates: list[str] = []
    stripped = text.strip()
    if looks_like_single_operator_reference(stripped):
        candidates.append(stripped)

    identity_patterns = (
        r"\bdef\s+([A-Za-z_]\w*)\s*\(",
        r"\bclass\s+([A-Za-z_]\w*)\b",
        r"\b(?:__global__\s+)?(?:__device__\s+)?(?:static\s+)?(?:inline\s+)?"
        r"(?:void|int|float|double|half|auto|tensor|at::tensor|torch::tensor)\s+([A-Za-z_]\w*)\s*\(",
        r"\bm\.def\s*\(\s*['\"]([^'\"]+)['\"]",
        r"\bTORCH_LIBRARY(?:_IMPL)?\s*\([^;]*?['\"]([^'\"]+)['\"]",
    )
    for pattern in identity_patterns:
        candidates.extend(match.group(1) for match in re.finditer(pattern, text, re.IGNORECASE))
    return dedupe(candidates)


def looks_like_single_operator_reference(text: str) -> bool:
    if not text or len(text) > 320:
        return False
    if "\n" in text or ";" in text or "=" in text:
        return False
    if re.search(r"\b(?:def|class|return|for|while|if|else|elif|with|import|from)\b", text):
        return False
    return bool(re.search(r"[A-Za-z_][\w:.]*", text))


def operator_pattern(operator: str) -> re.Pattern[str]:
    operator = operator.strip().lower()
    if operator.endswith("_*"):
        base = re.escape(operator[:-2]).replace(r"\_", r"[_ ]?")
        pattern = rf"(?<![a-z0-9_]){base}[_ ][a-z0-9_]+(?![a-z0-9_])"
    else:
        pattern = re.escape(operator)
        pattern = pattern.replace(r"\_", r"[_ ]?")
        pattern = pattern.replace(r"\*", r"[a-z0-9_]+")
        pattern = rf"(?<![a-z0-9_]){pattern}(?![a-z0-9_])"
    return re.compile(pattern, re.IGNORECASE)


def classify_with_pp(text: str, pp_path: Path) -> Classification | None:
    pp_text = pp_path.read_text(encoding="utf-8")
    candidates = pp_candidate_texts(text)
    variants = [variant for candidate in candidates for variant in normalized_variants(candidate)]
    for row in parse_op_family_rows(pp_text):
        for operator in row.operators:
            pattern = operator_pattern(operator)
            if any(pattern.search(variant) for variant in variants):
                return Classification(family=row.family, source="op_family.md", matched=operator)
    return None


def candidate_pool_for_family(family: str, pp_path: Path) -> list[str]:
    pp_text = pp_path.read_text(encoding="utf-8")
    for row in parse_op_family_rows(pp_text):
        if row.family == family:
            return row.optimization_candidate_pool
    raise ValueError(f"family {family!r} is not present in {pp_path}")


def compile_rule(pattern: str) -> re.Pattern[str] | None:
    try:
        return re.compile(pattern, re.IGNORECASE | re.DOTALL)
    except re.error:
        return None


def classify_with_json(text: str, rules_path: Path) -> Classification | None:
    rules = json.loads(rules_path.read_text(encoding="utf-8"))
    variants = normalized_variants(text)
    families = sorted(rules.get("families", []), key=lambda item: item.get("priority", 9999))

    for family_rule in families:
        family = family_rule.get("family")
        if not family:
            continue
        for pattern_type in ("operator_patterns", "formula_patterns"):
            for pattern_text in family_rule.get(pattern_type, []):
                pattern = compile_rule(pattern_text)
                if pattern is None:
                    continue
                if any(pattern.search(variant) for variant in variants):
                    return Classification(
                        family=family,
                        source="classification_rules.json",
                        matched=pattern_text,
                        pattern_type=pattern_type,
                    )
    return None


def classify_with_autonomous_fallback(text: str) -> Classification:
    variants = normalized_variants(text)
    tokenized_variants = [re.sub(r"[_:./\\-]+", " ", variant) for variant in variants]
    search_text = "\n".join(dedupe([*variants, *tokenized_variants]))
    for family, pattern_text, reason in AUTONOMOUS_FALLBACK_RULES:
        pattern = compile_rule(pattern_text)
        if pattern is not None and pattern.search(search_text):
            return Classification(
                family=family,
                source="autonomous_fallback",
                matched=reason,
                pattern_type="heuristic",
            )

    return Classification(
        family="elementwise",
        source="autonomous_fallback",
        matched="opaque input with no usable signal; final fallback",
        pattern_type="default",
    )


def classify(text: str, references: Path) -> Classification:
    pp_match = classify_with_pp(text, references / "op_family.md")
    if pp_match is not None:
        return pp_match

    json_match = classify_with_json(text, references / "classification_rules.json")
    if json_match is not None:
        return json_match

    return classify_with_autonomous_fallback(text)


def get_strategy_pool(text: str, references: Path) -> StrategyResult:
    classification = classify(text, references)
    candidate_pool = candidate_pool_for_family(classification.family, references / "op_family.md")
    return StrategyResult(
        classification=classification,
        optimization_candidate_pool=candidate_pool,
    )


def print_result(result: StrategyResult, args: argparse.Namespace) -> None:
    classification = result.classification
    if args.json:
        print(
            json.dumps(
                {
                    "family": classification.family,
                    "optimization_strategy_reference": result.optimization_candidate_pool,
                    "source": classification.source,
                    "matched": classification.matched,
                    "pattern_type": classification.pattern_type,
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return

    if args.explain:
        print(f"optimization_strategy_reference: {', '.join(result.optimization_candidate_pool)}")
        print(f"family: {classification.family}")
        print(f"source: {classification.source}")
        if classification.pattern_type:
            print(f"pattern_type: {classification.pattern_type}")
        if classification.matched:
            print(f"matched: {classification.matched}")
        return

    print(", ".join(result.optimization_candidate_pool))


def main() -> int:
    args = parse_args()
    text = read_input(args)
    result = get_strategy_pool(text, args.references)
    print_result(result, args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
