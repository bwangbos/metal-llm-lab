# Apple M5 Max, 128 GB

The recorded measurements used an Apple M5 Max with a 40-core GPU and 128 GB
unified memory, on AC power with Low Power Mode off. Builds used AppleClang 21,
Release mode, native ARM, Metal, and Accelerate. These details describe one local
test system; they are not performance promises for other machines.

Metal reported a 115,448.73 MB recommended maximum working set. The selected
94.5 GB text model leaves headroom for runtime buffers, KV state, the 2.79 GB MTP
sidecar, and the 904 MB vision projector. Larger artifact choices or concurrent
model processes can exhaust that headroom.

The 131,072-token server allocation passed. A 250,000-token synthetic cache-depth
benchmark also completed while `iogpu.wired_limit_mb` remained automatic (`0`),
`memory_pressure -Q` reported 40% effective free memory, and `vm_stat` showed no
throttled pages. This project did not change memory-wire limits, macOS power
settings, or other system settings.

Only one full-model process is supported. A second process failed prompt-batch
decoding with result `-3` while the server held the model, then succeeded after
the server stopped. Normal `metal-llm serve` and local `metal-llm bench` runs
share a live-process lease across checkouts using the same per-user/session
`TMPDIR`; local benchmarking also refuses a responding configured lab endpoint.
The lease does not cover model processes started outside the harness, so stop
those manually before running local `llama-bench`.

Machine-readable identity is in
[`manifests/hardware/apple-m5-max-128gb.json`](../../manifests/hardware/apple-m5-max-128gb.json),
and measurements are in the [raw result](../../results/raw/2026-09-03-qwen38-m5-max.json).
