# Metal LLM Lab

Metal LLM Lab is a reproducible research and operations workspace for running,
optimizing, validating, and comparing local large language models on Apple
Silicon. It tracks source revisions, patches, artifacts, commands, and raw
measurements; it does not commit model weights, build products, caches, or
checked-out runtimes.

## Support status

| Area | Current status |
| --- | --- |
| Platform | macOS on Apple Silicon only; initial target: Apple M5 Max with 128 GB unified memory |
| Model | Initial case study: Qwen3.8-Flash-Next |
| Runtimes | Pinned upstream revisions plus versioned local patch series |
| Other systems and models | Reusable design; not yet tested |

Supported platforms: macOS on Apple Silicon only. Non-macOS and
non-Apple-Silicon environments are unsupported; commands must fail with clear,
actionable diagnostics.

The Qwen artifact download requires approximately **100 GB** of available
storage, in addition to space for source checkouts and build outputs. Confirm
the artifact source, license, destination, size, and checksum before download.

Experimental runtime patches are maintained as versioned patches against pinned
upstream revisions and labeled experimental in benchmarks and comparisons. The
tuned runtime implements dynamic per-request MTP routing. Its complete
262,144-token `auto` configuration passed allocation, correctness, isolation,
and the predeclared performance gate on the recorded M5 Max 128 GiB system, so
`auto` is the recommended preset for that exact tested configuration. This is a
machine-specific acceptance result, not a performance promise for other hosts.

## Benchmark readouts

See the [prefill and generation context-scaling comparison](results/experiments/2026-09-06-extended-context-sweep/comparison.md)
for near-zero through 256K prompts on the M5 Max 128 GB, with vision enabled.
It compares `long` and `auto` with 256K custom equivalents of `fast` and
`stable`; the shipped short-context presets remain unchanged. The readout links
sample statistics, runtime provenance, and power/background-load caveats.
The [original preset sweep](results/experiments/2026-09-06-preset-context-sweep/summary.md)
measures each preset at its normal context allocation.

## Quick start

```sh
git clone https://github.com/bwangbos/metal-llm-lab.git
cd metal-llm-lab
./scripts/bootstrap-macos.sh
./bin/metal-llm doctor
./bin/metal-llm setup qwen3.8-flash-next --artifact-check cached
./bin/metal-llm serve qwen3.8-flash-next --artifact-check cached
./bin/metal-llm bench qwen3.8-flash-next --suite qwen3.8-smoke --mode local --artifact-check cached --dry-run
./bin/metal-llm report --check
```

Setup downloads approximately **100 GB**, checks every artifact checksum, and
builds every unique pinned runtime required by the model's profiles, including
the upstream reference runtime. Its duration depends on network speed, machine
load, and compiler performance; no fixed completion time is guaranteed.

`setup`, `serve`, and `bench` default to `--artifact-check cached`. After a
successful full verification, a warm cached run validates each artifact against
its local receipt and avoids rereading GGUF bodies. Their verification summary
reports the requested and effective mode plus cache hits, misses, and full
hashes. `cached` means every artifact matched a receipt; `mixed` means some
receipts missed and those bodies were fully hashed; `full` means every required
body was fully hashed. Artifact receipts live locally under
`.lab/verification/artifacts/` and are deliberately not committed. Use
`--artifact-check full` after suspicious changes, metadata-preserving restores,
or before publishing a high-stakes benchmark.

For an audit run, replace `cached` in any of the quick-start commands with
`full`; the command-line option accepts only `cached` or `full`.

An artifact receipt binds a downloaded model body to its manifest identity and
file metadata. A runtime build receipt separately binds a built executable to
its pinned runtime manifest. The managed lease in
`${TMPDIR:-/tmp}/metal-llm-lab/full-model.lease` is neither receipt: it records
the identity of a running full-model process so `serve` and `bench` can
coordinate use of it.
The server listens only on `127.0.0.1:8080` by default. Once it is ready, test
its OpenAI-compatible API from another terminal:

```sh
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-flash-next","messages":[{"role":"user","content":"Hello"}]}'
```

`serve` defaults to the model's `auto` preset. Vision is an independent switch
and defaults to `on` for every preset. All context sizes below are binary token
counts (32K = 32,768 and 256K = 262,144):

| Profile | Runtime | Context | MTP policy | Vision default | Status | Exact custom equivalent |
| --- | --- | ---: | --- | --- | --- | --- |
| `fast` | `tuned` | 32,768 | `on` | `on` | Supported short-request preset | `--profile custom --runtime tuned --mtp on --context 32768 --vision on` |
| `long` | `tuned` | 262,144 | `off` | `on` | Supported 256K preset; allocation accepted on the tested M5 Max 128 GiB host | `--profile custom --runtime tuned --mtp off --context 262144 --vision on` |
| `auto` | `tuned` | 262,144 | `dynamic` | `on` | Recommended on the accepted M5 Max 128 GiB configuration | `--profile custom --runtime tuned --mtp dynamic --context 262144 --vision on` |
| `stable` | `upstream` | 32,768 | `off` | `on` | Upstream reference only; not recommended | `--profile custom --runtime upstream --mtp off --context 32768 --vision on` |

For example, disable the projector without changing the selected runtime,
context, or MTP policy:

```sh
./bin/metal-llm serve qwen3.8-flash-next --profile fast --vision off
./bin/metal-llm serve qwen3.8-flash-next --profile long --vision on
```

Named presets reject `--runtime`, `--mtp`, and `--context` overrides. A custom
profile requires all three controls; `upstream` supports only `--mtp off`, and
context must be a positive integer no larger than 262,144. Use `--vision on` or
`--vision off` independently. The removed standalone vision preset and context
environment override fail with migration guidance.

Both `tuned` and `upstream` are llama.cpp builds configured for full Metal
offload, Metal Flash Attention, and Accelerate on Apple Silicon. The performance
distinction comes from the tuned patch series versus the pinned upstream tree,
plus whether MTP is loaded and selected—not from one runtime using Metal and the
other using a different compute backend. `stable` exists only for upstream
reference comparisons and is not recommended for normal operation.

With dynamic MTP, the server chooses one route only after chat templating and
multimodal expansion. Effective prompts of 32,768 tokens or fewer use
speculative MTP; larger prompts do not. That decision is fixed for the response,
reset when a slot is reused, and independent across concurrent slots. Final
non-streaming responses and terminal streaming events report the route in their
`timings` object:

```json
{
  "speculative": true,
  "speculative_policy": "dynamic",
  "effective_prompt_tokens": 24172,
  "speculative_threshold": 32768
}
```

These fields are route evidence, not proof that the two decoding routes produce
identical output. The opt-in acceptance harness checks boundary,
vision-expansion, streaming, slot-reuse, concurrency, structured-output,
tool-calling, and one-process behavior. It skips unless explicitly enabled and
never downloads artifacts or builds runtimes. On the exact Apple M5 Max 128 GiB
host, after setup and receipt verification, run it explicitly with:

```sh
METAL_LLM_INTEGRATION=1 zsh tests/integration/test_dynamic_mtp.sh
METAL_LLM_PERFORMANCE=1 zsh tests/integration/test_dynamic_mtp_performance.sh
```

The accepted run retained all 105 samples from the 3-policy by 7-length matrix.
Every dynamic generation-throughput mean was within 5% of its corresponding
fixed route. The narrowest margin was at 32,769 effective tokens: +4.90937%
relative to fixed-off, only 0.09063 percentage points inside the gate. See the
[acceptance record](docs/experiments/2026-09-03-dynamic-mtp-acceptance.md) and
[generated summary](results/summaries/qwen3.8-flash-next-dynamic-mtp.md).

`METAL_LLM_HOST`, `METAL_LLM_PORT`, and `METAL_LLM_PARALLEL` override the bind
address, port, and request slots. Set `METAL_LLM_API_KEY` to require an API key;
its value is passed to the server and forwarded by endpoint benchmarks to health
and completion requests.
It is omitted from dry-run output, process records, recorded commands, and
results; recorded HTTP argument arrays use a `<redacted>` placeholder. Extra
llama-server arguments may follow `--`, but are deliberately limited to positive
thread-count tuning (`-t`/`--threads`, `-tb`/`--threads-batch`, and
`--threads-http`) plus `--verbose` and `--log-colors`; for example,
`-- --threads 8`. Model, projector, draft/MTP, context, batching/parallel,
network, GPU/offload, flash-attention, authentication, and other behavioral
options are rejected in both separate-value and `--flag=value` forms. Use the
profile manifest or the documented environment variables above instead.

Normal `serve` and local benchmark runs share one managed full-model lease at
`${TMPDIR:-/tmp}/metal-llm-lab/full-model.lease`. The lease is per user/session
temporary root and coordinates all repository checkouts that use the same
`TMPDIR`; it records the live PID/start identity, model, profile, verified build,
artifact identities, and endpoint. Stale and PID-reused records are recovered,
but the harness never kills the recorded process. This lease covers only
processes started by `metal-llm`; it cannot identify an arbitrary model process
started another way.

`bench MODEL --suite SUITE` runs a versioned suite and validates a complete raw
JSON document before publishing it atomically without replacing an existing
same-name measurement. The shipped suite defaults to `--mode local`, which runs
only standalone `llama-bench` cases, acquires the shared lease, and also refuses
a responding server on the configured lab endpoint. `--mode endpoint` runs only
API cases and requires both a live matching `metal-llm serve` identity and a
responding configured endpoint; it cannot silently benchmark an unrelated or
differently configured server. Set `METAL_LLM_INCLUDE_OPTIONAL=1` to include its
PNG vision case. `--dry-run` prints only the selected mode's actions without
running them. `report` validates raw results and regenerates Markdown summaries;
`report --check` detects drift without rewriting files and is appropriate for
CI.

## Reproducible work

New harness benchmarks require a clean Git checkout and record its actual commit
and tree, an exact detected chip/memory hardware-manifest match, the verified
runtime revision/tree/manifest/receipt/executable, model manifest and artifact
identities, suite and fixture checksums, and sanitized exact argument arrays.
Runtime verification rejects hidden Git index flags and compares every tracked
path's raw, unfiltered bytes and executable mode with the index; every call also
verifies both `llama-server` and `llama-bench` as regular, non-symlink
executables against the build receipt. Benchmark timestamps always come from the
trusted absolute system clock executable `/bin/date`; `PATH` and environment
overrides cannot supply recorded time.
OS, compiler, SDK, and power evidence is recorded from the host; unavailable
values are explicit JSON `null`, never guessed. Hardware and repository identity
overrides are rejected. The imported initial case-study result predates this
capture contract and therefore carries explicit `provenance: null` and
`command: null` markers instead of reconstructed claims.

Vision benchmark fixtures must be Git-tracked regular, non-symlink PNG or JPEG
files confined to `benchmarks/fixtures/`; both extension and detected MIME type
are checked for an exact match before use. Extensions are lowercase only
(`.png`, `.jpg`, or `.jpeg`), and the detected MIME type—not the filename—is used
in the uploaded data URL. The result records the fixture checksum. Read the
[harness decision](docs/decisions/0001-reproducible-harness.md) before extending
the workflow.

See [CONTRIBUTING.md](CONTRIBUTING.md) for reproducibility defect reports and
[SECURITY.md](SECURITY.md) for responsible vulnerability reporting.

The initial case-study record is available as
[raw JSON](results/raw/2026-09-03-qwen38-m5-max.json) and a
[generated summary](results/summaries/qwen3.8-flash-next-m5-max.md). Continue with
the [model notes](docs/models/qwen3.8-flash-next.md),
[tested hardware](docs/hardware/apple-m5-max-128gb.md),
[runtime experiment](docs/experiments/2026-09-03-runtime-comparison.md),
[MTP crossover study](docs/experiments/2026-09-03-mtp-context-crossover.md),
[dynamic-MTP acceptance](docs/experiments/2026-09-03-dynamic-mtp-acceptance.md),
and [dynamic-MTP decision](docs/decisions/0002-dynamic-mtp-direction.md).
