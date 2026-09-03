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

Experimental runtime patches will be maintained as versioned patches against
pinned upstream revisions and labeled experimental in benchmarks and
comparisons. Dynamic per-request MTP selection is future work. It is not part
of this foundation milestone and has no implemented or tested patch here.

## Quick start

```sh
git clone https://github.com/bwangbos/metal-llm-lab.git
cd metal-llm-lab
./scripts/bootstrap-macos.sh
./bin/metal-llm doctor
./bin/metal-llm setup qwen3.8-flash-next
./bin/metal-llm serve qwen3.8-flash-next --profile auto
./bin/metal-llm bench qwen3.8-flash-next --suite qwen3.8-smoke --mode local --dry-run
./bin/metal-llm report --check
```

Setup downloads approximately **100 GB**, checks every artifact checksum, and
builds every unique pinned runtime required by the model's profiles, including
the stable fallback. Its duration depends on network speed, machine load, and
compiler performance; no fixed completion time is guaranteed.
The server listens only on `127.0.0.1:8080` by default. Once it is ready, test
its OpenAI-compatible API from another terminal:

```sh
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-flash-next","messages":[{"role":"user","content":"Hello"}]}'
```

Choose a profile explicitly or use `auto`, which selects the detected hardware
manifest's recommendation:

| Profile | Context | Vision | MTP | Runtime |
| --- | ---: | --- | --- | --- |
| `fast` | 32,768 | No | Yes | Experimental hybrid |
| `vision` | 32,768 | Yes | Yes | Experimental hybrid |
| `long` | 131,072 | No | No | Experimental hybrid |
| `stable` | 32,768 | No | No | Pinned upstream stable |

`METAL_LLM_HOST`, `METAL_LLM_PORT`, `METAL_LLM_PARALLEL`, and
`METAL_LLM_CONTEXT` override the bind address, port, request slots, and context
size. Set `METAL_LLM_API_KEY` to require an API key; its value is passed to the
server and forwarded by endpoint benchmarks to health and completion requests.
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
path's content and executable mode with the index; every call also verifies both
`llama-server` and `llama-bench` as regular, non-symlink executables against the
build receipt. Benchmark timestamps always come from the system UTC clock.
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
[MTP crossover study](docs/experiments/2026-09-03-mtp-context-crossover.md), and
[dynamic-MTP direction](docs/decisions/0002-dynamic-mtp-direction.md).
