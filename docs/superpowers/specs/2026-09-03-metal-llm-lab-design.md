# Metal LLM Lab Repository Design

**Date:** September 3, 2026

**Status:** Approved for implementation

**Repository:** `bwangbos/metal-llm-lab`

**License:** MIT

## Purpose

Metal LLM Lab is a reproducible research and operations workspace for running, optimizing, validating, and comparing local large language models on Apple Silicon. The initial case study is Qwen3.8-Flash-Next on an Apple M5 Max with 128 GB unified memory, but the repository must support additional models, Apple Silicon configurations, and inference runtimes without organizing the project around one model or machine.

The repository must let a new user clone it, follow short copy-and-paste instructions, and automate source checkout, patching, compilation, artifact download, verification, serving, and benchmarking. Large model files, compiled outputs, and third-party source trees remain local and reconstructable.

## Repository Strategy

Use a compact reproducible research harness rather than vendoring inference runtimes or managing them as Git submodules. The repository tracks:

- Exact upstream runtime revisions.
- Versioned patch series applied to those revisions.
- Machine-readable model and artifact manifests.
- Setup, serving, diagnostic, and benchmark automation.
- Raw benchmark data, summarized findings, and experiment methodology.
- Architectural decisions and historical context.

Model weights, build products, caches, and checked-out third-party repositories are excluded from Git. Experimental runtime changes, including dynamic MTP selection, remain tested patches against pinned upstream revisions until maintaining a dedicated runtime fork is justified.

## User Experience

The primary onboarding flow is:

```sh
git clone https://github.com/bwangbos/metal-llm-lab.git
cd metal-llm-lab
./scripts/bootstrap-macos.sh
./bin/metal-llm setup qwen3.8-flash-next
./bin/metal-llm serve qwen3.8-flash-next --profile auto
```

The initial command interface is:

- `doctor`: Report supported hardware, dependencies, storage, and configuration problems.
- `setup MODEL`: Fetch pinned source, apply patches, build, download artifacts, verify checksums, and run a smoke test.
- `serve MODEL --profile PROFILE`: Launch a named, reproducible inference configuration.
- `bench MODEL --suite SUITE`: Run a benchmark definition and save raw results with provenance.
- `report`: Produce readable summaries from raw benchmark results.

The final root README must provide a literal working quick start for the initial Qwen model. The interface and manifests must not assume one model or machine.

## Repository Layout

```text
bin/                         User-facing command entry points
scripts/                     Bootstrap and focused maintenance scripts
manifests/runtimes/          Runtime repositories, revisions, and build settings
manifests/models/            Model artifacts, licenses, checksums, and compatibility
manifests/hardware/          Tested machine descriptions and measured constraints
patches/                     Versioned patches against pinned runtime revisions
benchmarks/suites/           Reproducible benchmark definitions
benchmarks/fixtures/         Small prompts and test assets permitted in Git
results/raw/                 Machine-readable measurements and provenance
results/summaries/           Human-readable conclusions linked to raw data
docs/models/                 Model-specific setup and findings
docs/hardware/               Machine-specific baselines and limitations
docs/experiments/            Methodology, observations, and experiment narratives
docs/decisions/              Architecture decision records
docs/troubleshooting/        Actionable failure diagnosis
tests/                       Lightweight automated validation
```

## Reproducibility and Provenance

For each benchmark or experiment, record:

- Date, repository revision, and experiment identifier.
- Hardware, operating system, power mode, and relevant system state.
- Compiler, SDK, build type, and build flags.
- Upstream runtime repository and exact commit.
- Ordered patch set and patch checksums.
- Artifact URLs, expected sizes, licenses, and cryptographic checksums.
- Exact server and benchmark commands.
- Prompt or fixture identity and generation parameters.
- Raw timings and hardware readings needed to interpret them.
- Known anomalies, limitations, and output-equivalence findings.

The initial Qwen case study preserves runtime comparisons, MTP/no-MTP results, the vision-enabled crossover study, vision validation, long-context retrieval, memory observations, and the rationale and exact flags behind each profile. Raw records are machine-readable; human summaries link to them and explain methodology.

## Generated State and Local Paths

Model weights, compiled outputs, caches, checked-out runtime worktrees, partial downloads, temporary benchmark files, local environments, and secret files are ignored by Git. Scripts use repository-relative or explicitly configured data directories. Published results must not contain usernames, credentials, private tokens, or unnecessary absolute paths.

## Setup Pipeline

The macOS bootstrap and setup flow must:

1. Confirm Apple Silicon and report the detected chip, unified memory, operating system, and developer toolchain.
2. Check required commands and give copy-and-paste guidance for missing dependencies.
3. Check available disk space before large downloads or builds.
4. Resolve a model manifest and compatible runtime manifest.
5. Clone or update the runtime at an exact pinned commit in an ignored local directory.
6. Apply the declared patch series and stop if the source revision or patch context differs.
7. Compile the Metal runtime with recorded build options.
8. Display artifact source, license, and expected download size before downloading.
9. Download with resume support and verify checksums before use.
10. Run a lightweight smoke test and report the next serve or benchmark command.

Scripts never silently install global packages, invoke `sudo`, change macOS system settings, or enable telemetry.

## Profiles and Automatic Selection

Profiles are data-backed configurations rather than opaque shell argument collections. Each records its model, runtime, context allocation, vision support, speculative-decoding mode, and relevant inference flags.

Automatic selection may use detected hardware and actual prompt characteristics. The planned dynamic-MTP capability will load the target model, vision projector, and MTP head once, then select speculative or conventional decoding per request after multimodal prompt expansion. Its threshold is configurable and based on measured results; long-context requests default to no-MTP when performance or repeatability favors it.

Experimental profiles are labeled separately from upstream-stable fallbacks.

## Safety and Failure Behavior

- Large downloads show source, license, expected size, and destination before beginning.
- Interrupted downloads resume without replacing verified artifacts.
- Existing files are verified rather than overwritten blindly.
- Patch failures report expected and actual revisions and stop.
- Unsupported hardware and missing dependencies produce actionable diagnostics.
- Tokens are read from environment variables or credential helpers and never written to manifests or results.
- Published benchmark data sanitizes user-specific absolute paths.
- Experimental patches and known correctness concerns are identified prominently.

## Testing and Continuous Integration

CI remains lightweight and does not download model weights. It validates shell syntax and help behavior, manifest schemas and cross-references, dry-run command generation, hardware-detection fixtures, checksum handling, patch applicability where practical, profile boundaries, result schemas, report generation, secrets, and oversized files.

Full Metal builds, artifact downloads, vision validation, and performance benchmarks are labeled local integration tests. Their results identify the repository revision, manifests, and environment.

## Documentation

The initial repository includes:

- A root README with scope, support status, prerequisites, storage expectations, a copy-and-paste Qwen quick start, common commands, and deeper links.
- `AGENTS.md` with repository conventions, verification requirements, generated directories, provenance rules, and continuation guidance.
- Model documentation for Qwen3.8-Flash-Next.
- Hardware documentation for the M5 Max 128 GB baseline.
- Benchmark methodology and current results.
- Architecture decisions for the harness strategy and dynamic-MTP direction.
- Troubleshooting for downloads, builds, Metal allocation, memory contention, and output-budget issues.
- Security, licensing, and contribution guidance.

Documentation distinguishes measured facts, upstream claims, hypotheses, and future work.

## Initial Milestone

The first milestone provides a working, documented Qwen3.8-Flash-Next path on the existing M5 Max while establishing reusable boundaries for other models and Apple Silicon machines. It includes the repository scaffold, manifests, setup and serving commands, tests, migrated benchmark history, and documentation. It does not attempt to become a general package manager or support untested platforms.

Dynamic per-request MTP selection is documented as the next runtime experiment and may be implemented as a subsequent tested patch after the repository foundation is published.

## Success Criteria

- A fresh clone offers a short, accurate setup path with automated compilation and artifact acquisition.
- Every runtime and model artifact is pinned and checksum-verifiable.
- The Qwen case study can be reproduced without undocumented chat history.
- Benchmark claims link to raw data and methodology.
- No model weights, compiled artifacts, secrets, or third-party source trees are committed.
- Adding a second model or Apple Silicon machine does not require redesigning the command interface or repository layout.
