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
./bin/metal-llm bench qwen3.8-flash-next --suite qwen3.8-smoke --dry-run
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
server but omitted from dry-run output. Extra llama-server arguments may follow
`--`, for example `-- --threads 8`.

Only one managed server may run at a time. Stop the current process before
switching profiles or running local `llama-bench`. `bench MODEL --suite SUITE`
runs a versioned suite and atomically saves raw JSON; `--dry-run` prints the
resolved microbenchmark/API actions without running them. Optional API and vision
cases are retained as endpoint-only suite templates; do not run them beside the
local microbenchmark cases, because that would require two full-model processes.
`report` validates raw results and regenerates Markdown summaries; `report
--check` detects drift without rewriting files and is appropriate for CI.

## Reproducible work

Every benchmark preserves raw results and provenance: repository and upstream
revisions, patches and checksums, artifacts, hardware and OS state, build flags,
commands, fixtures, generation parameters, timings, and known anomalies. Read
the [harness decision](docs/decisions/0001-reproducible-harness.md) before
extending the workflow.

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
