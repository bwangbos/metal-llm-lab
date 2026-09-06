# Extended fast/stable context sweep, 2026-09-06

Status: complete. All 18 cells, 54 retained samples, and 18 warm-ups passed
their token-count, non-truncation, uncached-prefill, and applicable routing
checks. Raw-response hashes were verified, and both managed session identities
confirmed custom/256K/vision-on with the intended runtime and MTP policy.
The benchmark process exited successfully after stopping its owned server.

Results: [four-curve comparison](../../results/experiments/2026-09-06-extended-context-sweep/comparison.md),
[new means and sample standard deviations](../../results/experiments/2026-09-06-extended-context-sweep/summary.md),
and [portable measurements and identities](../../results/experiments/2026-09-06-extended-context-sweep/measurements.json).
Raw responses and logs remain locally in `.lab/extended-context-2026-09-06`.
Repository revision: `1a58bbc2253442e4e62095a6514ae50aaf250332`.

User-requested extension of the [preset sweep](2026-09-06-preset-context-sweep.md).
These are custom configurations, not changes to the shipped presets:

| Curve | Runtime | MTP | Allocated context | Vision |
| --- | --- | --- | ---: | --- |
| fast-equivalent | tuned | on (including above 32K) | 262144 | on |
| stable-equivalent | upstream | off | 262144 | on |

Measure 128, 32768, 65536, 98304, 131072, 163840, 196608, 229376,
and 261888 effective prompt tokens. Repeat the short points with the 256K
allocation; do not splice in results from the original 32K allocation.
Reuse the previous long/auto measurements only as explicitly dated comparison
curves, not contemporaneous controls. No preset defaults or runtime code change.

Protocol matches the previous sweep: vision loaded but text-only synthetic
repeated-token prompts, one warm-up and three retained requests per cell,
128 generated tokens, temperature 0, seed 1234, no prompt-cache reuse,
one server at a time. Every response must pass exact input/output counts,
non-truncation, and (where exposed) MTP-route checks. Managed identity checks
also verify runtime, MTP policy, context allocation, and vision. Full raw
responses and logs stay in the ignored run directory; preserve failures too.

```sh
python3 -B tests/integration/benchmark_presets.py \
  --state-root STATE_ROOT --extended \
  --run-dir .lab/extended-context-2026-09-06
python3 -B tests/integration/summarize_presets.py \
  .lab/extended-context-2026-09-06 \
  results/experiments/2026-09-06-extended-context-sweep
```

The state root supplies existing verified artifacts and builds; its model and
runtime manifests must match the code checkout. The launcher uses cached
artifact verification with its normal invalidation rules. Experiment and
managed session records capture source, manifest, executable, and artifact
hashes. Hardware: Apple M5 Max 128 GiB, macOS 26.4 (25E246).

Before launch, no llama-server, llama-bench, or benchmark_presets process was
present. The highest sampled CPU consumer was the assistant process at 97.5%
(about one core); no heavily loaded virtualization process appeared among the
top consumers. These are snapshots, not proof of exclusive machine access.
Sequential-run thermal/background-load drift remains a limitation; synthetic
throughput does not establish model quality or typical chat throughput.

During the fast-equivalent 64K warm-up, prefill took 581.83 seconds
(112.64 tokens/s). The macOS power log showed sleep/dark-wake activity and
repeated AC/battery transitions around 07:31–07:33 local time. Subsequent
retained 64K samples were much faster, but the power-state disturbance means
this stretch is not a clean controlled comparison. The warm-up and all three
retained responses are preserved without replacement. A process snapshot
showed the existing virtualization process at about 24 GB RSS but only 1.3%
CPU; the thermal-status query failed to return warning levels, so no claim
about absence of throttling can be made from that check.

Review notes: upstream does not expose the tuned runtime's response-level
MTP routing field; stable-equivalent's MTP-off setting is verified from the
managed session identity instead. Before resuming any failed sample, preserve
its existing raw response separately or choose a fresh run directory: the
current harness reuses the raw filename for a sample without a success record.
This run has had no failed retained sample or resumption. Do not modify the
active harness because its hash is part of the experiment identity.

Final audit checked all 54 retained records through the exporter and all 18
warm-up records separately against raw responses. The harness hash still
matched the experiment identity. A read-only review found no critical or
important issue invalidating this local sweep; its minor reporting and
retry-preservation qualifications are reflected above. No runtime, model,
profile defaults, or system settings were changed. Collection finished before
the subsequent user-requested publication of these notes and results.
