# Dynamic MTP acceptance on Apple M5 Max 128 GiB

- Decision: Pass; promote `auto` to `recommended` for the exact tested configuration.
- Measurement date: 2026-09-04
- Raw result: [`../../results/raw/2026-09-03-qwen38-dynamic-mtp.json`](../../results/raw/2026-09-03-qwen38-dynamic-mtp.json)
- Generated summary: [`../../results/summaries/qwen3.8-flash-next-dynamic-mtp.md`](../../results/summaries/qwen3.8-flash-next-dynamic-mtp.md)

## Scope and method

The acceptance target was the pinned Qwen3.8-Flash-Next artifact set on the exact
Apple M5 Max 128 GiB manifest, using the trusted tuned runtime tree, full Metal
offload, vision enabled, and a 262,144-token allocation. A default dynamic server
became healthy with the target, projector, and MTP sidecar loaded, establishing
that the complete allocation fits without a Metal allocation failure. The fresh
accepted-default observation at 2026-09-04T15:56:55Z recorded server RSS of
69892685824 bytes and 43% system-wide effective free memory. The raw result
retains that sanitized point-in-time observation together with immutable
observation (`25e70cbdb5d567f259f6bcc8b2d3e8451c7ad5ba8ad1b18551c27f04feb05949`),
managed-process (`2a6cc52173a0802e7fb8123bf108c30d1b23b307f309adb7ea3b147fe2b3e257`),
and final server-log (`b4ee3e60af289807d60d33be2ccfcc0e673ef836d8cdf03cf81ff346133892ab`)
SHA-256 identities. It does not claim peak memory usage.

Correctness and isolation used the opt-in integration harness. Its 19 retained
rows covered threshold boundaries, multimodal expansion, streaming, slot reuse,
concurrent opposite routes, deterministic correctness cases, and the one-process
rule. The tracked [19-row correctness evidence](../../results/raw/2026-09-03-qwen38-dynamic-mtp-correctness.json)
has SHA-256
`9df71ed12fcca3fba1fcc3a361c62b22d59b3e3c04fde255570ee1cb48955a16`.

Performance used one full-model process at a time for fixed-on, fixed-off, and
dynamic policy. Each policy measured effective prompt lengths 29,000, 30,000,
32,767, 32,768, 32,769, 33,868, and 98,304. Every cell used one warm-up and five
retained requests, generated 128 tokens, and used identical deterministic
settings. All 105 rows, output hashes, routes, individual throughput values,
means, sample standard deviations, draft counters, and provenance are in the raw
result. The predeclared gate required each dynamic generation-throughput mean to
be within 5% of its corresponding fixed route.

## Result

All correctness, isolation, allocation, route, matrix-completeness, and
performance gates passed. Dynamic selected MTP through 32,768 effective tokens
and selected conventional decoding above it. At 32,767, dynamic averaged
44.778118828762345 tok/s versus fixed-on 44.2195854504937 tok/s, a
+1.2630904893804473% delta. At 32,769, dynamic averaged 43.14954799180947 tok/s
versus fixed-off 41.1303088964011 tok/s, a +4.909370120449208% delta. That latter
comparison passed by only 0.090629879550792 percentage points and is the
narrowest acceptance margin. The generated summary derives all seven comparisons
and all 21 per-cell statistics from the validated raw document.

## Recovery and invalidated attempts

A host power loss removed the earlier collector's temporary scratch after at
least 83 of 105 samples. No durable row file survived, and conversation prose is
not measurement evidence, so collection restarted at zero and none of those
observations were reconstructed.

The recovery work first added crash-durable, strictly bound checkpoints. A later
recovery attempt retained 35 fixed-on rows before the fixed-off transition
exposed two defects: loaded-artifact validation incorrectly required the MTP
sidecar under fixed-off, and a function-call context could suppress a returned
failure and print a false healthy line. The complete 35-row checkpoint, responses,
and server logs were preserved under `.lab/task6-diagnostics/` with a hash
inventory. Because the fix changed collector identity, those rows were
invalidated and the canonical run again restarted at zero.

An interrupted, noncanonical run had also shown roughly an 18.5% slowdown for
dynamic 32,767. It did not reproduce: the corrected canonical cell was +1.2631%
versus fixed-on. The noncanonical observation remains disclosed as recovery
history but is not mixed into the raw result.

## Limitations

These are machine-specific local measurements under the recorded OS, compiler,
runtime, artifact, and AC-power identities. The narrow 32,769 margin merits a
repeat after any relevant identity changes. Output hashes are retained, but
matching throughput and route selection do not establish behavioral equivalence
between speculative and conventional decoding.
