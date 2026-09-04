# Cached Model-Artifact Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make metadata-bound cached SHA-256 receipts the safe default for every model-artifact-consuming command while retaining an explicit fresh-full verification path.

**Architecture:** A focused Zsh module owns model-artifact path safety, Darwin filesystem fingerprints, exact receipt validation/publication, per-invocation memoization, counters, effective-mode derivation, and receipt-set identity. Setup, serve, and bench use that module; managed identity and schema-version-2 benchmark provenance carry the verifier's normalized summary, while runtime/build/fixture/result verification remains uncached.

**Tech Stack:** Zsh, macOS `stat`/`lstat` semantics, `jq`, `shasum`, shell fixture tests, JSON Schema draft 2020-12, Markdown report generation.

**Spec:** `docs/superpowers/specs/2026-09-04-artifact-verification-cache-design.md`

## Global Constraints

- Supported hosts remain macOS on Apple Silicon; fingerprint capture uses Darwin `stat` and preserves nanosecond timestamps as strings.
- `cached` is the default; `full` is the only override; there is no `off` mode or equals-form option.
- Only model artifacts use this cache. Runtime source, build receipt, executable, manifest, suite, fixture, and result-evidence hashes remain fresh.
- New/resumed/replaced artifact bytes are always fully hashed before publication and use a receipt for the final path.
- Dry-runs may read receipts and artifact bytes but never create or update local state.
- Receipt storage is `.lab/verification/artifacts/MODEL_ID/ARTIFACT_ID.json` with owned `0700` directories and owned, single-link `0600` regular files.
- Managed identities advance to exact schema version 3. Newly generated results advance to schema version 2; tracked schema-version-1 results remain valid and unchanged.
- Cached verification does not claim equivalence to a fresh full SHA-256 against a malicious same-user local actor.
- Use `apply_patch` for repository edits, preserve unrelated work, and make each task pass its focused tests before committing.

## File and interface map

- Create `lib/artifact-verification.zsh`: all model-artifact receipt, fingerprint, cache, session, summary, and download-publication behavior.
- Create `tests/test_artifact_verification.sh`: small-file unit coverage for receipt safety, invalidation, modes, races, digest stability, and dry-run nonmutation.
- Modify `bin/metal-llm`: source the new module and advertise the shared option.
- Modify `lib/setup.zsh`: parse the option, reuse verifier state during disk preflight/acquisition, and delegate verified download publication.
- Modify `lib/serve.zsh`: parse the option, use verified paths, record verifier summary, and print the summary before process replacement.
- Modify `lib/bench.zsh`: parse the option in both modes, use verified paths, match endpoint receipt identity, and emit schema-version-2 provenance.
- Modify `lib/runtime-state.zsh`: remove direct model-artifact body hashing and delegate configuration/path trust to the new module; retain runtime verification unchanged.
- Modify `lib/managed-process.zsh`: validate exact schema-version-3 verifier identity.
- Modify `schemas/result.schema.json`: discriminate version 1 from version 2 and require verification provenance only for version 2.
- Modify `lib/report.zsh`: validate and render version-aware verification provenance without changing frozen historical evidence.
- Modify `tests/test_cli.sh`, `tests/test_setup.sh`, `tests/test_serve.sh`, `tests/test_bench.sh`, and `tests/test_results.sh`: command, identity, provenance, compatibility, and report regressions.
- Modify `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, and `docs/models/qwen3.8-flash-next.md`: user contract, trust boundary, and contributor guidance.

The shared module exposes these exact interfaces:

```zsh
metal_llm_artifact_verification_begin REQUESTED_MODE DRY_RUN
metal_llm_verify_model_artifact MODEL_MANIFEST MODEL_ID ARTIFACT_DIR ARTIFACT_ID
metal_llm_verify_configuration_artifacts MODEL_MANIFEST MODEL_ID ARTIFACT_DIR NORMALIZED_CONFIGURATION_JSON
metal_llm_verified_artifact_path ARTIFACT_ID
metal_llm_install_verified_artifact MODEL_MANIFEST MODEL_ID ARTIFACT_DIR ARTIFACT_ID PART_PATH
metal_llm_artifact_verification_finalize COMPLETE_SET
metal_llm_print_artifact_verification_summary
```

`metal_llm_artifact_verification_finalize` exports compact JSON in
`METAL_LLM_ARTIFACT_VERIFICATION_JSON`; configuration verification also exports
the existing ordered `METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES`. Verified paths
are held internally by artifact ID and retrieved with
`metal_llm_verified_artifact_path`.

---

### Task 1: Build the shared receipt verifier

**Files:**
- Create: `lib/artifact-verification.zsh`
- Create: `tests/test_artifact_verification.sh`
- Modify: `bin/metal-llm`

**Interfaces:**
- Consumes: `metal_llm_die`, `metal_llm_valid_id`, `metal_llm_file_size`, and `metal_llm_sha256` from `lib/common.zsh`; schema-v1 and schema-v2 model manifests.
- Produces: all seven shared interfaces in the file map, `METAL_LLM_ARTIFACT_VERIFICATION_JSON`, and `METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES`.

- [ ] **Step 1: Add the failing cold-cache, warm-cache, and full-mode tests**

Create a temporary model manifest with two tiny artifacts and source
`lib/common.zsh` plus the new module. Wrap only the model body hash helper and
append to a file so command-substitution subshells cannot hide body reads from
the test:

```zsh
artifact_hash_log="$temporary_root/artifact-hashes.log"
: > "$artifact_hash_log"
metal_llm_artifact_compute_sha256() {
    print -r -- "$1" >> "$artifact_hash_log"
    metal_llm_sha256 "$1"
}
artifact_hash_count() {
    wc -l < "$artifact_hash_log" | tr -d ' '
}

metal_llm_artifact_verification_begin cached 0
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
metal_llm_artifact_verification_finalize 1
(( $(artifact_hash_count) == 1 )) || fail 'cold cached verification did not hash once'
jq -e '.requested_mode == "cached" and .effective_mode == "full" and
  .cache_hits == 0 and .cache_misses == 1 and .full_hashes == 1' \
  <<< "$METAL_LLM_ARTIFACT_VERIFICATION_JSON" >/dev/null || fail 'bad cold summary'

: > "$artifact_hash_log"
metal_llm_artifact_verification_begin cached 0
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
metal_llm_artifact_verification_finalize 1
(( $(artifact_hash_count) == 0 )) || fail 'warm cached verification read artifact body'
jq -e '.effective_mode == "cached" and .cache_hits == 1 and
  .cache_misses == 0 and .full_hashes == 0' \
  <<< "$METAL_LLM_ARTIFACT_VERIFICATION_JSON" >/dev/null || fail 'bad warm summary'

: > "$artifact_hash_log"
metal_llm_artifact_verification_begin full 0
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
metal_llm_artifact_verification_finalize 1
(( $(artifact_hash_count) == 1 )) || fail 'forced full verification reused receipt'
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `zsh tests/test_artifact_verification.sh`

Expected: FAIL because `lib/artifact-verification.zsh` and its interfaces do not
exist.

- [ ] **Step 3: Implement session initialization, fingerprinting, and exact receipt validation**

In `lib/artifact-verification.zsh`, initialize fresh global associative arrays
and counters for each invocation. Validate mode and dry-run values before any
filesystem access:

```zsh
metal_llm_artifact_verification_begin() {
    local requested_mode=$1 dry_run=$2
    [[ "$requested_mode" == cached || "$requested_mode" == full ]] || {
        metal_llm_die "artifact check must be cached or full"
        return 1
    }
    [[ "$dry_run" == 0 || "$dry_run" == 1 ]] || {
        metal_llm_die 'artifact verification dry-run state must be 0 or 1'
        return 1
    }
    typeset -g METAL_LLM_ARTIFACT_CHECK_REQUESTED="$requested_mode"
    typeset -gi METAL_LLM_ARTIFACT_CHECK_DRY_RUN=$dry_run
    typeset -gi METAL_LLM_ARTIFACT_CACHE_HITS=0
    typeset -gi METAL_LLM_ARTIFACT_CACHE_MISSES=0
    typeset -gi METAL_LLM_ARTIFACT_FULL_HASHES=0
    typeset -gA METAL_LLM_ARTIFACT_PATHS=()
    typeset -gA METAL_LLM_ARTIFACT_FINGERPRINTS=()
    typeset -gA METAL_LLM_ARTIFACT_BINDINGS=()
    typeset -ga METAL_LLM_ARTIFACT_ORDER=()
    typeset -g METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES='[]'
    unset METAL_LLM_ARTIFACT_VERIFICATION_JSON
}
```

Capture `device_id`, `inode`, `size_bytes`, `%FB`, `%Fc`, and `%Fm` using
`/usr/bin/stat -f`. Reject symlinks before canonicalization, require the
canonical file to remain under the canonical artifact directory, require six
unambiguous tab-separated values, and require decimal/nine-fractional-digit
strings. Serialize the fingerprint with `jq -cS`. Put the absolute-stat calls
behind internal `metal_llm_artifact_lstat` and
`metal_llm_artifact_fingerprint` functions so tests can inject impossible local
ownership and mid-read mutation without making production behavior depend on
`PATH`.

Validate receipt parents and the receipt with `lstat`: effective UID ownership,
directory mode `0700`, file mode `0600`, regular type, no symlink, and link count
one. For a safe receipt, require the exact schema-v1 keys from the spec, exact
model/manifest/artifact/path/fingerprint values, and a recomputed stable
`binding_sha256`. Treat missing or safe malformed/stale receipts as misses;
return a distinct unsafe status for ownership/link/mode failures so callers fail
closed.

- [ ] **Step 4: Implement full hashing, atomic receipts, memoization, and finalization**

`metal_llm_verify_model_artifact` resolves the exact manifest record, verifies
the expected byte count, captures the pre-fingerprint, and either accepts a
cached receipt or calls `metal_llm_artifact_compute_sha256`. After a full hash,
capture the fingerprint again; retry the complete pre/hash/post sequence once
when it changed, then fail as unstable. Publish no receipt on byte or checksum
failure.

Write receipts with a unique same-directory `mktemp` name, `umask 077`, compact
exact JSON, self-validation, and atomic `mv -f`. Do not create the verification
tree in dry-run mode. Wrap construction/publication in Zsh's `always` cleanup so
failure or interruption removes only that invocation's unique temporary file.
Store the canonical path, fingerprint, and stable binding under the artifact
ID. On repeated verification, recapture and compare the fingerprint; unchanged
entries are reused without changing counters, while changed entries execute a
new decision.

Finalize a complete set (`COMPLETE_SET=1`) by sorting artifact IDs, hashing compact sorted JSON of
`{artifact_id,binding_sha256}`, and exporting:

```json
{
  "requested_mode": "cached",
  "effective_mode": "mixed",
  "cache_hits": 1,
  "cache_misses": 1,
  "full_hashes": 1,
  "receipt_set_sha256": "<64 lowercase hex>"
}
```

Derive `cached` for hits-only, `full` for hashes-only, and `mixed` for both.
For `COMPLETE_SET=0`, require dry-run mode, do not export persistence JSON or a
receipt-set digest, and derive display-only mode from the artifacts that exist,
using `not-run` only when none exists. Print the exact single-line summary from
the design. Add `source
"$METAL_LLM_ROOT/lib/artifact-verification.zsh"` immediately after
`lib/common.zsh` in `bin/metal-llm`.

- [ ] **Step 5: Add invalidation, safety, race, dry-run, and digest tests**

Extend `tests/test_artifact_verification.sh` with separate assertions for:

```zsh
# Same-size mutation must hash rather than hit.
print -n -- 'omega' > "$artifact_path" # fixture's original value is five-byte "alpha"
: > "$artifact_hash_log"
metal_llm_artifact_verification_begin cached 0
if metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a; then
    fail 'same-size checksum mutation was accepted'
fi
(( $(artifact_hash_count) == 1 )) || fail 'same-size mutation used cached receipt'

# Inode replacement with restored mtime must hash rather than hit.
print -n -- 'alpha' > "$artifact_path"
metal_llm_artifact_verification_begin full 0
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
metal_llm_artifact_verification_finalize 1
cp "$artifact_path" "$artifact_path.replacement"
touch -r "$artifact_path" "$artifact_path.replacement"
mv -f "$artifact_path.replacement" "$artifact_path"

# Full refresh changes time but not the stable set digest.
before_set=$(jq -r '.receipt_set_sha256' <<< "$cached_summary")
after_set=$(jq -r '.receipt_set_sha256' <<< "$full_summary")
[[ "$before_set" == "$after_set" ]] || fail 'verification time changed stable set digest'
```

Also mutate manifest SHA/bytes/path and every fingerprint field; cover safe
malformed JSON fallback; reject symlink, hard-linked, wrong-mode, wrong-owner
when the platform permits it, and unsafe parent receipts; prove checksum failure
publishes no replacement; prove two background refreshes leave one whole valid
receipt and no fixed `.part`; force an artifact change during hashing and verify
one retry followed by failure; prove dry-run hit/miss leaves a recursive
before/after path-and-SHA inventory unchanged; and prove reversed manifest order
produces the same receipt-set digest.

- [ ] **Step 6: Run focused and full tests**

Run: `zsh tests/test_artifact_verification.sh`

Expected: `artifact verification checks: PASS`

Run: `zsh tests/run.sh`

Expected: every existing test plus `tests/test_artifact_verification.sh` passes.

- [ ] **Step 7: Commit the shared verifier**

```bash
git add bin/metal-llm lib/artifact-verification.zsh tests/test_artifact_verification.sh
git commit -m "feat: add cached artifact receipt verifier"
```

### Task 2: Integrate cached verification with setup and downloads

**Files:**
- Modify: `lib/setup.zsh`
- Modify: `tests/test_setup.sh`
- Modify: `tests/test_cli.sh`

**Interfaces:**
- Consumes: Task 1 begin, verify, install, finalize, and summary interfaces.
- Produces: setup's public `--artifact-check cached|full` behavior, single-pass existing-artifact preflight, and fully verified final-path receipts for downloads.

- [ ] **Step 1: Write failing setup parser, cache, and download tests**

Update CLI/help expectations to include the option. In `tests/test_setup.sh`,
assert the default and explicit modes and usage status 2 for duplicate, missing,
`off`, unknown, and equals-form values:

```zsh
assert_contains "$help_output" 'setup MODEL [--artifact-check cached|full]'
assert_setup_usage_rejected 'missing value' fixture-model --artifact-check
assert_setup_usage_rejected 'disabled verification' fixture-model --artifact-check off
assert_setup_usage_rejected 'equals form' fixture-model --artifact-check=full
assert_setup_usage_rejected 'duplicate' fixture-model --artifact-check cached --artifact-check full
```

Instrument the fixture hash command to append only GGUF paths to a log. Run
setup twice in default cached mode and require one GGUF hash during initial
download, then zero on the warm run. Run with `--artifact-check full` and require
one. Require the receipt path to name the final artifact, and require
`requested=cached effective=full` after initial download and
`requested=cached effective=cached` when warm.

For dry-run, create a stale safe receipt, inventory `.lab`, run setup, require a
read-only body hash, and compare the inventory byte-for-byte afterward. Keep the
existing all-missing 35-artifact dry-run assertion and require no verification
directory.

- [ ] **Step 2: Run setup and CLI tests to verify RED**

Run: `zsh tests/test_cli.sh && zsh tests/test_setup.sh`

Expected: FAIL because setup does not parse or propagate `--artifact-check` and
downloads do not publish artifact receipts.

- [ ] **Step 3: Parse and initialize the setup verification session**

Add `artifact_check=cached` and one duplicate guard to `metal_llm_setup`; accept
only a separate `cached` or `full` value. Update `metal_llm_setup_usage` and root
help. Call `metal_llm_artifact_verification_begin "$artifact_check" "$dry_run"`
only after host, command, model ID, and manifest validation have succeeded.

Refactor `metal_llm_remaining_artifact_bytes` to set
`METAL_LLM_REMAINING_ARTIFACT_BYTES` instead of being invoked through command
substitution. For an existing final artifact, call the shared verifier directly;
for a missing final path, retain partial-size accounting. This preserves the
session state for the later acquisition loop.

- [ ] **Step 4: Replace duplicate existing checks and centralize downloaded publication**

When the acquisition loop sees an existing final path, call the shared verifier;
its unchanged per-invocation fingerprint reuses the preflight result without a
second body hash or counter. For a completed or newly downloaded `.part`, call:

```zsh
metal_llm_install_verified_artifact \
  "$model_manifest" "$model_id" "$artifact_dir" "$artifact_id" "$part_path"
```

That interface owns byte/hash verification, final-path non-overwrite, `mv`,
final fingerprint capture, receipt publication, and session registration. Setup
must not hash or move the part independently afterward.

After every artifact is present, call `metal_llm_artifact_verification_finalize
1` and print the shared summary before `next command:`. If any setup dry-run
artifact is missing, call `metal_llm_artifact_verification_finalize 0`; this
prints counts for existing artifacts, uses `effective=not-run` only when none
exist, and emits no digest.

- [ ] **Step 5: Run focused and full tests**

Run: `zsh tests/test_cli.sh && zsh tests/test_setup.sh && zsh tests/test_artifact_verification.sh`

Expected: all three print `PASS`.

Run: `zsh tests/run.sh`

Expected: `all checks: PASS`.

- [ ] **Step 6: Commit setup integration**

```bash
git add bin/metal-llm lib/setup.zsh tests/test_cli.sh tests/test_setup.sh
git commit -m "feat: cache setup artifact verification"
```

### Task 3: Use the shared verifier in serve and both benchmark modes

**Files:**
- Modify: `lib/runtime-state.zsh`
- Modify: `lib/serve.zsh`
- Modify: `lib/bench.zsh`
- Modify: `tests/test_serve.sh`
- Modify: `tests/test_bench.sh`
- Modify: `tests/test_cli.sh`

**Interfaces:**
- Consumes: Task 1 verifier/session/path interfaces and Task 2 CLI wording.
- Produces: one consistent artifact-check option and one nonredundant verification pass for serve, local bench, and endpoint bench. Identity/result schemas remain unchanged until Task 4.

- [ ] **Step 1: Add failing command parsing and no-rehash tests**

For serve and bench, add usage-status-2 coverage for missing, duplicate, `off`,
unknown, and equals-form values. Verify `serve ... -- --artifact-check full` is
rejected by the existing passthrough allowlist rather than interpreted as the
lab option.

In both fixture suites, log GGUF body hashes. Require a cold default run to
report full, a warm default dry-run to report cached without a body read, and an
explicit full dry-run to read every required artifact without changing receipt
files. Cover local bench's text-model set and endpoint bench's exact resolved
model/projector/MTP set.

Require each command to print one summary and prove the model entry artifact is
not rehashed when its path is inserted into the executable command.

- [ ] **Step 2: Run serve, bench, and CLI tests to verify RED**

Run: `zsh tests/test_cli.sh && zsh tests/test_serve.sh && zsh tests/test_bench.sh`

Expected: FAIL because serve/bench do not accept the option and
`metal_llm_artifact_path` still hashes independently.

- [ ] **Step 3: Delegate configuration verification and path lookup**

Replace `metal_llm_profile_artifact_identities` in `lib/runtime-state.zsh` with a
thin compatibility removal: all callers use
`metal_llm_verify_configuration_artifacts`. Change `metal_llm_artifact_path` to
call `metal_llm_verified_artifact_path`; it must no longer read bytes or resolve
manifest records.

In serve and bench, parse `artifact_check=cached`, initialize after normalized
configuration and manifests validate, verify the exact configuration artifact
set, finalize with `COMPLETE_SET=1`, then obtain required paths from verified state. Keep runtime
build verification fresh and unchanged.

Endpoint dry-run has no live identity but still verifies any existing local
artifacts under the resolved configuration. Non-dry-run endpoint bench verifies
artifacts before matching the live endpoint. Print the shared summary before
serve `exec` and before benchmark execution/publication.

- [ ] **Step 4: Update exact-output fixtures without weakening assertions**

Where serve tests currently compare a command as the entire output, split the
two expected lines explicitly:

```zsh
assert_contains "$auto_output" 'artifact verification: requested=cached effective=cached'
assert_contains "$auto_output" "$common_hybrid -c 262144 $network_defaults"
assert_count "$auto_output" 'artifact verification:' 1
```

Do not replace exact command-content assertions with a generic success check.
Retain the before/after `.lab` inventory assertions for dry-runs.

- [ ] **Step 5: Run focused and full tests**

Run: `zsh tests/test_cli.sh && zsh tests/test_serve.sh && zsh tests/test_bench.sh`

Expected: all three print `PASS`.

Run: `zsh tests/run.sh`

Expected: `all checks: PASS`.

- [ ] **Step 6: Commit command integration**

```bash
git add bin/metal-llm lib/runtime-state.zsh lib/serve.zsh lib/bench.zsh tests/test_cli.sh tests/test_serve.sh tests/test_bench.sh
git commit -m "feat: verify serve and bench artifacts through receipts"
```

### Task 4: Bind verification to managed identity and versioned result provenance

**Files:**
- Modify: `lib/managed-process.zsh`
- Modify: `lib/serve.zsh`
- Modify: `lib/bench.zsh`
- Modify: `schemas/result.schema.json`
- Modify: `tests/test_serve.sh`
- Modify: `tests/test_bench.sh`
- Modify: `tests/test_results.sh`

**Interfaces:**
- Consumes: finalized `METAL_LLM_ARTIFACT_VERIFICATION_JSON` from Tasks 1 and 3.
- Produces: exact managed identity schema 3, endpoint receipt-set matching, result schema 2, and version-aware compatibility for untouched schema-1 evidence.

- [ ] **Step 1: Write failing managed-identity and endpoint matching tests**

Require newly started serve and local-bench identity JSON to have exact schema 3
and the six verifier keys. Reject missing, extra, negative, invalid-mode, invalid
digest, and impossible counter combinations. The consistency expression is:

```jq
if .effective_mode == "cached" then
  .cache_hits > 0 and .cache_misses == 0 and .full_hashes == 0
elif .effective_mode == "full" then
  .cache_hits == 0 and .full_hashes > 0
else
  .effective_mode == "mixed" and .cache_hits > 0 and .full_hashes > 0
end
```

Create endpoint fixtures where server and benchmark modes/counters differ but
the receipt-set digest matches; require acceptance. Change only the digest and
require `managed endpoint identity does not match resolved configuration`.
Provide a schema-2 live identity and require exact-schema rejection.

- [ ] **Step 2: Write failing result-schema and provenance tests**

Require new benchmark output to use `schema_version: 2` and contain the exact
verification object. Validate each existing tracked schema-1 result unchanged.
Create mutations that delete the object from v2, add it to v1, change its digest,
or create impossible counters, and require schema/report rejection.

The schema must discriminate on `schema_version`, not make the new object
globally optional:

```json
{
  "oneOf": [
    {"$ref": "#/$defs/result_v1"},
    {"$ref": "#/$defs/result_v2"}
  ]
}
```

- [ ] **Step 3: Run identity and result tests to verify RED**

Run: `zsh tests/test_serve.sh && zsh tests/test_bench.sh && zsh tests/test_results.sh`

Expected: FAIL because managed identity is schema 2 and benchmark results are
schema 1 without verifier provenance.

- [ ] **Step 4: Advance managed identity to exact schema 3**

Add `artifact_verification` to the exact top-level key set and emit schema 3 in
`metal_llm_acquire_managed_lease`. Validate exact nested keys, mode enums,
non-negative integer counters, a lowercase 64-hex digest, and the consistency
expression from Step 1.

Serve and local bench pass the finalized verifier JSON into their identity
builders. Endpoint bench compares adjacent artifact arrays as today and compares
only `artifact_verification.receipt_set_sha256` across invocations; it does not
require startup and benchmark requested/effective modes or counters to match.

- [ ] **Step 5: Implement result schema 2 while preserving version 1**

Refactor shared JSON Schema definitions for common result fields and define
version-specific provenance objects:

- v1 retains the exact current allowed/required keys and `schema_version: 1`;
- v2 uses `schema_version: 2`, requires `artifact_verification` for non-null
  provenance, and validates the same exact object as managed identity;
- v2 benchmark generation always has non-null provenance;
- no tracked raw result is rewritten or annotated.

Set new benchmark result documents to schema 2 in `lib/bench.zsh` and add
`artifact_verification: $artifact_verification` to the provenance builder. For
endpoint benchmarks this is the benchmark invocation's summary, not a copy of
the server-start summary.

- [ ] **Step 6: Run focused and full tests**

Run: `zsh tests/test_serve.sh && zsh tests/test_bench.sh && zsh tests/test_results.sh`

Expected: all three print `PASS`.

Run: `zsh tests/run.sh`

Expected: `all checks: PASS`, including unchanged frozen result/report checks.

- [ ] **Step 7: Commit identity and provenance**

```bash
git add lib/managed-process.zsh lib/serve.zsh lib/bench.zsh schemas/result.schema.json tests/test_serve.sh tests/test_bench.sh tests/test_results.sh
git commit -m "feat: record artifact verification provenance"
```

### Task 5: Render verifier provenance and document the trust boundary

**Files:**
- Modify: `lib/report.zsh`
- Modify: `tests/test_results.sh`
- Modify: `README.md`
- Modify: `SECURITY.md`
- Modify: `CONTRIBUTING.md`
- Modify: `docs/models/qwen3.8-flash-next.md`

**Interfaces:**
- Consumes: schema-version-2 `provenance.artifact_verification` from Task 4.
- Produces: report validation/rendering and complete user/contributor guidance; schema-1 generated summaries remain byte-for-byte stable.

- [ ] **Step 1: Add failing report rendering and drift tests**

Build a temporary valid schema-2 local result from the benchmark fixture, run
the report renderer, and require these lines:

```text
- Artifact verification requested/effective: `cached` / `mixed`
- Artifact verification counts (hits/misses/full): `1` / `1` / `1`
- Artifact receipt set: `<64 lowercase hex>`
```

Change each raw field without regenerating the summary and require
`metal-llm report --check` to detect drift. Hash every tracked schema-1 summary
before and after a normal report generation/check and require equality.

- [ ] **Step 2: Run result tests to verify RED**

Run: `zsh tests/test_results.sh`

Expected: FAIL because reports do not validate or render artifact-verification
provenance.

- [ ] **Step 3: Add version-aware report validation and rendering**

In `lib/report.zsh`, add one jq helper for the exact verification object and use
it only for schema-2 results. Preserve existing route/provenance validation.
Render requested/effective mode, counts, and receipt-set digest in the
reproducibility/provenance section for v2. Leave all schema-1 formatting paths
unchanged so frozen historical Markdown does not drift.

- [ ] **Step 4: Update user-facing and security documentation**

In `README.md`:

- add `--artifact-check cached|full` to setup, serve, and bench examples;
- say cached is the default and a warm run avoids rereading GGUF bodies;
- explain cache hit/miss/full summaries and local receipt location;
- distinguish artifact receipts, runtime build receipts, and managed leases;
- recommend full mode after suspicious changes, metadata-preserving restores,
  and before high-stakes benchmark publication.

In `SECURITY.md`, state that a malicious same-user actor able to spoof all bound
metadata or modify after verification is outside cached mode's integrity claim,
and that full mode narrows but does not eliminate check/use races.

In `CONTRIBUTING.md`, require receipt/provenance regression coverage for verifier
changes and prohibit routing non-model integrity checks into this cache. In the
Qwen model guide, document the roughly 100 GB cold/full read cost and warm
cached workflow.

- [ ] **Step 5: Run docs, report, and full tests**

Run: `zsh tests/test_results.sh && zsh tests/test_cli.sh && zsh tests/test_repository.sh`

Expected: all three print `PASS`.

Run: `zsh tests/run.sh`

Expected: `all checks: PASS`.

- [ ] **Step 6: Commit reports and documentation**

```bash
git add lib/report.zsh tests/test_results.sh README.md SECURITY.md CONTRIBUTING.md docs/models/qwen3.8-flash-next.md
git commit -m "docs: explain cached artifact verification"
```

### Task 6: Verify the completed feature from a clean consumer checkout

**Files:**
- Modify only if verification exposes a defect; add a focused failing regression before each corrective change.

**Interfaces:**
- Consumes: Tasks 1-5 and the approved design.
- Produces: clean-checkout evidence that the CLI, receipts, schemas, dry-runs, and documentation work together without real model downloads.

- [ ] **Step 1: Run static and repository-wide verification**

Run:

```bash
zsh -n bin/metal-llm lib/*.zsh tests/*.sh
git diff --check origin/main...HEAD
zsh tests/run.sh
./bin/metal-llm report --check
```

Expected: syntax exit 0, no diff-check output, `all checks: PASS`, and report
check exit 0 with no generated drift.

- [ ] **Step 2: Verify the public contract in an isolated clone**

Create a temporary clone of the exact branch with `git clone --no-local`, then
run fixture-backed command tests plus the real all-missing setup dry-run:

```bash
./bin/metal-llm help
./bin/metal-llm setup qwen3.8-flash-next --artifact-check cached --dry-run
./bin/metal-llm setup qwen3.8-flash-next --artifact-check full --dry-run
zsh tests/test_setup.sh
zsh tests/test_serve.sh
zsh tests/test_bench.sh
```

Expected: help advertises the shared option; both modes parse; setup dry-runs
show 35 planned artifacts; the fixture-backed serve test retains
auto/vision/dynamic-MTP command generation; fixture-backed local and endpoint
bench modes pass; no dry-run creates `.lab`.

- [ ] **Step 3: Audit the implementation against the approved spec**

Check each spec section explicitly: all three command parsers; default cached;
no off mode; exact receipt path/schema/ownership; six fingerprint fields;
stable binding and set digest; forced full; download full hashing; memoization;
dry-run nonmutation; summaries; identity schema 3; result v1/v2 compatibility;
endpoint digest matching; report drift; security language; all 17 required test
categories. Record any missing item as a failing test before editing code.

- [ ] **Step 4: Commit any verification-driven corrections**

If Step 1-3 required a correction, commit only its regression and fix:

```bash
git add bin/metal-llm lib/artifact-verification.zsh lib/setup.zsh lib/serve.zsh lib/bench.zsh lib/runtime-state.zsh lib/managed-process.zsh lib/report.zsh schemas/result.schema.json tests/test_artifact_verification.sh tests/test_cli.sh tests/test_setup.sh tests/test_serve.sh tests/test_bench.sh tests/test_results.sh README.md SECURITY.md CONTRIBUTING.md docs/models/qwen3.8-flash-next.md
git commit -m "fix: close artifact verification gap"
```

If no correction was needed, do not create an empty commit.

- [ ] **Step 5: Request code review before integration**

Review `origin/main...HEAD` against both the design and this plan. Require zero
Critical or Important findings, rerun each affected focused test after review
fixes, then rerun `zsh tests/run.sh` and `./bin/metal-llm report --check` before
offering merge/push/worktree choices.
