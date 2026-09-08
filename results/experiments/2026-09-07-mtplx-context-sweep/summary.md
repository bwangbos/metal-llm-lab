# MTPLX context sweep — 104GiB budget

Means ± sample standard deviations, three retained samples per point; one separate warm-up. All inputs uncached, 128 output tokens. Vision enabled; text-only synthetic repeated-token prompts.

| Input tokens | Prefill tok/s | Generation tok/s | Mean request seconds |
| ---: | ---: | ---: | ---: |
| 128 | 443.01 ± 1.57 | 79.01 ± 0.16 | 1.91 |
| 32,768 | 1309.57 ± 0.89 | 62.72 ± 0.39 | 27.08 |
| 65,536 | 1231.51 ± 10.88 | 55.84 ± 0.11 | 55.53 |
| 98,304 | 1164.26 ± 6.15 | 49.25 ± 0.23 | 87.06 |
| 131,072 | 1135.70 ± 2.50 | 43.97 ± 0.10 | 118.35 |
| 163,840 | 1111.05 ± 6.84 | 38.24 ± 0.58 | 150.86 |
| 196,608 | 1037.43 ± 28.96 | 35.89 ± 0.30 | 193.22 |
| 229,376 | 1072.16 ± 4.66 | 33.65 ± 0.19 | 217.80 |
| 261,888 | 1062.73 ± 1.07 | 31.41 ± 0.42 | 250.56 |

[Protocol and limitations](../../../docs/experiments/2026-09-07-mtplx-context-sweep.md) · [Measurements and provenance](measurements.json) · [Comparison](comparison.md)

Routing/acceptance details are retained per request in measurements.json. An admitted fixed-M4 lane does not imply every verification call uses its compiled M4 shape.

Host monitoring: 878 samples; minimum reported free percentage 18%. See measurements for pressure, swap and power observations.
