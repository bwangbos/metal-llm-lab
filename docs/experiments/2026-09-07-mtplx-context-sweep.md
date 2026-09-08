# MTPLX 104GiB context sweep

Status: complete September 7. All nine cells, nine warm-ups and 27 retained
samples passed exact-count, zero-prefix-reuse and routing-policy validation.
Raw response/request hashes and all exported means/standard deviations were
audited against the saved evidence. No failed or replaced sample.

Results: [five-curve comparison](../../results/experiments/2026-09-07-mtplx-context-sweep/comparison.md),
[means and standard deviations](../../results/experiments/2026-09-07-mtplx-context-sweep/summary.md),
[portable measurements](../../results/experiments/2026-09-07-mtplx-context-sweep/measurements.json).

User requested a near-zero to near-max sweep comparable to the existing
[256K-allocation four-profile readout](../../results/experiments/2026-09-06-extended-context-sweep/comparison.md).

## Protocol

- Apple M5 Max 128GiB; pinned MTPLX 2.11.2 and Optimized Speed snapshot
  `6bc2f6e8426ccb4af73c81bc56ba7718afc92cc6`; details and checksums in the
  [initial evaluation](2026-09-06-mtplx-evaluation.md).
- 104GiB allocation budget, unchanged default wired limit, Apple-managed fans,
  turbo profile, MTP on/depth 3, vision loaded, 262144 context at every point.
  Budget rationale: [admission experiment](2026-09-07-mtplx-memory-budget.md).
- Exactly 128, 32768, 65536, 98304, 131072, 163840, 196608, 229376, 261888
  raw input tokens. Repeated ` x` token ID 830, verified with pinned tokenizer.
- One warm-up plus three retained samples per cell; 128 output tokens,
  temperature 0, seed 1234, single serial request. Text-only workload.
- `/v1/completions` with token IDs avoids chat-template overhead. Clear only
  candidate session/allocator cache before every request; require zero reused
  tokens in usage and internal metrics. Weights remain loaded; this is uncached
  prompt prefill, not a disk-cold weight-loading test.
- The route does not implement llama.cpp's `ignore_eos` option. Do not silently
  send an ignored flag: require exactly 128 outputs on every response, and stop
  on any short completion. OpenAI `finish_reason: length` is expected when the
  requested output cap is reached; it is not evidence of input truncation.
  Require exact prompt count and retain 128 context tokens of spare headroom.
- Record public timing fields, raw request/response hashes, internal MTP route,
  admission, compilation and acceptance metrics. Timing table uses public
  `prompt_per_second` / `predicted_per_second`; MTPLX calculates decode duration
  as generation elapsed minus prefill and cache restore, so cross-runtime timer
  boundaries may differ slightly. Preserve native internal timings too.
- Host memory/swap/power sampled every five seconds. Stop only the verified
  candidate server on critical host pressure, reported free below 8%, or swap
  exceeding 128MiB. No global settings or unrelated processes changed.
- A temporary `caffeinate -i -w SERVER_PID` idle-sleep assertion was added as
  the 128K warm-up completed; it ends with the owned server. No persistent
  power setting changed. Earlier cells had no such explicit assertion.

## Evidence and validation

All repository checks passed before collection. Raw-completion calibration
confirmed exact 128/128 counts and zero prefix reuse. The initially zero MTP
draft counters were not low acceptance: internal metrics identify the stock
context-copy proposal route (e.g. 64 rounds, 64 copied tokens drafted and all
64 accepted in the 64K sample). Preserve this default runtime behavior.
Configured depth-3 MTP does not mean neural MTP proposals are used in every
round. Fixed-M4 can be admitted while compiled M4 calls stay zero because the
context-copy verifier uses a different block shape; this is not memory fallback.

Raw run: `.lab/mtplx-evaluation/context-sweep-20260907-100646/`.
Frozen harness: `.lab/mtplx-evaluation/benchmark_context.py` (hash recorded in
experiment identity); server log `launch-sweep-104gib-2026-09-07.log`.
Every sample is written to a new file; errors preserve evidence and stop.

## Comparison limitations

This compares complete setups, not runtimes holding quantization constant:
the older AtomicChat AD-4.27bpw Q4_K_M-M64 GGUF differs from this MLX pack.
Prior long/auto and extended fast/stable results are dated September 6, not
contemporaneous controls; their power/background-load caveats still apply.
MTP remains on throughout this candidate curve, unlike existing `auto` above
32K. A synthetic repeated-token sweep is not a model-quality, typical chat,
vision-processing or long-output stability benchmark. No production promotion.

## Completed-run observations

- MTPLX prefill means exceeded the prior auto/long curves at 32K and above;
  near-zero prefill was lower. Compared with prior auto generation means, MTPLX
  was higher through 160K and lower at 192K, 224K and near-full. Small differences
  must be interpreted with cross-day/background-load limitations.
- Near-full mean: 1062.73 prefill tok/s, 31.41 generation tok/s, 250.56s wall
  time for 261888 uncached inputs plus 128 outputs.
- All 36 requests admitted fixed-M4 memory promotion. All actually used the
  stock context-copy route: 64 copy rounds, 64 copied draft tokens and 64
  accepted copy tokens per request, zero compiled-M4 calls. This is a different
  route from the earlier key-retrieval admission test; zero compiled calls here
  are not a memory-budget fallback. Retain raw metrics for each request.
- 878 five-second host observations: pressure level 1 (normal), zero swap,
  AC power throughout; minimum reported free percentage 18%. Sampling does not
  establish continuous thermal state or rule out brief between-sample events.
- Collector exited 0. Owned server stopped with SIGTERM (exit 143), process
  absence verified; temporary idle-sleep assertion exited 0 automatically.
  Existing production profiles unchanged; no publishing performed.
