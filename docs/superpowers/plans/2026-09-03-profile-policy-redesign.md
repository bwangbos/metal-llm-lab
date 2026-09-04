# Profile Policy Redesign and Dynamic MTP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the coupled profile/vision model with immutable `fast`, `long`, `auto`, and `stable` presets, explicit `custom` policy controls, independently selectable vision, and native single-server MTP routing at 32,768 effective prompt tokens.

**Architecture:** A new Zsh profile resolver turns named or custom CLI inputs into one normalized JSON configuration consumed by setup, serve, managed identity, and endpoint benchmarks. The tuned llama.cpp patch series gains per-slot speculative gating after multimodal tokenization, while the target, projector, and MTP head stay loaded in one process. Hardware acceptance on the M5 Max 128 GiB gates promotion of the 262,144-token `auto` preset as the ready default.

**Tech Stack:** Zsh, jq, JSON Schema Draft 2020-12, Git patch series, C++17 llama.cpp server, CMake/Ninja, curl, GitHub Actions on macOS.

**Spec:** `docs/superpowers/specs/2026-09-03-profile-policy-redesign.md`

## Global Constraints

- Supported platform remains macOS on Apple Silicon; unsupported hosts fail before artifact or process mutation.
- `auto` uses the tuned runtime, 262,144 context, vision on by default, and MTP at effective prompt lengths `<= 32768` only.
- The route decision occurs after multimodal expansion, remains fixed for the response, and is independent per concurrent slot.
- Named profiles reject runtime, MTP, and context overrides; `custom` requires all three.
- `upstream` is compatible only with MTP `off`; MTP `on` and `dynamic` require `tuned`.
- Vision accepts only `on` or `off`, defaults to `on`, and remains independent of every profile.
- No public Metal/CPU toggle, two-server router, threshold override, silent context reduction, or silent policy fallback.
- Runtime revisions, patch revisions/trees, build receipts, artifacts, managed identity, and benchmark provenance remain strictly verified.
- Never commit model weights, runtime checkouts, build products, partial downloads, credentials, or user-specific paths.
- Do not describe `auto` as ready/recommended until the Task 6 hardware gate passes.

---

### Task 1: Add native per-slot dynamic MTP to the tuned runtime

**Files:**
- Modify: `tests/test_runtime_sync.sh`
- Create: `patches/llama.cpp/qwen3.8-hybrid/0013-server-gate-mtp-by-effective-prompt.patch`
- Modify: `patches/llama.cpp/qwen3.8-hybrid/series`
- Modify: `manifests/runtimes/llama-cpp-qwen38-hybrid.json`
- Generated only in ignored runtime checkout: `common/arg.cpp`, `common/common.h`, `tools/server/server-context.cpp`, `tools/server/server-task.h`, `tools/server/server-task.cpp`, and relevant llama.cpp server tests

**Interfaces:**
- Consumes: the existing tuned runtime at tested tree `50ea300c34ee161a7008ca5d7b3cef8e2a77360b` and its initialized `common_speculative` context.
- Produces: internal server option `--spec-draft-max-prompt-tokens N`; per-task fixed route state; final timing fields `speculative`, `speculative_policy`, `effective_prompt_tokens`, and `speculative_threshold`.

- [ ] **Step 1: Add failing patch-series and behavior assertions**

Extend `tests/test_runtime_sync.sh` to require a thirteenth patch and verify its formatted patch includes all of these implementation anchors:

```zsh
grep -Fqx '0013-server-gate-mtp-by-effective-prompt.patch' \
  "$root/patches/llama.cpp/qwen3.8-hybrid/series"
patch_13="$root/patches/llama.cpp/qwen3.8-hybrid/0013-server-gate-mtp-by-effective-prompt.patch"
grep -Fq -- '--spec-draft-max-prompt-tokens' "$patch_13"
grep -Fq 'effective_prompt_tokens' "$patch_13"
grep -Fq 'speculative_threshold' "$patch_13"
grep -Fq 'speculative_policy' "$patch_13"
```

Add a temporary 13-patch fixture whose last patch changes a test source file and assert `runtime-sync` requires `.tested_revision == .patches[-1].revision` and reproduces the new tested tree.

- [ ] **Step 2: Run the runtime-sync test and verify RED**

Run:

```sh
zsh tests/test_runtime_sync.sh
```

Expected: failure because patch 0013 and its manifest entry do not exist.

- [ ] **Step 3: Implement and test the runtime change in the ignored checkout**

In `.lab/runtimes/llama-cpp-qwen38-hybrid/source`, branch from the current twelfth patch revision. Add a signed integer server parameter with default `-1` meaning fixed/unlimited speculation. Parse `--spec-draft-max-prompt-tokens N` as a positive integer and reject it unless draft/MTP speculative decoding is loaded.

Add per-slot fields equivalent to:

```cpp
bool speculative_for_task = true;
int32_t effective_prompt_tokens = 0;
int32_t speculative_threshold = -1;
```

At task launch, after templating and MTMD tokenization have populated the task's effective tokens, assign:

```cpp
effective_prompt_tokens = task->n_tokens();
speculative_threshold = params_base.speculative.max_prompt_tokens;
speculative_for_task = spec != nullptr &&
    (speculative_threshold < 0 || effective_prompt_tokens <= speculative_threshold);
```

Make `server_slot::can_speculate()` require both the loaded speculative context and `speculative_for_task`. Reset the task decision on slot release. Audit every begin, draft, checkpoint, restore, accept, statistics, and replay path so an off-route slot never touches speculative state while another slot may remain on-route.

Add route fields to `server_slot_stats` and its final JSON serialization. Fixed MTP reports policy `on`, no draft model reports `off`, and threshold-gated operation reports `dynamic`. Non-applicable threshold serializes as JSON `null`.

Add llama.cpp-side tests covering 32,767, 32,768, and 32,769 effective tokens, slot reset, and simultaneous opposite decisions. The helper under test must take effective token counts rather than raw request text.

- [ ] **Step 4: Build and run the focused upstream tests**

Run from the ignored runtime checkout:

```sh
cmake --build build --target llama-server -j
ctest --test-dir build --output-on-failure -R 'server|speculative'
```

Expected: compilation succeeds and all selected tests pass. If the existing build directory is incompatible, reconfigure it using the exact manifest CMake options; do not modify global packages.

- [ ] **Step 5: Format patch 0013 and update immutable runtime identity**

Commit only the focused upstream changes, then generate the patch from the
repository root:

```sh
git -C .lab/runtimes/llama-cpp-qwen38-hybrid/source \
  format-patch -1 --stdout HEAD > \
  patches/llama.cpp/qwen3.8-hybrid/0013-server-gate-mtp-by-effective-prompt.patch
```

Append the filename to `series`. Set the runtime manifest's final patch revision and `tested_revision` to the new 40-character commit, and set `tested_tree_sha` to `git rev-parse 'HEAD^{tree}'`.

- [ ] **Step 6: Verify reproducibility from the original base**

Run:

```sh
zsh tests/test_runtime_sync.sh
scripts/runtime-sync.zsh llama-cpp-qwen38-hybrid --dry-run
```

In a separate temporary clone, check out base `7798007a29a90e3053e799394da48cf53a2f8e0f`, apply all 13 patches with `git am`, and require its tree to equal the updated manifest tree. No existing runtime checkout may be reset or deleted for this proof.

- [ ] **Step 7: Commit the runtime patch**

```sh
git add tests/test_runtime_sync.sh patches/llama.cpp/qwen3.8-hybrid \
  manifests/runtimes/llama-cpp-qwen38-hybrid.json
git commit -m "feat: gate MTP by effective prompt length"
```

---

### Task 2: Centralize preset and custom profile resolution

**Files:**
- Create: `lib/profile.zsh`
- Create: `tests/test_profiles.sh`
- Modify: `bin/metal-llm`
- Modify: `schemas/model.schema.json`
- Modify: `schemas/hardware.schema.json`
- Modify: `manifests/models/qwen3.8-flash-next.json`
- Modify: `manifests/hardware/apple-m5-max-128gb.json`
- Modify: `lib/setup.zsh`
- Modify: `lib/runtime-state.zsh`
- Modify: `tests/test_manifests.sh`
- Modify: `tests/test_setup.sh`

**Interfaces:**
- Produces: `metal_llm_resolve_profile MODEL_MANIFEST REQUESTED_PROFILE VISION RUNTIME MTP CONTEXT`, which sets `METAL_LLM_EFFECTIVE_PROFILE` to normalized JSON.
- Normalized JSON fields: `profile_id`, `runtime_alias`, `runtime_id`, `context`, `vision.enabled`, `vision.projector_artifact_id`, `vision.image_min_tokens`, `mtp.policy`, `mtp.artifact_id`, `mtp.spec_type`, `mtp.draft_n_max`, `mtp.gpu_layers`, `mtp.threshold`, `model_artifact_id`, and fixed inference settings.

- [ ] **Step 1: Write failing resolver and schema tests**

Create `tests/test_profiles.sh`. Source `common.zsh` and `profile.zsh`, resolve the real manifest, and assert:

```zsh
resolve '' '' '' ''
jq -e '.profile_id == "auto" and .runtime_alias == "tuned" and
  .context == 262144 and .vision.enabled == true and
  .mtp.policy == "dynamic" and .mtp.threshold == 32768' <<< "$METAL_LLM_EFFECTIVE_PROFILE"

resolve fast off '' '' ''
jq -e '.context == 32768 and .vision.enabled == false and .mtp.policy == "on"' \
  <<< "$METAL_LLM_EFFECTIVE_PROFILE"

resolve custom on tuned off 65536
jq -e '.profile_id == "custom" and .runtime_alias == "tuned" and
  .context == 65536 and .mtp.policy == "off"' <<< "$METAL_LLM_EFFECTIVE_PROFILE"
```

Add failures for missing each custom control, named-profile overrides, upstream plus `on`/`dynamic`, context `0` and `262145`, invalid vision, removed profile `vision`, and obsolete environment variable `METAL_LLM_CONTEXT`.

Update manifest tests to require model schema version 2, `default_profile`, `max_context`, runtime aliases, model-level vision/MTP capabilities, unique preset IDs, and exact preset tuples. Require hardware schema version 2 without `recommended_profile`.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```sh
zsh tests/test_profiles.sh
zsh tests/test_manifests.sh
```

Expected: missing resolver and old schema/manifest failures.

- [ ] **Step 3: Define schema version 2 and migrate the real manifests**

Change the model manifest to this separation of concerns:

```json
{
  "schema_version": 2,
  "default_profile": "auto",
  "max_context": 262144,
  "runtime_aliases": {
    "tuned": "llama-cpp-qwen38-hybrid",
    "upstream": "llama-cpp-upstream-stable"
  },
  "text_model": {
    "entry_artifact_id": "qwen38-text-00001",
    "artifact_ids": [
      "qwen38-text-00001", "qwen38-text-00002", "qwen38-text-00003",
      "qwen38-text-00004", "qwen38-text-00005", "qwen38-text-00006",
      "qwen38-text-00007", "qwen38-text-00008", "qwen38-text-00009",
      "qwen38-text-00010", "qwen38-text-00011", "qwen38-text-00012",
      "qwen38-text-00013", "qwen38-text-00014", "qwen38-text-00015",
      "qwen38-text-00016", "qwen38-text-00017", "qwen38-text-00018",
      "qwen38-text-00019", "qwen38-text-00020", "qwen38-text-00021",
      "qwen38-text-00022", "qwen38-text-00023", "qwen38-text-00024",
      "qwen38-text-00025", "qwen38-text-00026", "qwen38-text-00027",
      "qwen38-text-00028", "qwen38-text-00029", "qwen38-text-00030",
      "qwen38-text-00031", "qwen38-text-00032", "qwen38-text-00033"
    ],
    "total_bytes": 94525394976
  },
  "capabilities": {
    "vision": {
      "default_enabled": true,
      "projector_artifact_id": "qwen38-projector-f16",
      "image_min_tokens": 1024
    },
    "mtp": {
      "artifact_id": "qwen38-mtp-q8-0",
      "spec_type": "draft-mtp",
      "draft_n_max": 2,
      "gpu_layers": "all",
      "dynamic_threshold": 32768
    }
  },
  "profiles": [
    {"id":"fast","runtime":"tuned","context":32768,"mtp_policy":"on","status":"supported"},
    {"id":"long","runtime":"tuned","context":262144,"mtp_policy":"off","status":"supported"},
    {"id":"auto","runtime":"tuned","context":262144,"mtp_policy":"dynamic","status":"pending-acceptance"},
    {"id":"stable","runtime":"upstream","context":32768,"mtp_policy":"off","status":"reference"}
  ]
}
```

Preserve the exact 33-shard order shown above. Keep fixed inference flags once
at model level. Make the schema reject unknown aliases, duplicate profiles,
references to missing artifacts/runtimes, invalid policy combinations, or a
default absent from profiles.

Remove `recommended_profile` from the hardware schema and manifest rather than retaining two sources of truth.

- [ ] **Step 4: Implement the normalized resolver**

Create `lib/profile.zsh` with strict parsing helpers and no `eval`. The resolver defaults missing profile to the manifest default and missing vision to the capability default. For named profiles it rejects any supplied custom value. For custom it requires all three values and synthesizes the normalized object without adding a manifest profile.

Before success, cross-check artifact IDs, runtime alias IDs, context bounds, and policy/runtime compatibility. Export only one immutable JSON string in `METAL_LLM_EFFECTIVE_PROFILE`; consumers extract fields with `jq -er`.

- [ ] **Step 5: Update setup and artifact identity helpers**

Source `lib/profile.zsh` before consumers. Make setup provision every unique runtime in `.runtime_aliases` and every model, projector, and MTP artifact in model capabilities. Replace `metal_llm_profile_artifact_identities ... PROFILE_ID` with a normalized-configuration form so custom configurations and independent vision cannot bypass checksum identity.

Dry-run must still report exactly two runtime builds and 35 immutable artifact actions, but it must describe the new default and no longer mention hardware profile selection.

- [ ] **Step 6: Run focused and aggregate tests**

Run:

```sh
zsh tests/test_profiles.sh
zsh tests/test_manifests.sh
zsh tests/test_setup.sh
zsh tests/run.sh
```

Expected: all pass, including the newly discovered `tests/test_profiles.sh` in the aggregate runner.

- [ ] **Step 7: Commit the policy model**

```sh
git add lib/profile.zsh tests/test_profiles.sh bin/metal-llm \
  schemas/model.schema.json schemas/hardware.schema.json \
  manifests/models/qwen3.8-flash-next.json \
  manifests/hardware/apple-m5-max-128gb.json \
  lib/setup.zsh lib/runtime-state.zsh tests/test_manifests.sh tests/test_setup.sh
git commit -m "feat: centralize profile policy resolution"
```

---

### Task 3: Apply the new contract to serving and managed identity

**Files:**
- Modify: `lib/serve.zsh`
- Modify: `lib/managed-process.zsh`
- Modify: `bin/metal-llm`
- Modify: `tests/test_serve.sh`
- Modify: `tests/test_cli.sh`

**Interfaces:**
- Consumes: `METAL_LLM_EFFECTIVE_PROFILE` from Task 2 and the runtime option from Task 1.
- Produces: profile-optional serve CLI; independent `--vision on|off`; strict managed identity containing runtime alias, context, MTP policy/threshold, and vision state.

- [ ] **Step 1: Write failing serve and help tests**

Update test fixtures to schema version 2 and add exact dry-run assertions for:

```text
serve MODEL                              -> auto, tuned, 262144, vision, MTP head, threshold 32768
serve MODEL --profile fast              -> tuned, 32768, vision, fixed MTP, no threshold
serve MODEL --profile long --vision off -> tuned, 262144, no projector, no MTP
serve MODEL --profile stable            -> upstream, 32768, vision, no MTP
serve MODEL --profile custom --runtime tuned --mtp dynamic --context 65536 --vision off
```

Assert the old `--profile vision` and any non-empty `METAL_LLM_CONTEXT` fail with migration guidance. Assert named profiles reject custom controls, custom requires all controls, and upstream rejects MTP on/dynamic. Retain API-key redaction and all safe-passthrough adversarial tests.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```sh
zsh tests/test_cli.sh
zsh tests/test_serve.sh
```

Expected: old required-profile usage and coupled manifest parsing fail.

- [ ] **Step 3: Replace serve parsing and command construction**

Parse the public options into separate requested values and call the central resolver once. Build the server argument array only from normalized JSON:

- always use the resolved immutable runtime and target artifact;
- add projector arguments only when vision is on;
- add MTP arguments for policy `on` or `dynamic`;
- add `--spec-draft-max-prompt-tokens 32768` only for `dynamic`;
- never add the threshold or MTP artifact for policy `off`;
- remove all `METAL_LLM_CONTEXT` fallback logic.

Keep fixed Metal settings for both tuned and upstream runtimes. Preserve loopback, port, parallel, API key, receipt verification, managed lease, and passthrough allowlist behavior.

- [ ] **Step 4: Strengthen managed identity**

Replace the server-wide MTP boolean assumption with exact fields:

```json
{
  "profile_id": "auto",
  "runtime_alias": "tuned",
  "context": 262144,
  "vision": true,
  "mtp_policy": "dynamic",
  "mtp_threshold": 32768
}
```

Retain immutable runtime/build/artifact hashes, PID/start identity, endpoint, and owner token. Exact-key validation must reject old or partially upgraded records. Stale-record recovery must remain safe and must not signal PIDs.

- [ ] **Step 5: Update CLI help and migration diagnostics**

Show optional profile/default behavior, all preset names, `--vision on|off`, and the complete custom grammar. Remove `METAL_LLM_CONTEXT`. A removed `vision` profile error must say to select a preset and add `--vision on`.

- [ ] **Step 6: Verify serve behavior**

Run:

```sh
zsh tests/test_cli.sh
zsh tests/test_serve.sh
zsh tests/test_profiles.sh
zsh tests/run.sh
```

Expected: all pass; dry-run writes no lease or `.lab` state and never prints an API key.

- [ ] **Step 7: Commit the serve migration**

```sh
git add lib/serve.zsh lib/managed-process.zsh bin/metal-llm \
  tests/test_serve.sh tests/test_cli.sh
git commit -m "feat: serve orthogonal profile and vision policies"
```

---

### Task 4: Make benchmark provenance route-aware

**Files:**
- Modify: `lib/bench.zsh`
- Modify: `schemas/result.schema.json`
- Modify: `benchmarks/suites/qwen3.8-smoke.json`
- Modify: `tests/test_bench.sh`
- Modify: `tests/test_results.sh`
- Modify: `lib/report.zsh`
- Modify: `results/raw/2026-09-03-qwen38-m5-max.json` only for explicit schema compatibility, never invented measurements

**Interfaces:**
- Consumes: normalized endpoint configuration and final response timing metadata.
- Produces: route-aware benchmark rows with configured policy and actual `on`/`off` selection.

- [ ] **Step 1: Write failing endpoint identity and route tests**

Extend the fake endpoint to return final timing metadata for dynamic short and long cases. Assert endpoint mode rejects:

- a managed identity whose runtime alias, context, vision, policy, threshold, or artifacts differ;
- dynamic results missing route metadata;
- `speculative=true` above 32,768 or `speculative=false` at/below it;
- text-only counts substituted for expanded vision counts;
- route changes between streaming events;
- local `llama-bench` runs labeled as MTP `on` or `dynamic` even though that executable does not perform server speculative decoding.

Assert API keys remain forwarded and redacted.

- [ ] **Step 2: Run benchmark/result tests and verify RED**

Run:

```sh
zsh tests/test_bench.sh
zsh tests/test_results.sh
```

Expected: result schema and endpoint parser lack the new policy/route fields.

- [ ] **Step 3: Use the central resolver for endpoint benchmarks**

Accept the same profile, vision, and custom controls as serve when benchmarking a managed endpoint. If no profile is supplied, derive the exact configuration from the verified managed identity rather than assuming a suite default. A supplied configuration must exactly match the live identity.

Keep standalone `llama-bench` explicitly profileless and runtime-oriented. In
local mode, reject profile, vision, MTP, and context options; accept only
`--runtime tuned|upstream`, defaulting to `tuned`. Publish `profile_id`, vision,
MTP policy, selected route, effective prompt length, and threshold as JSON
`null`, while retaining the verified runtime/build identity and the benchmark's
own prompt/depth settings. Endpoint mode accepts the serve profile/vision/custom
controls and verifies them against managed identity. Update the shipped suite so
its default local microbench remains lightweight and its endpoint cases exercise
the managed `auto` server.

- [ ] **Step 4: Extend result provenance without rewriting history**

For new harness results require:

```json
{
  "profile_id": "auto",
  "runtime_alias": "tuned",
  "context": 262144,
  "vision": true,
  "mtp_policy": "dynamic",
  "mtp_selected": true,
  "effective_prompt_tokens": 32768,
  "mtp_threshold": 32768
}
```

Fixed policies use `mtp_selected` equal to their policy and `mtp_threshold: null`.
Imported historical runs retain their existing booleans/null provenance and gain only explicit JSON `null` fields if schema compatibility requires them. Do not infer a later profile, runtime alias, route, or context capacity.

Validate route/policy/count relationships before atomic no-clobber publication. Preserve calendar, privacy, secret, known-ID, suite/fixture, and exact-command validation.

- [ ] **Step 5: Update report rendering**

Make generic reports show configured policy separately from selected route. Historical summaries must render unchanged unless their source data explicitly changes. `report --check` must detect drift in any new generated route statement.

- [ ] **Step 6: Verify focused and aggregate behavior**

Run:

```sh
zsh tests/test_bench.sh
zsh tests/test_results.sh
./bin/metal-llm report --check
zsh tests/run.sh
```

Expected: all pass; the committed historical summary has no invented dynamic data.

- [ ] **Step 7: Commit route-aware evidence**

```sh
git add lib/bench.zsh schemas/result.schema.json \
  benchmarks/suites/qwen3.8-smoke.json tests/test_bench.sh \
  tests/test_results.sh lib/report.zsh results
git commit -m "feat: record dynamic MTP route provenance"
```

---

### Task 5: Rewrite profile documentation and integration harness

**Files:**
- Modify: `README.md`
- Modify: `docs/models/qwen3.8-flash-next.md`
- Modify: `docs/hardware/apple-m5-max-128gb.md`
- Modify: `docs/decisions/0002-dynamic-mtp-direction.md`
- Modify: `docs/troubleshooting/qwen3.8-flash-next.md`
- Modify: `CONTRIBUTING.md`
- Modify: `.github/ISSUE_TEMPLATE/benchmark.yml`
- Create: `tests/integration/test_dynamic_mtp.sh`
- Modify: `tests/test_repository.sh`

**Interfaces:**
- Produces: copy/paste documentation for every preset and its exact custom equivalent; opt-in hardware acceptance harness.

- [ ] **Step 1: Add failing documentation contract tests**

Require the README to contain the four exact equivalences:

```text
custom --runtime tuned --mtp on --context 32768 --vision on
custom --runtime tuned --mtp off --context 262144 --vision on
custom --runtime tuned --mtp dynamic --context 262144 --vision on
custom --runtime upstream --mtp off --context 32768 --vision on
```

Require `stable` to appear with both `reference` and `not recommended`, require vision-default-on language, and reject `--profile vision`, `--profile hybrid`, `METAL_LLM_CONTEXT`, or the old hardware-selection description outside archived plans/specs/history.

- [ ] **Step 2: Run the repository test and verify RED**

Run:

```sh
zsh tests/test_repository.sh
```

Expected: the README still documents the old profiles.

- [ ] **Step 3: Rewrite user and contributor documentation**

Lead the README quick start with:

```sh
./bin/metal-llm serve qwen3.8-flash-next
```

Add the preset table, exact custom-equivalent column, vision examples, validation rules, dynamic route semantics, API metadata example, and honest 256K acceptance status. Explain that both runtimes use Metal and that `tuned` versus `upstream`—plus MTP—is the source of the performance distinction.

Change ADR 0002 from `Proposed; not implemented` to `Implemented; pending hardware acceptance` until Task 6 passes. Record the actual patch revision/tree and the fixed 32,768 policy. Update troubleshooting for memory failure, unsupported custom combinations, removed interfaces, and route-metadata mismatches.

- [ ] **Step 4: Add an opt-in real integration harness**

Create `tests/integration/test_dynamic_mtp.sh`. It must require `METAL_LLM_INTEGRATION=1`, the exact M5 Max hardware match, verified artifacts/build receipts, and an otherwise clean managed-process lease. It must never download or build implicitly.

The harness starts one managed `auto` server, waits for health, and uses traps to stop only its recorded PID/start identity. It exercises:

- effective text lengths 32,767, 32,768, and 32,769;
- an image request whose text length is below but expanded count is above 32,768;
- streaming and non-streaming final metadata;
- slot reuse from short to long and long to short;
- simultaneous short and long requests with opposite routes;
- deterministic text, structured JSON, tool calling, and vision on both routes;
- rejection of a second managed full-model process.

Every response must agree on effective count, policy, threshold, fixed route, and draft statistics. Save sanitized raw evidence under `results/raw/` only through the existing result validator and atomic publisher.

- [ ] **Step 5: Verify docs and the skipped integration contract**

Run:

```sh
zsh tests/test_repository.sh
zsh tests/integration/test_dynamic_mtp.sh
zsh tests/run.sh
```

Expected: the integration script exits with an explicit SKIP when the opt-in variable is absent; all lightweight tests pass without loading a model.

- [ ] **Step 6: Commit documentation and harness**

```sh
git add README.md docs CONTRIBUTING.md .github/ISSUE_TEMPLATE/benchmark.yml \
  tests/integration/test_dynamic_mtp.sh tests/test_repository.sh
git commit -m "docs: explain preset and custom profile policies"
```

---

### Task 6: Run the M5 Max 256K acceptance and crossover validation

**Files:**
- Create: `docs/experiments/2026-09-03-dynamic-mtp-acceptance.md`
- Create: `results/raw/2026-09-03-qwen38-dynamic-mtp.json` only if measurements complete and validate
- Create: `results/summaries/qwen3.8-flash-next-dynamic-mtp.md` generated from validated raw data
- Modify: `README.md`
- Modify: `docs/decisions/0002-dynamic-mtp-direction.md`
- Modify: `manifests/models/qwen3.8-flash-next.json`
- Modify: `tests/test_results.sh`

**Interfaces:**
- Consumes: completed tuned build, verified Qwen artifacts, Task 5 integration harness.
- Produces: pass/fail evidence for making `auto` the ready recommended default.

- [ ] **Step 1: Verify prerequisites without mutation**

Run:

```sh
./bin/metal-llm doctor
./bin/metal-llm setup qwen3.8-flash-next --dry-run
./bin/metal-llm serve qwen3.8-flash-next --dry-run
```

Require exact M5 Max 128 GiB detection, trusted 13-patch runtime tree, matching build receipts, all artifact checksums, 262,144 context, projector, MTP head, and dynamic threshold. If build or artifacts are absent, run the documented explicit setup; do not install system packages automatically.

- [ ] **Step 2: Prove the complete allocation fits**

Start the default `auto` server with vision on and require health without Metal allocation failure. Record OS/build/artifact identities and memory observations. Confirm the managed identity reports tuned runtime, 262,144 context, vision on, dynamic policy, and threshold 32,768.

If allocation fails, stop this task. Preserve sanitized diagnostics, keep profile status `pending-acceptance`, do not call it recommended-ready, and return the memory/cache evidence to the user for a new design decision.

- [ ] **Step 3: Run correctness and isolation acceptance**

Run:

```sh
METAL_LLM_INTEGRATION=1 zsh tests/integration/test_dynamic_mtp.sh
```

Expected: every boundary, multimodal, streaming, slot-reuse, concurrency, correctness, and one-process assertion passes. A failure stops promotion and is recorded without weakening the test.

- [ ] **Step 4: Repeat boundary performance measurements**

Measure fixed MTP on, fixed MTP off, and dynamic selection at effective prompt lengths 29,000, 30,000, 32,767, 32,768, 32,769, 33,868, and a long calibration point. Use at least five measured repetitions after one warm-up per route, identical generation settings, and one full-model process at a time. Record individual samples, mean, sample standard deviation, draft acceptance, output hashes, route, and vision state.

The dynamic route must match the corresponding fixed route within a predeclared 5% throughput tolerance at each side; otherwise investigate overhead before promotion. Preserve output divergence rather than averaging it away.

- [ ] **Step 5: Publish validated acceptance evidence**

Write the raw result through the schema/privacy validator, generate its summary, and document method, failures, memory, route correctness, performance, and limitations. Add tests that the summary is derived from raw values and `report --check` detects drift.

Only after Steps 2–4 pass, change the `auto` manifest status from `pending-acceptance` to `recommended` and ADR status to `Implemented and accepted on Apple M5 Max 128 GiB`. Update README wording from pending to ready.

- [ ] **Step 6: Verify results and commit acceptance**

Run:

```sh
zsh tests/test_results.sh
./bin/metal-llm report --check
zsh tests/run.sh
git diff --check
```

Expected: all pass.

```sh
git add docs/experiments docs/decisions README.md manifests/models \
  results tests/test_results.sh
git commit -m "perf: validate dynamic MTP on M5 Max"
```

---

### Task 7: Final clean-clone verification and publication

**Files:**
- Modify only if verification exposes a defect; every change requires its own failing regression first.

**Interfaces:**
- Produces: reviewed branch ready to merge and a successful public macOS CI run.

- [ ] **Step 1: Run the complete local gate**

Run:

```sh
zsh tests/run.sh
./bin/metal-llm report --check
git diff --check
git diff --cached --check
git status --short
```

Expected: all checks pass and status is clean.

- [ ] **Step 2: Verify a clean clone without large mutation**

Clone the exact branch commit with `git clone --no-local`. Run lightweight tests, bootstrap diagnostics, report check, and setup/serve dry-runs. Require the dry-run to print the 13-patch tuned runtime, both runtime builds, verified artifacts, default `auto`, 262,144 context, vision projector, MTP head, and 32,768 threshold while leaving `.lab` absent.

- [ ] **Step 3: Request whole-branch review**

Review from the merge base through HEAD against the approved spec. Require explicit coverage of CLI removals, resolver single-source-of-truth, runtime patch reconstruction, post-MTMD gating, per-slot isolation, managed identity, result provenance, README custom equivalents, and the M5 Max acceptance evidence. Fix every Critical or Important issue with a regression and request a scoped re-review.

- [ ] **Step 4: Integrate using the branch-completion workflow**

After a clean review and fresh verification, present the standard merge/push/keep choice. Do not merge or delete the worktree without the user's choice.

- [ ] **Step 5: Push and require CI success after integration**

Push the selected branch/result to `bwangbos/metal-llm-lab`, wait for the macOS CI workflow, and require its conclusion to be `success`. Verify the remote commit equals the reviewed local commit and the repository remains public with MIT license metadata.
