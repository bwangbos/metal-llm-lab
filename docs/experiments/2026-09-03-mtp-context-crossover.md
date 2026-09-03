# MTP context crossover — 2026-09-03

## Configuration

The study used hybrid llama.cpp revision
`831e5d6f6e0d7b6c8d5757b1da41480ab33a0528`, the AtomicChat 4.27 bpw Q4 target,
and the F16 projector configured for at least 1,024 image tokens. Both arms used
Metal, all target layers on GPU, 131,072 context allocation, fit off, Flash
Attention on, mmap and lazy loading, one slot, no prompt-cache reuse, reasoning
off, temperature 0, seed 1234, and at most 256 generated tokens. The MTP arm alone
loaded the Unsloth shared Q8 sidecar, used `draft-mtp`, allowed at most two draft
tokens, and placed all draft layers on GPU.

The [raw result](../../results/raw/2026-09-03-qwen38-m5-max.json) is the source
for both tables in the
[generated summary](../../results/summaries/qwen3.8-flash-next-m5-max.md).
Attached-image rows are single runs. The five text-only boundary rows are
three-run means with sample standard deviations. Other text-only calibration
rows are single runs. These historical rows retained the 256-token output cap,
but not the actual generated-token counts, so the raw result records those
counts as `null` rather than presenting the cap as a measurement. Repository
profile identifiers also postdate this capture and are therefore `null`.

## Findings

For the same attached-image workload, the measured crossover was bracketed by
32,844 tokens (no MTP 30.1183, MTP 36.8054 tok/s) and 33,868 tokens (no MTP
36.6638, MTP 34.3194 tok/s). Linear interpolation gives approximately 33.6K,
but that is only a workload-specific point estimate. The route data are
non-monotonic, so the bracket is the stronger measured statement.

The vision-loaded, text-only repeats place the practical general-purpose gray
zone around 29–30K effective tokens. For this configuration, use MTP below 28K,
prefer no-MTP at or above 30K, and favor no-MTP inside the gray zone when
repeatability matters.

The earlier 96K retrieval's 23.80 tok/s used MTP; it is not a no-MTP baseline.
Correct no-MTP measurements were 34.4737 tok/s at 99,405 effective tokens with
an attached image and 36.6619 tok/s at 98,338 text tokens with the projector
resident.

## Output behavior and limitations

The 16,417-token text calibration produced byte-identical output between arms.
Many other same-input greedy requests did not. Repeated requests within one mode
also occasionally differed despite temperature 0 and seed 1234. A fixed visible
string grammar was rejected as a token-path control because the same bytes used
varying BPE segmentations and completion-token counts.

This study therefore measures operational throughput, not a universally fixed
compute-only crossover, and it does not establish zero behavioral effect from
MTP. Per-request routing is future work described in
[ADR 0002](../decisions/0002-dynamic-mtp-direction.md).
