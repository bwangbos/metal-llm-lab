# Qwen3.8-Flash-Next

## Status and provenance

This repository's initial model path is Qwen3.8-Flash-Next. The artifact manifest
pins AtomicChat's 4.27 bpw Q4 text model (33 shards, 94,525,394,976 bytes), the
904,003,840-byte F16 vision projector, and the 2,786,568,256-byte Unsloth shared
Q8 MTP sidecar by source URL, license URL, byte count, and SHA-256. The choices
are locally tested artifact selections, not claims that one quantization is best
on every Apple Silicon system.

The `tuned` runtime is the ordered Qwen/MTP patch series at tested revision
`b814e84c45f00fb0d9f3283175acc1a24fa90b95` and tested tree
`4f3c051ed7ae4e856cb6d7d95f5c1af6984fc72d`. The `upstream` runtime is pinned
llama.cpp revision `de8656bd94f1163188125542534e4bcbc9f9fb1f` and tree
`ef599001012ff8bee837a832decde4c564702cc4` without the local patch series.
Both are Metal builds; the difference is the runtime source plus MTP policy.
The `stable` preset is upstream reference-only and not recommended for normal
operation.

## Profiles

| Profile | Runtime | Context | MTP policy | Status |
| --- | --- | ---: | --- | --- |
| `fast` | `tuned` | 32,768 | `on` | Supported short-request preset |
| `long` | `tuned` | 262,144 | `off` | Supported policy; full allocation pending acceptance |
| `auto` | `tuned` | 262,144 | `dynamic` | Implemented; pending hardware acceptance |
| `stable` | `upstream` | 32,768 | `off` | Reference only; not recommended |

Vision defaults on independently for every preset and loads the pinned F16
projector with a 1,024-token image minimum. Append `--vision off` to any preset
or custom configuration to omit it. All profiles use full Metal offload, `fit`
off, Flash Attention on, mmap plus lazy loading, and one request slot by default.
Inspect the default dynamic command without loading the model:

```sh
./bin/metal-llm serve qwen3.8-flash-next --dry-run
```

The historical winning MTP server used this command tail (the current launcher
spells the same manifest choices using the runtime's accepted long options):

```text
-ngl all -c 32768 -fit off -fa on -lm mmap -lzm on -np 1 \
-md mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf \
--spec-type draft-mtp --spec-draft-n-max 2 -ngld all
```

The earlier 131,072-token allocation succeeded during a recorded local session
with the target and MTP loaded. That does not establish that the current
262,144-token target, projector, and MTP configuration fits together. `auto`
therefore remains pending acceptance, and the `long` preset intentionally omits
MTP because the context study favored no-MTP at long context.

Dynamic routing uses the fixed threshold of 32,768 effective prompt tokens.
Effective length includes template and image expansion: counts at or below the
threshold use MTP, while counts above it do not. The route remains fixed for the
response and is reported in final timing metadata. See the root README for exact
custom equivalents and the integration command.

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
