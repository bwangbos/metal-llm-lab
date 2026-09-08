# Qwen3.8 setup comparison across context

Apple M5 Max 128GiB. Each entry is **prefill / generation tok/s** (mean of three retained samples). All curves allocate 262144 context, with vision enabled and text-only repeated-token inputs.

| Input tokens | Existing fast-equivalent | Existing stable-equivalent | Existing long | Existing auto | MTPLX turbo, 104GiB |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 128 | 576.8 / 86.4 | 470.1 / 39.8 | 523.8 / 48.3 | 524.3 / 74.7 | 443.0 / 79.0 |
| 32,768 | 985.3 / 47.4 | 748.4 / 30.2 | 972.2 / 44.7 | 899.0 / 46.3 | 1309.6 / 62.7 |
| 65,536 | 754.6 / 31.7 | 651.2 / 24.5 | 892.6 / 42.0 | 923.0 / 42.3 | 1231.5 / 55.8 |
| 98,304 | 683.6 / 25.2 | 601.3 / 20.7 | 851.0 / 40.3 | 884.8 / 41.3 | 1164.3 / 49.2 |
| 131,072 | 676.8 / 22.2 | 559.9 / 18.3 | 850.6 / 40.2 | 864.3 / 40.1 | 1135.7 / 44.0 |
| 163,840 | 637.4 / 19.3 | 530.5 / 15.7 | 845.2 / 39.8 | 823.4 / 37.4 | 1111.1 / 38.2 |
| 196,608 | 598.0 / 16.9 | 490.2 / 14.1 | 840.4 / 39.7 | 808.1 / 38.6 | 1037.4 / 35.9 |
| 229,376 | 562.4 / 14.9 | 453.2 / 12.6 | 795.4 / 38.3 | 780.9 / 37.9 | 1072.2 / 33.6 |
| 261,888 | 536.4 / 13.8 | 454.8 / 11.8 | 767.0 / 37.5 | 760.7 / 37.2 | 1062.7 / 31.4 |

Existing curves were measured September 6; MTPLX September 7. Different quants, APIs and timing boundaries mean this is an end-to-end setup comparison, not an isolated runtime speedup. Previous power/background-load caveats remain applicable.

MTPLX uses fixed depth-3 MTP throughout; existing auto disables MTP above 32768. Fast/stable-equivalent are custom 256K configurations, not changes to their shipped 32K presets.

MTPLX uses its stock context-copy proposal route on this repeated-token workload; configured MTP depth does not mean neural MTP drafting runs in every round. Do not extrapolate this workload to chat, coding, model quality or image-processing speed.

[MTPLX statistics](summary.md) · [Protocol](../../../docs/experiments/2026-09-07-mtplx-context-sweep.md) · [Previous readout and caveats](../2026-09-06-extended-context-sweep/comparison.md)
