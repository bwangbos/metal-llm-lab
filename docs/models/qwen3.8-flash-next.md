# Qwen3.8-Flash-Next

## Status and provenance

This repository's initial model path is Qwen3.8-Flash-Next. The artifact manifest
pins AtomicChat's 4.27 bpw Q4 text model (33 shards, 94,525,394,976 bytes), the
904,003,840-byte F16 vision projector, and the 2,786,568,256-byte Unsloth shared
Q8 MTP sidecar by source URL, license URL, byte count, and SHA-256. The choices
are locally tested artifact selections, not claims that one quantization is best
on every Apple Silicon system.

`stable` uses pinned upstream llama.cpp without the local Qwen/MTP patches.
`fast`, `vision`, and `long` use the experimental hybrid runtime at revision
`831e5d6f6e0d7b6c8d5757b1da41480ab33a0528`. The hybrid is an ordered patch
series rather than a claim of upstream support. Use `stable` when upstream
provenance matters more than the measured local throughput improvement.

## Profiles

| Profile | Context | Projector | MTP | Intended use |
| --- | ---: | --- | --- | --- |
| `fast` | 32,768 | No | Yes | Short text requests |
| `vision` | 32,768 | F16, 1,024 minimum image tokens | Yes | Image requests |
| `long` | 131,072 | No | No | Large-document work and repeatability |
| `stable` | 32,768 | No | No | Pinned upstream fallback |

All profiles use full Metal offload, `fit` off, Flash Attention on, mmap plus
lazy loading, and one request slot by default. Inspect the exact resolved command
without loading the model:

```sh
./bin/metal-llm serve qwen3.8-flash-next --profile vision --dry-run
```

The historical winning MTP server used this command tail (the current launcher
spells the same manifest choices using the runtime's accepted long options):

```text
-ngl all -c 32768 -fit off -fa on -lm mmap -lzm on -np 1 \
-md mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf \
--spec-type draft-mtp --spec-draft-n-max 2 -ngld all
```

The 131,072-token allocation succeeded during the recorded local session with
the hybrid target and MTP loaded. The current `long` profile intentionally omits
MTP because the later context study favored no-MTP at long context.

## Correctness evidence and limits

The recorded API, tool-calling, retrieval, structured-output, and six-case vision
checks passed. The vision suite covered a diagram, OCR, spatial reasoning, a
screenshot, a photo, and rejection of an unrelated image. A 64-token structured
output limit was exhausted by reasoning; `max_tokens=256` passed. Thinking tokens
therefore need explicit output budget, even when the visible JSON is short.

The short matched greedy MTP A/B produced byte-identical output, as did one
16,417-token calibration. Many other same-input requests diverged across routes,
and occasional repeats diverged within one route despite temperature 0 and seed
1234. Do not infer that MTP is behavior-neutral from the short matched run.

See the [generated result summary](../../results/summaries/qwen3.8-flash-next-m5-max.md),
[runtime comparison](../experiments/2026-09-03-runtime-comparison.md), and
[context crossover study](../experiments/2026-09-03-mtp-context-crossover.md).
