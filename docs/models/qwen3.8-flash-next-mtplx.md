# Qwen3.8 Flash Next — MTPLX package

Integration status: implementation and offline validation accepted; live
acceptance of the managed integration is pending. The earlier experimental
server is not acceptance evidence for the new launcher. The existing
`qwen3.8-flash-next` `auto` profile remains the recommendation on its qualified
M5 Max 128 GiB configuration.

Source availability is approved for the main repository. Use the normal
checkout and the commands below; no experimental worktree or private helper
is required. Publishing the integration does not mark the pending live checks
as passed.

This package and `qwen3.8-flash-next` use the same underlying model family but
different quantized weight packages and runtimes. Selecting one selects the
whole setup; this is not a backend toggle for identical weights.

## Install and serve

After the repository's macOS bootstrap and doctor checks:

Python 3.12 must be available for the pinned runtime. Setup creates its own
environment and installs locked packages there; it does not install a global
Python interpreter or change your system packages. The repository bootstrap is
a prerequisite check, not a silent package-manager installation.
If Python 3.12 is not named `python3.12` on your `PATH`, set `METAL_LLM_PYTHON`
to its executable when running setup.

For an existing checkout, update first with `git pull --ff-only`. Run setup in
the checkout you intend to use: model and runtime storage are managed locally
under that checkout's `.lab` directory, not implicitly shared with worktrees.

```sh
./bin/metal-llm setup qwen3.8-flash-next-mtplx --dry-run
./bin/metal-llm setup qwen3.8-flash-next-mtplx
./bin/metal-llm serve qwen3.8-flash-next-mtplx --dry-run
./bin/metal-llm serve qwen3.8-flash-next-mtplx
```

The snapshot is 115,061,253,338 bytes (approximately 115.1 GB / 107.2 GiB),
plus the isolated Python environment, package downloads and operational cache
space. Download size is not resident-memory usage: the approximately 29.8 GiB
external n-gram table is file-backed. Keep it on fast local SSD storage.
Do not treat SSD offload as proof that arbitrary smaller-memory Macs fit.

To reuse a previously downloaded complete snapshot, replace the placeholder
with its directory, not an environment directory or a Hugging Face repository ID:

```sh
./bin/metal-llm setup qwen3.8-flash-next-mtplx --import-from /path/to/snapshot
```

Import verifies and copies into managed storage. It does not delete the source;
budget enough disk space for both copies. The resulting installation must not
depend on an evaluation worktree. Do not remove an old snapshot while another
process might still be using it.

Cached artifact verification is the default. `--artifact-check full` requests
a complete rehash; use it after suspicious changes or before an audited run.
Both modes verify downloads. The explicit `--artifact-check disabled` opt-out
skips all model-file hashing, including downloads, imports, and launch rechecks.
It retains file existence, size, safe-path and runtime integrity checks, but
cannot detect same-size corruption. It never creates or refreshes trusted model
receipts. Results are marked UNVERIFIED; model SHA-256 fields are expected
manifest values, not measured hashes. Use this flag on each command; it does
not change the cached default. A server started this way also requires
`--artifact-check disabled` for endpoint benchmarks until restarted with verification.

## Profiles

| Profile | Context | MTP | Vision default | Custom equivalent |
| --- | ---: | --- | --- | --- |
| `default` | 262,144 | On, depth 3 | On | `--profile custom --mtp on --context 262144 --vision on` |
| `custom` | Explicit | Explicit on/off | On | Requires `--mtp` and `--context` |

```sh
./bin/metal-llm serve qwen3.8-flash-next-mtplx --profile custom --mtp off --context 32768
./bin/metal-llm serve qwen3.8-flash-next-mtplx --vision off
```

Do not pass `--runtime tuned|upstream` or `--mtp dynamic` to this package.
Those choices belong to the original llama.cpp integration. Its 32K dynamic
cutoff has not been ported or qualified for MTPLX. MTPLX's internal `turbo`
configuration is an implementation detail, not another lab profile.

MTPLX 2.11.2 loads its vision tower lazily and has no native serving flag for
disabling it. The lab's `--vision off` is an adapter-level request guard:
multimodal requests are rejected before vision processing. It does not remove
the vision weights from the installed snapshot.

MTP enabled describes the configured policy, not the proposal path of every
token. MTPLX can use a context-copy shortcut. The recorded repeated-token sweep
used that shortcut rather than neural MTP proposals; zero compiled-M4 calls
in that run did not mean a memory fallback.

## API and prompt behavior

The normal endpoint is `http://127.0.0.1:8080/v1`. Use API model ID
`qwen3.8-flash-next-mtplx`:

```sh
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-flash-next-mtplx","messages":[{"role":"user","content":"Hello"}]}'
```

`METAL_LLM_HOST`, `METAL_LLM_PORT` and `METAL_LLM_API_KEY` retain their lab
meanings. If authentication is enabled, supply the bearer key to API clients.
Only `METAL_LLM_PARALLEL=1` is supported for this configuration. Stop an owned
server normally before starting another; the lab does not kill conflicting
processes. Its lease cannot discover every independently launched server.

Agent rewrites are disabled and tools use native model formatting. This removes
the additional MTPLX agent instruction contract; it does not remove the model's
chat template or native tool schema overhead. A tool-enabled request can still
cost more prompt tokens than a plain text request. Do not assume exact token
parity with llama.cpp. The earlier 598-token request used the old hybrid tool
contract and is not a measurement of this launcher.

The evaluated serving defaults use reasoning on, `xhigh` effort, preserved
thinking, temperature 1, top-p 0.95 and top-k 20. Benchmark requests must record
their own sampling overrides. Telemetry and SSD session caching are disabled;
fans remain Apple-managed.

## Memory and qualification

The qualified M5 Max 128 GiB hardware receives a 104 GiB process-local memory
budget (111,669,149,696 bytes). An explicit `MTPLX_MEMORY_LIMIT_BYTES` takes
precedence. Other hardware retains MTPLX's default and is marked unqualified.
This is not a system-wide wired-memory setting or a guarantee against pressure
from other applications. Dry-run reports the selected budget and qualification.

The earlier 104 GiB admission experiment removed a particular compiled-verifier
memory rejection. It did not prove that the admitted path was always faster.
Do not raise the budget blindly when a request falls back: inspect actual path
metrics, memory pressure and competing workloads first.

## Benchmarking and evidence

With the matching managed server already running, from a clean checkout:

```sh
./bin/metal-llm bench qwen3.8-flash-next-mtplx --suite qwen3.8-smoke --mode endpoint --dry-run
./bin/metal-llm bench qwen3.8-flash-next-mtplx --suite qwen3.8-smoke --mode endpoint
```

Local `llama-bench` cases cannot benchmark an MLX runtime and are unsupported.
Use the shared API cases. Keep runtime-native timing and speculative-path
evidence: similarly named throughput fields can have different boundaries.

- [Initial evaluation and exact pins](../experiments/2026-09-06-mtplx-evaluation.md)
- [Memory-budget admission experiment](../experiments/2026-09-07-mtplx-memory-budget.md)
- [Synthetic context sweep protocol](../experiments/2026-09-07-mtplx-context-sweep.md)
- [Five-curve comparison and portable measurements](../../results/experiments/2026-09-07-mtplx-context-sweep/comparison.md)
- [Managed-integration acceptance checklist](../experiments/2026-09-07-mtplx-integration-acceptance.md)

The comparison is cross-day, uses different quantization, and exercises a
repeated-token workload. It is not evidence of a quality winner or universal
speed improvement. Broad task quality and sustained stability remain open.

## Troubleshooting

- Unsupported profile or runtime: use `default` or the MTPLX custom syntax
  above; original-package profile names are not aliases here.
- Insufficient disk space: include both snapshots when importing, plus the
  environment. Do not delete files belonging to a running model to make room.
- Checksum failure: stop and inspect the source or partial download. Do not
  bypass verification or replace the pinned manifest hash to fit a local file.
- Managed-process conflict: finish or stop the owned workload normally. Never
  remove a live lease as a shortcut to loading a second model.
- Endpoint benchmark mismatch: use the same package ID, host and port as the
  managed server. An old manually launched evaluation server is not a match.
- Memory pressure: release competing workloads voluntarily or use a smaller
  custom context. A 104 GiB process limit does not reserve that memory for you.

## Pins and licensing

MTPLX is pinned to 2.11.2; the model is
`Youssofal/Qwen3.8-Flash-Next-MTPLX-Optimized-Speed` at
`6bc2f6e8426ccb4af73c81bc56ba7718afc92cc6`. Dependencies are locked separately
from the model manifest, including structured-output support.

The lab code's MIT license does not relicense downloaded material. MTPLX uses
Apache-2.0; retain its license and NOTICE when redistributing it. Model weights
use Qwen Community License 1.0. Review the pinned snapshot's license before
downloading or redistributing. Weights and third-party runtime source are not
committed to this repository.
