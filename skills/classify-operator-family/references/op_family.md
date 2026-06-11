| Torch算子 | family | 优化策略参考（按优先顺序） |
| --- | --- | --- |
| scaled_dot_product_attention / flash_attention / sparse_attention | attention | STRUCTURAL, KERNEL_FUSION, TILE_REFINEMENT, DTE_PIPELINE, MICRO_ARCH |
| mm / bmm / addmm / linear / matmul | matmul | STRUCTURAL, KERNEL_FUSION, TILE_REFINEMENT, DTE_PIPELINE, MICRO_ARCH |
| softmax / log_softmax | softmax | ALGORITHM_SUBSTITUTION, HARDWARE_DISPATCH, MICRO_ARCH, DTE_PIPELINE, FINE_TUNING |
| layer_norm / rms_norm / batch_norm / group_norm | norm | ALGORITHM_SUBSTITUTION, HARDWARE_DISPATCH, MICRO_ARCH, DTE_PIPELINE, FINE_TUNING |
| sum / mean / max / argmax / reduce_* | reduction | HARDWARE_DISPATCH, MICRO_ARCH, DTE_PIPELINE, FINE_TUNING |
| relu / sigmoid / tanh / exp / log / sqrt | elementwise | STRUCTURAL, MICRO_ARCH, FINE_TUNING, EXPLORATION |
| swiglu / silu / gelu / geglu / mish | elementwise_complex | STRUCTURAL, MICRO_ARCH, FINE_TUNING, EXPLORATION |
| conv2d / conv1d / depthwise_conv | convolution | STRUCTURAL, MICRO_ARCH, FINE_TUNING, EXPLORATION |
| max_pool / avg_pool / adaptive_pool | pooling | STRUCTURAL, MICRO_ARCH, FINE_TUNING, EXPLORATION |
| cumsum / cumprod | scan | STRUCTURAL, MICRO_ARCH, FINE_TUNING, EXPLORATION |
| sort / topk / argsort | sort_search | STRUCTURAL, MICRO_ARCH, FINE_TUNING, EXPLORATION |
| gelu_linear / fused_norm_act / fused_silu_linear | fusion_simple | STRUCTURAL, MICRO_ARCH, FINE_TUNING, EXPLORATION |
| gru / lstm / causal_conv1d | recurrent | STRUCTURAL, MICRO_ARCH, FINE_TUNING, EXPLORATION |
