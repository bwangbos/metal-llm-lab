# Metal LLM Lab Repository Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a safe, reproducible, checkout-and-go research repository whose first supported configuration is Qwen3.8-Flash-Next on an Apple M5 Max with 128 GB unified memory.

**Architecture:** A Zsh entry point dispatches small commands that read versioned JSON manifests through `jq`. Runtime source, builds, and model artifacts live under ignored `.lab/` directories and can be reconstructed from exact source revisions, patch files, URLs, sizes, and SHA-256 checksums. Documentation and machine-readable benchmark records preserve the current experiment history without committing large or third-party artifacts.

**Tech Stack:** Zsh, JSON, `jq`, Git, CMake, AppleClang/Metal, `curl`, SHA-256, GitHub Actions, ShellCheck.

**Spec:** `docs/superpowers/specs/2026-09-03-metal-llm-lab-design.md`

## Global Constraints

- Repository: public `bwangbos/metal-llm-lab`, default branch `main`, MIT license.
- Support only macOS on Apple Silicon in the first milestone; fail clearly elsewhere.
- Never invoke `sudo`, silently install packages, alter macOS settings, or enable telemetry.
- Never commit model weights, build products, third-party runtime trees, credentials, partial downloads, or user-specific absolute paths.
- Pin every runtime revision and checksum every downloaded artifact before use.
- Preserve the distinction between measured results, upstream claims, interpretations, and future work.
- Dynamic per-request MTP selection is documented future work, not part of this foundation milestone.

---

### Task 1: Repository guardrails and public documentation shell

**Files:**
- Create: `.gitignore`
- Create: `.gitattributes`
- Create: `LICENSE`
- Create: `README.md`
- Create: `AGENTS.md`
- Create: `CONTRIBUTING.md`
- Create: `SECURITY.md`
- Create: `docs/decisions/0001-reproducible-harness.md`
- Test: `tests/test_repository.sh`

**Interfaces:**
- Produces: repository-wide safety rules and stable documentation entry points used by every later task.

- [ ] **Step 1: Write the repository guardrail test**

Create `tests/test_repository.sh` as an executable Zsh script. It must assert that all seven public files exist, `LICENSE` contains `MIT License`, `.gitignore` excludes `/.lab/`, `/models/`, `/build/`, `.env`, `*.gguf`, and partial downloads, and no tracked file exceeds 10 MiB.

```zsh
#!/bin/zsh
set -euo pipefail
root=${0:A:h:h}
for path in README.md AGENTS.md CONTRIBUTING.md SECURITY.md LICENSE .gitignore .gitattributes; do
  [[ -f "$root/$path" ]] || { print -u2 -- "missing $path"; exit 1; }
done
grep -q 'MIT License' "$root/LICENSE"
for pattern in '/.lab/' '/models/' '/build/' '.env' '*.gguf' '*.part'; do
  grep -Fqx "$pattern" "$root/.gitignore" || { print -u2 -- "missing ignore: $pattern"; exit 1; }
done
git -C "$root" ls-files -z | xargs -0 stat -f '%z %N' | awk '$1 > 10485760 { bad=1; print } END { exit bad }'
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `zsh tests/test_repository.sh`

Expected: failure naming the first missing public file.

- [ ] **Step 3: Add guardrails and documentation shell**

Use the standard MIT text with copyright `2026 Brian Wang`. Configure `.gitattributes` with `* text=auto eol=lf` and `*.zsh text eol=lf`. In `.gitignore`, exclude generated `.lab`, models, builds, secrets, logs, partial downloads, macOS metadata, and editor files.

The root README must state the project scope, current support matrix, approximate 100 GB Qwen download requirement, status of experimental patches, and the future quick-start command names. `AGENTS.md` must require provenance, checksum verification, no hidden system mutation, tests before benchmark claims, and preservation of raw results. The contribution and security documents must explain how to report reproducibility defects and vulnerabilities without publishing tokens or private paths.

- [ ] **Step 4: Run the test and documentation checks**

Run: `zsh tests/test_repository.sh`

Expected: `repository checks: PASS`.

Run: `git diff --check`

Expected: exit 0 with no output.

- [ ] **Step 5: Commit**

```sh
git add .gitignore .gitattributes LICENSE README.md AGENTS.md CONTRIBUTING.md SECURITY.md docs/decisions/0001-reproducible-harness.md tests/test_repository.sh
git commit -m "docs: establish repository guardrails"
```

---

### Task 2: Versioned manifest contracts and the first supported configuration

**Files:**
- Create: `schemas/runtime.schema.json`
- Create: `schemas/model.schema.json`
- Create: `schemas/hardware.schema.json`
- Create: `manifests/runtimes/llama-cpp-qwen38-hybrid.json`
- Create: `manifests/runtimes/llama-cpp-upstream-stable.json`
- Create: `manifests/models/qwen3.8-flash-next.json`
- Create: `manifests/hardware/apple-m5-max-128gb.json`
- Create: `tests/test_manifests.sh`

**Interfaces:**
- Produces: JSON objects keyed by stable `id`; model manifests reference `runtime_id`, profiles reference artifact IDs, and setup/serve commands consume those fields with `jq -er`.

- [ ] **Step 1: Write failing schema and cross-reference tests**

The executable `tests/test_manifests.sh` must use `jq -e` to require runtime fields `id`, `repository`, `base_revision`, `patches`, `build.generator`, and `build.targets`; artifact fields `id`, `url`, `bytes`, `sha256`, and `license_url`; profile fields `id`, `runtime_id`, `context`, `vision`, and `mtp`; and hardware fields `id`, `chip`, `unified_memory_bytes`, and `tested`. It must reject a 63-character checksum fixture and confirm every model `runtime_id` resolves to a runtime manifest.

- [ ] **Step 2: Run the manifest test and verify it fails**

Run: `zsh tests/test_manifests.sh`

Expected: failure because schemas and manifests do not exist.

- [ ] **Step 3: Add schemas and runtime manifests**

Pin the hybrid reconstruction to `https://github.com/ggml-org/llama.cpp.git` base `7798007a29a90e3053e799394da48cf53a2f8e0f`, followed by the Qwen Metal patch and eleven ordered MTP integration patches that produce tested tree `831e5d6f6e0d7b6c8d5757b1da41480ab33a0528`. Pin the conservative runtime directly to `de8656bd94f1163188125542534e4bcbc9f9fb1f` with no patches. Record Release, native ARM, Metal, Accelerate, server, and bench build settings.

- [ ] **Step 4: Add model and hardware manifests**

Record AtomicChat's 33-shard `Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64` model, the F16 projector, and Unsloth Q8 MTP sidecar. Use the verified projector checksum `0e61454a76dd154a10aaa8fb1ada32615f55a13e4171014dacd06913e4aa6889` and MTP checksum `5ff54097406a905cf3a724c709124ceb0e3e10235ee862298969e91c96fa96e6`. Compute and record checksums for all 33 local shards before committing the manifest. Record the model total as 94,525,394,976 bytes, projector as 904,003,840 bytes, and MTP sidecar as 2,786,568,256 bytes.

Define `fast`, `vision`, `long`, and `stable` profiles with their exact runtime, 32,768 or 131,072 context, projector, and common Metal flags. Keep MTP on for `fast` and `vision`; disable it for `long` because the measured long-context crossover favors ordinary Metal decoding. Set the M5 Max manifest's `recommended_profile` to `vision`, which the CLI resolves when `--profile auto` is requested. Record the tested M5 Max as 40 GPU cores and 137,438,953,472 bytes of unified memory.

- [ ] **Step 5: Run manifest verification**

Run: `zsh tests/test_manifests.sh`

Expected: `manifest checks: PASS`.

Run: `jq empty schemas/*.json manifests/**/*.json`

Expected: exit 0.

- [ ] **Step 6: Commit**

```sh
git add schemas manifests tests/test_manifests.sh
git commit -m "feat: add versioned runtime and model manifests"
```

---

### Task 3: Reconstruct the tested hybrid runtime with a patch series

**Files:**
- Create: `patches/llama.cpp/qwen3.8-hybrid/series`
- Create: `patches/llama.cpp/qwen3.8-hybrid/0001-metal-optimize-qwen4-exp-inference.patch`
- Create: `patches/llama.cpp/qwen3.8-hybrid/0002-gguf-py-register-qwen4exp-nextn-tensors.patch` through `0012-qwen4exp-expose-optimized-graph-helpers-to-mtp.patch`
- Create: `scripts/runtime-sync.zsh`
- Create: `tests/test_runtime_sync.sh`

**Interfaces:**
- Consumes: `manifests/runtimes/*.json`.
- Produces: `.lab/runtimes/RUNTIME_ID/source` at `tested_tree`, and `.lab/runtimes/RUNTIME_ID/build-metal` after setup builds it.

- [ ] **Step 1: Write failing dry-run and dirty-tree tests**

Test that `scripts/runtime-sync.zsh llama-cpp-qwen38-hybrid --dry-run` prints the repository, base revision, all 12 patch names in order, and final tested tree. Use a temporary local Git fixture to verify the script refuses a dirty existing checkout and reports an unappliable patch without altering the checkout.

- [ ] **Step 2: Run the tests and verify failure**

Run: `zsh tests/test_runtime_sync.sh`

Expected: failure because the runtime synchronizer is absent.

- [ ] **Step 3: Export and normalize the tested patches**

From the existing clean hybrid checkout, export commit `67d777b61c1169d9f7a8cf00f4abc1e731e6fa75` and commits in `67d777b61c1169d9f7a8cf00f4abc1e731e6fa75..831e5d6f6e0d7b6c8d5757b1da41480ab33a0528` using `git format-patch`. Preserve authorship and commit messages. List their exact filenames in `series`, one per line.

- [ ] **Step 4: Implement safe runtime synchronization**

The script resolves its repository root from `${0:A}`, validates the manifest with `jq -er`, clones with blob filtering when absent, fetches the exact base revision, refuses dirty state, detaches at the base, applies patches with `git am`, verifies `git rev-parse HEAD^{tree}` against a recorded `tested_tree_sha`, and removes an in-progress `git am` state on failure without deleting user files. `--dry-run` performs no writes.

- [ ] **Step 5: Verify patch reconstruction**

Run: `zsh tests/test_runtime_sync.sh`

Expected: `runtime sync checks: PASS`.

Run the synchronizer against a fresh ignored destination and compare `git diff --exit-code` plus `git rev-parse HEAD^{tree}` with the existing hybrid checkout.

Expected: no diff and identical tree hashes.

- [ ] **Step 6: Commit**

```sh
git add patches scripts/runtime-sync.zsh tests/test_runtime_sync.sh
git commit -m "feat: make hybrid llama.cpp runtime reproducible"
```

---

### Task 4: Doctor, setup, and artifact acquisition

**Files:**
- Create: `bin/metal-llm`
- Create: `lib/common.zsh`
- Create: `lib/doctor.zsh`
- Create: `lib/setup.zsh`
- Create: `scripts/bootstrap-macos.sh`
- Create: `tests/fixtures/system/apple-m5-max.txt`
- Create: `tests/test_cli.sh`
- Create: `tests/test_doctor.sh`
- Create: `tests/test_setup.sh`

**Interfaces:**
- Produces: `metal-llm doctor`, `metal-llm setup MODEL [--dry-run]`, and `.lab/artifacts/MODEL_ID/...` containing only verified artifacts.
- Consumes: runtime/model manifests and `scripts/runtime-sync.zsh`.

- [ ] **Step 1: Write failing CLI and doctor tests**

Verify help text, unknown-command exit 2, unsupported-architecture diagnostics, detection-fixture parsing, missing-command guidance, and repository-root resolution when invoked outside the checkout. The doctor result is nonzero when required tools are absent and never mutates the system.

- [ ] **Step 2: Write failing setup tests**

Using a tiny local file fixture, verify download resume, byte-count validation, SHA-256 success, checksum rejection, atomic rename from `.part`, reuse of an already verified file, disk-space rejection, and redaction of `HF_TOKEN`. Verify `--dry-run` prints every runtime/build/artifact action without creating `.lab`.

- [ ] **Step 3: Implement the dispatcher and diagnostics**

`bin/metal-llm` accepts `doctor`, `setup`, `serve`, `bench`, `report`, and `help`, with only `doctor` and `setup` active in this task. `doctor` checks `arm64`, macOS, `git`, `curl`, `jq`, `cmake`, `ninja`, `xcode-select`, `shasum`, free disk space, and Metal visibility. Missing Homebrew tools produce one explicit `brew install cmake ninja jq` suggestion but are never installed automatically.

- [ ] **Step 4: Implement setup orchestration**

The setup command validates the model manifest, calculates required bytes, asks for confirmation only when attached to a terminal unless `--yes` is supplied, synchronizes the runtime, configures CMake into `.lab/runtimes/RUNTIME_ID/build-metal`, builds `llama-server` and `llama-bench`, downloads artifacts with `curl --fail --location --continue-at -`, verifies byte count and SHA-256, then atomically renames each `.part` file. It prints the next `serve` command on success.

- [ ] **Step 5: Implement bootstrap and run unit tests**

`bootstrap-macos.sh` resolves the checkout, runs `metal-llm doctor`, and prints the exact setup command. It does not install dependencies.

Run: `zsh tests/test_cli.sh && zsh tests/test_doctor.sh && zsh tests/test_setup.sh`

Expected: all three scripts print `PASS` and exit 0.

- [ ] **Step 6: Commit**

```sh
git add bin lib scripts/bootstrap-macos.sh tests
git commit -m "feat: automate diagnostics and reproducible setup"
```

---

### Task 5: Profile-driven serving

**Files:**
- Create: `lib/serve.zsh`
- Create: `tests/test_serve.sh`
- Modify: `bin/metal-llm`
- Modify: `README.md`

**Interfaces:**
- Produces: `metal-llm serve MODEL --profile PROFILE [--dry-run] [-- EXTRA_LLAMA_ARGS]`.
- Consumes: verified artifacts, built runtime, and profile objects from the model manifest.

- [ ] **Step 1: Write failing profile tests**

Assert exact command generation for `fast`, `vision`, `long`, and `stable`; resolution of `auto` to the hardware manifest's `recommended_profile`; loopback binding by default; 32,768 and 131,072 context sizes; MTP only where declared; projector and 1,024 image-token floor for vision; API key forwarding without printing its value; environment overrides for host, port, parallel slots, and context; invalid profile failure; missing-checksum artifact failure; and passthrough arguments after `--`.

- [ ] **Step 2: Run the tests and verify failure**

Run: `zsh tests/test_serve.sh`

Expected: failure because `serve` is not implemented.

- [ ] **Step 3: Implement command construction**

Build an argument array without `eval`. Common defaults are `-ngl all -fit off -fa on -lm mmap -lzm on -np 1 --host 127.0.0.1`. Read context, runtime, MTP, projector, and image floor from the selected manifest profile. Require every referenced file and executable before launch. `--dry-run` shell-quotes the command; normal mode uses `exec`.

- [ ] **Step 4: Add the literal quick start**

Replace provisional README language with tested commands for clone, doctor, setup, and serve. Include download size, expected setup duration as environment-dependent rather than guaranteed, OpenAI-compatible curl example, profile table, environment overrides, and the one-server-at-a-time limitation.

- [ ] **Step 5: Verify and commit**

Run: `zsh tests/test_serve.sh && zsh tests/test_repository.sh`

Expected: both pass.

```sh
git add bin/metal-llm lib/serve.zsh tests/test_serve.sh README.md
git commit -m "feat: launch reproducible inference profiles"
```

---

### Task 6: Preserve benchmark data and experiment history

**Files:**
- Create: `schemas/result.schema.json`
- Create: `results/raw/2026-09-03-qwen38-m5-max.json`
- Create: `results/summaries/qwen3.8-flash-next-m5-max.md`
- Create: `docs/models/qwen3.8-flash-next.md`
- Create: `docs/hardware/apple-m5-max-128gb.md`
- Create: `docs/experiments/2026-09-03-runtime-comparison.md`
- Create: `docs/experiments/2026-09-03-mtp-context-crossover.md`
- Create: `docs/decisions/0002-dynamic-mtp-direction.md`
- Create: `docs/troubleshooting/qwen3.8-flash-next.md`
- Create: `benchmarks/suites/qwen3.8-smoke.json`
- Create: `lib/bench.zsh`
- Create: `lib/report.zsh`
- Create: `tests/test_bench.sh`
- Create: `tests/test_results.sh`
- Modify: `bin/metal-llm`
- Modify: `README.md`

**Interfaces:**
- Produces: `metal-llm bench MODEL --suite SUITE [--dry-run]`, schema-valid raw result records, linked human narratives, and `metal-llm report` summary output.

- [ ] **Step 1: Write failing result validation tests**

Require each run to record timestamp, repository revision, hardware ID, runtime ID and revision, profile, effective prompt tokens, generated tokens, prompt and generation throughput, generation settings, output hash when available, and notes. Reject absolute paths beginning `/Users/`, secret-like keys, and unknown hardware/runtime IDs. Verify summary tables are generated from raw JSON values.

- [ ] **Step 2: Run the tests and verify failure**

Run: `zsh tests/test_results.sh`

Expected: failure because the result schema and report command are absent.

- [ ] **Step 3: Implement the benchmark runner**

Define `qwen3.8-smoke` as a small JSON suite containing a 512-token prompt-processing case, 128-token generation case, deterministic API smoke request, and optional vision fixture case. `metal-llm bench` resolves the model and profile, refuses to run when another lab server owns the configured port, supports `--dry-run`, invokes `llama-bench` or the local HTTP endpoint without `eval`, and writes a timestamped result document through a temporary file followed by atomic rename. Unit tests use fake executables and fixtures; they do not launch Metal or download artifacts.

- [ ] **Step 4: Migrate and correct the existing evidence**

Transcribe the runtime comparison, 28K/96K retrieval, vision suite, and MTP/no-MTP crossover measurements. Preserve the correction that 23.80 tok/s at approximately 96K used MTP; record no-MTP results of 34.47 tok/s at 99,405 effective tokens with an image and 36.66 tok/s at 98,338 tokens with the projector resident. Record the attached-image crossover bracket 32,844–33,868 and interpolation near 33.6K, plus the repeated general-purpose gray zone around 29–30K. Explicitly record output divergence and non-monotonic route-dependent behavior.

- [ ] **Step 5: Write continuation documentation**

Document artifact choices, exact server flags, stable versus experimental provenance, 128K allocation, memory limits, structured-output budget behavior, vision validation, and the rule against two concurrent full-model servers. The dynamic-MTP ADR describes a single loaded target with post-multimodal-tokenization per-request gating, configurable threshold, fixed choice for each response, and required correctness/performance tests; it does not claim implementation.

- [ ] **Step 6: Implement and verify reporting**

`metal-llm report` validates raw files, emits Markdown tables from JSON, and supports `--check` to fail when committed summaries differ from generated output.

Run: `zsh tests/test_bench.sh && zsh tests/test_results.sh && ./bin/metal-llm report --check`

Expected: both pass with no user-specific paths or secrets.

- [ ] **Step 7: Commit**

```sh
git add schemas/result.schema.json results docs benchmarks lib/bench.zsh lib/report.zsh tests/test_bench.sh tests/test_results.sh bin/metal-llm README.md
git commit -m "docs: preserve qwen benchmark evidence and decisions"
```

---

### Task 7: CI, full verification, and GitHub publication

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/ISSUE_TEMPLATE/benchmark.yml`
- Create: `.github/pull_request_template.md`
- Create: `tests/run.sh`
- Modify: `docs/superpowers/specs/2026-09-03-metal-llm-lab-design.md`

**Interfaces:**
- Produces: one local verification entry point, lightweight GitHub CI, and the public repository.

- [ ] **Step 1: Add the aggregate test runner and CI**

`tests/run.sh` executes every `tests/test_*.sh`, `zsh -n` on tracked shell files, `jq empty` on tracked JSON, `git diff --check`, a secret-pattern scan, and the 10 MiB tracked-file limit. CI runs it on `macos-latest`, then runs ShellCheck on shell files. It never downloads models or compiles the full runtime.

- [ ] **Step 2: Run the full local verification**

Run: `zsh tests/run.sh`

Expected: all checks pass and exit 0.

Run: `git status --short`

Expected: empty output after committing the CI files.

- [ ] **Step 3: Verify the checkout-and-go path without large downloads**

Run: `./scripts/bootstrap-macos.sh`

Expected: accurate diagnostics and the Qwen setup command, with no system mutation.

Run: `./bin/metal-llm setup qwen3.8-flash-next --dry-run`

Expected: pinned clone, 12-patch application, Metal build, all artifact downloads, checksum checks, and smoke-test actions are printed; `.lab` remains absent in a clean temporary clone.

- [ ] **Step 4: Mark the reviewed specification implemented and commit**

Change the design status to `Implemented in repository foundation` and commit CI, templates, tests, and the status update.

```sh
git add .github tests/run.sh docs/superpowers/specs/2026-09-03-metal-llm-lab-design.md
git commit -m "ci: verify the reproducible lab foundation"
```

- [ ] **Step 5: Authenticate and create the remote repository**

Run `gh auth status`. If the stored credential remains invalid, run interactive `gh auth login --hostname github.com --git-protocol https --web` and allow the user to complete browser authorization. Confirm `gh repo view bwangbos/metal-llm-lab` returns not found before creation.

Create and push:

```sh
gh repo create bwangbos/metal-llm-lab --public --source=. --remote=origin --push --description "Reproducible local LLM optimization, serving, and benchmarking on Apple Silicon"
```

- [ ] **Step 6: Verify the public repository**

Run: `gh repo view bwangbos/metal-llm-lab --json nameWithOwner,visibility,defaultBranchRef,url,licenseInfo`

Expected: `bwangbos/metal-llm-lab`, `PUBLIC`, default branch `main`, and MIT license metadata.

Run: `gh run list --repo bwangbos/metal-llm-lab --limit 1`

Expected: the initial CI workflow exists; if still running, wait for completion and require success before reporting completion.
