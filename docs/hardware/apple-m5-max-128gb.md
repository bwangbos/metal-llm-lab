# Apple M5 Max, 128 GB

The recorded measurements used an Apple M5 Max with a 40-core GPU and 128 GB
unified memory, on AC power with Low Power Mode off. Builds used AppleClang 21,
Release mode, native ARM, Metal, and Accelerate. These details describe one local
test system; they are not performance promises for other machines.

Metal reported a 115,448.73 MB recommended maximum working set. The selected
94.5 GB text model leaves headroom for runtime buffers, KV state, the 2.79 GB MTP
sidecar, and the 904 MB vision projector. Larger artifact choices or concurrent
model processes can exhaust that headroom.

The earlier 131,072-token server allocation passed. A 250,000-token synthetic
cache-depth benchmark also completed while `iogpu.wired_limit_mb` remained
automatic (`0`), `memory_pressure -Q` reported 40% effective free memory, and
`vm_stat` showed no throttled pages. The later acceptance run directly proved
that the `auto` configuration can load the target, projector, MTP sidecar, and a
262,144-token context together on this exact host. A fresh accepted-default
observation at 2026-09-04T15:56:55Z recorded server RSS of 69892685824 bytes
and 43% system-wide effective free memory; the validated raw result and generated
summary retain its managed-process, server-log, and observation hashes. This is a
point-in-time observation, not a peak-memory claim. The launcher must still fail
rather than silently reducing context or disabling a capability. This project
does not change memory-wire limits, macOS power settings, or other system
settings.

Only one full-model process is supported. A second process failed prompt-batch
decoding with result `-3` while the server held the model, then succeeded after
the server stopped. Normal `metal-llm serve` and local `metal-llm bench` runs
share a live-process lease across checkouts using the same per-user/session
`TMPDIR`; local benchmarking also refuses a responding configured lab endpoint.
The lease does not cover model processes started outside the harness, so stop
those manually before running local `llama-bench`.

The real dynamic-MTP acceptance harness is deliberately opt-in and matches this
manifest exactly: `Apple M5 Max`, `arm64`, and 137,438,953,472 bytes (128 GiB) of
unified memory. It requires an already verified tuned build receipt and all
verified model artifacts, refuses a pre-existing managed lease, and neither
downloads nor builds anything:

```sh
METAL_LLM_INTEGRATION=1 zsh tests/integration/test_dynamic_mtp.sh
```

The integration evidence and the complete performance matrix passed; see the
[acceptance record](../experiments/2026-09-03-dynamic-mtp-acceptance.md). The
result is machine-specific and does not rewrite the prior measurements.

Machine-readable identity is in
[`manifests/hardware/apple-m5-max-128gb.json`](../../manifests/hardware/apple-m5-max-128gb.json),
and measurements are in the [raw result](../../results/raw/2026-09-03-qwen38-m5-max.json).
