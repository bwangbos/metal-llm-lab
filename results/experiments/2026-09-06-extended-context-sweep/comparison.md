# Context scaling with a consistent 256K allocation

Apple M5 Max 128 GiB. Vision enabled, text-only synthetic repeated-token
prompts, uncached prefill, 128 generated tokens, one warm-up plus three retained
samples per cell. Values are mean **prefill / generation tokens per second**.

Fast-equivalent and stable-equivalent are newly measured custom configurations,
not changes to the shipped 32K presets. Long and auto are reused from the
[earlier preset sweep](../2026-09-06-preset-context-sweep/summary.md).
All four curves allocate 262144 tokens even at their near-zero prompt point.

| Prompt tokens | Fast-equivalent: tuned/MTP on | Stable-equivalent: upstream/MTP off | Long: tuned/MTP off | Auto: tuned/dynamic MTP |
| ---: | ---: | ---: | ---: | ---: |
| 128 | 576.8 / 86.4 | 470.1 / 39.8 | 523.8 / 48.3 | 524.3 / 74.7 |
| 32,768 | 985.3 / 47.4 | 748.4 / 30.2 | 972.2 / 44.7 | 899.0 / 46.3 |
| 65,536 | 754.6 / 31.7 | 651.2 / 24.5 | 892.6 / 42.0 | 923.0 / 42.3 |
| 98,304 | 683.6 / 25.2 | 601.3 / 20.7 | 851.0 / 40.3 | 884.8 / 41.3 |
| 131,072 | 676.8 / 22.2 | 559.9 / 18.3 | 850.6 / 40.2 | 864.3 / 40.1 |
| 163,840 | 637.4 / 19.3 | 530.5 / 15.7 | 845.2 / 39.8 | 823.4 / 37.4 |
| 196,608 | 598.0 / 16.9 | 490.2 / 14.1 | 840.4 / 39.7 | 808.1 / 38.6 |
| 229,376 | 562.4 / 14.9 | 453.2 / 12.6 | 795.4 / 38.3 | 780.9 / 37.9 |
| 261,888 | 536.4 / 13.8 | 454.8 / 11.8 | 767.0 / 37.5 | 760.7 / 37.2 |

The ceiling prompt leaves 256 tokens for output and runtime headroom.
Auto used MTP on at 128 and 32768 prompt tokens, off at all higher tested
points. Fixed-on MTP remained on throughout the fast-equivalent curve.

## Interpretation and limitations

Fixed-on MTP leads near-zero generation but scales much worse than the tuned
MTP-off curve in this workload. At near-full context, the observed generation
means are 13.76 (fixed-on), 11.76 (upstream off), 37.53 (tuned off), and 37.17
(dynamic). The 32K grid does not locate an exact crossover within 32K–64K.

These were sequential runs, not randomized contemporaneous controls. The
extended run encountered sleep/wake and AC/battery transitions around its
64K fast-equivalent warm-up; all retained samples were kept. The earlier auto
run encountered concurrent virtualization load, including a slower 160K
sample. Small differences or changes between runs cannot be attributed solely
to profile settings. Thermal state was not continuously measured. These are
synthetic throughput observations, not quality or realistic image-processing
benchmarks. See the [full protocol and caveats](../../../docs/experiments/2026-09-06-extended-context-sweep.md).

New evidence: [sample statistics](summary.md) and [measurements, identities,
and hashes](measurements.json). Earlier evidence:
[long/auto measurements](../2026-09-06-preset-context-sweep/measurements.json).
