# Preset context sweep on Apple M5 Max 128 GB

Vision on, text-only repeated-token prompts; one warm-up and three retained samples per cell.
Each response generates 128 tokens. Ceiling prompts leave 256 tokens of space.
Values are mean ± sample standard deviation in tokens/s. All retained responses passed count, truncation, route, and uncached-prefill checks.

| Profile | Prompt tokens | Prefill tok/s | Generation tok/s | MTP selected |
| --- | ---: | ---: | ---: | :---: |
| fast | 128 | 575.47 ± 1.10 | 86.07 ± 0.08 | on |
| fast | 32,512 | 894.75 ± 28.01 | 45.42 ± 1.24 | on |
| stable | 128 | 478.31 ± 4.55 | 40.23 ± 0.27 | off |
| stable | 32,512 | 754.39 ± 21.74 | 30.93 ± 0.75 | off |
| long | 128 | 523.84 ± 8.89 | 48.33 ± 0.22 | off |
| long | 32,768 | 972.25 ± 21.66 | 44.72 ± 0.73 | off |
| long | 65,536 | 892.58 ± 2.03 | 41.97 ± 0.04 | off |
| long | 98,304 | 850.97 ± 8.89 | 40.28 ± 0.35 | off |
| long | 131,072 | 850.62 ± 13.31 | 40.20 ± 0.30 | off |
| long | 163,840 | 845.16 ± 0.54 | 39.82 ± 0.22 | off |
| long | 196,608 | 840.35 ± 5.27 | 39.72 ± 0.26 | off |
| long | 229,376 | 795.44 ± 0.06 | 38.32 ± 0.21 | off |
| long | 261,888 | 767.00 ± 2.65 | 37.53 ± 0.03 | off |
| auto | 128 | 524.31 ± 4.43 | 74.74 ± 1.90 | on |
| auto | 32,768 | 898.98 ± 9.63 | 46.30 ± 0.71 | on |
| auto | 65,536 | 923.02 ± 1.41 | 42.30 ± 0.34 | off |
| auto | 98,304 | 884.79 ± 12.70 | 41.26 ± 0.22 | off |
| auto | 131,072 | 864.35 ± 1.96 | 40.13 ± 0.15 | off |
| auto | 163,840 | 823.39 ± 20.94 | 37.37 ± 3.37 | off |
| auto | 196,608 | 808.06 ± 1.16 | 38.60 ± 0.16 | off |
| auto | 229,376 | 780.91 ± 3.72 | 37.87 ± 0.22 | off |
| auto | 261,888 | 760.69 ± 0.32 | 37.17 ± 0.02 | off |

Concurrent virtualization load was observed during the auto run, following its slower third 160K sample. All samples are retained; small between-profile differences are not isolated causal effects.

Evidence: [measurements.json](measurements.json).
Protocol and limitations: [experiment notes](../../../docs/experiments/2026-09-06-preset-context-sweep.md).
