# Preset context sweep, 2026-09-06

Status: complete. All 22 cells and 66 retained samples passed validation.
The owned benchmark server exited after collection.

Results: [means and sample standard deviations](../../results/experiments/2026-09-06-preset-context-sweep/summary.md)
and [portable measurements and runtime identities](../../results/experiments/2026-09-06-preset-context-sweep/measurements.json).
Raw responses, warm-ups, and server logs remain locally under
`.lab/preset-benchmark-2026-09-06-v2`; the portable export includes their
retained-response and server-log hashes, not the full raw files.

Host: Apple M5 Max, 128 GiB memory, macOS 26.4 (25E246).
Repository revision: `1a58bbc2253442e4e62095a6514ae50aaf250332`.
The exported experiment and session identities record harness, manifests,
runtime, executable, and artifact hashes.

Observed generation means were 86.07 tokens/s for `fast` near zero context,
74.74 for `auto`, 48.33 for `long`, and 40.23 for `stable`. At 261,888 prompt
tokens, `long` reached 37.53 and `auto` 37.17 tokens/s. Auto selected MTP on
at 128 and 32,768 prompt tokens and off at every higher tested point.
These are actual preset comparisons, including their differing allocations,
not an isolated test of the cost of dynamic routing. Background-load and
sequential-run caveats below apply.

Measure the actual `fast`, `stable`, `long`, and `auto` presets on the
Apple M5 Max 128 GiB host with vision enabled. The requests are text-only;
the projector stays loaded. `custom` is a configuration interface, not a preset.

Use a 128-token near-zero prompt, then 32,768-token increments. Reserve 256
tokens at the context ceiling (128 output plus 128 runtime headroom): the last
prompt is 32,512 for the 32K presets or 261,888 for the 256K presets. This means the final short-preset
row differs from the 32,768-token row of the long presets. Record exact counts.

Each cell has one discarded warm-up followed by three retained samples.
Use repeated tokenizer-derived ` x` token IDs, `/completion`, temperature 0,
seed 1234, 128 output tokens, `ignore_eos=true`, `cache_prompt=false`, and one
request slot. Calibrate any automatic special-token offset per server. This
matches the synthetic workload family of the prior dynamic-MTP acceptance
matrix; it is a throughput study, not a model-quality evaluation.

Collect one server at a time in order fast, stable, long, auto. Preserve all
responses, warm-ups, logs, timing metadata, managed identities, payload/output
hashes, and sample means/sample standard deviations. Reject unexpected MTP
routes, truncation, short output, or prefill using a reused prefix. Stop only
the exact child process started by this harness. Resume completed cells only
when the experiment identity matches.

The harness uses current repository launcher libraries with an explicit state
root containing previously built runtimes and weights. It requires model and
runtime manifests to match the code checkout byte-for-byte. The normal
launcher performs artifact and runtime verification and acquires the shared
full-model lease. No runtime flags are changed from the preset.

Example (state root may be an existing checkout with verified `.lab` assets):

```sh
python3 tests/integration/benchmark_presets.py \
  --state-root STATE_ROOT \
  --run-dir .lab/preset-benchmark-2026-09-06-v2
python3 -B tests/integration/summarize_presets.py \
  .lab/preset-benchmark-2026-09-06-v2 \
  results/experiments/2026-09-06-preset-context-sweep
```

Limitations: sequential collection may include thermal, memory-residency, and
background-load drift. Prompt prefill is measured without prefix reuse, while
weights may be resident after warm-up. Allocation success and full-context
throughput are separate observations. Do not infer output equivalence between
profiles from throughput alone.

The first attempted ceiling warm-up used a 32,640-token prompt plus 128 output
tokens. It produced all 128 tokens but the runtime marked the response truncated
when the context-capacity guard fired. That response is preserved in the first
attempt directory and excluded from the revised sweep. The revised run uses
the additional 128-token runtime headroom consistently across profiles.

During auto's third 163,840-token sample, generation fell to 33.48 tokens/s
from approximately 39.3 in the first two samples. A subsequent process snapshot
during the next warm-up showed a virtualization process using 245.5% CPU and
approximately 24 GB RSS. System effective free memory was 43%; `pmset -g therm`
reported no recorded thermal or performance warning. This is evidence of
concurrent load, not proof of causation. Retain the sample and consider the
sequential-run/background-load limitation when comparing preset means.
