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

## Quick start (coming with the harness)

```sh
git clone https://github.com/bwangbos/metal-llm-lab.git
cd metal-llm-lab
./scripts/bootstrap-macos.sh
./bin/metal-llm setup qwen3.8-flash-next
./bin/metal-llm serve qwen3.8-flash-next --profile auto
```

The future command interface also includes `doctor`, `bench MODEL --suite
SUITE`, and `report`. Until implemented, this shell records the intended public
interface rather than promising a completed installation.

## Reproducible work

Every benchmark preserves raw results and provenance: repository and upstream
revisions, patches and checksums, artifacts, hardware and OS state, build flags,
commands, fixtures, generation parameters, timings, and known anomalies. Read
the [harness decision](docs/decisions/0001-reproducible-harness.md) before
extending the workflow.

See [CONTRIBUTING.md](CONTRIBUTING.md) for reproducibility defect reports and
[SECURITY.md](SECURITY.md) for responsible vulnerability reporting.
