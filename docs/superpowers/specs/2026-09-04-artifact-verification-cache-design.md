# Cached model-artifact verification

- Status: Proposed design; awaiting user approval
- Date: 2026-09-04

## Context

Model-artifact verification currently computes a fresh SHA-256 for every required
GGUF on every `setup`, `serve`, and `bench` invocation. The Qwen3.8-Flash-Next
artifact set is approximately 100 GB, so repeatedly reading it all delays normal
operation and creates avoidable storage and CPU load.

The checks protect an important invariant: a process or benchmark must use the
exact bytes named by the model manifest. This design keeps that invariant while
making a metadata-bound receipt the normal fast path. A user can still request a
fresh full read whenever the stronger check is appropriate.

## Goals

- Make cached verification the default for every command that consumes model
  artifacts: `setup`, `serve`, and `bench`.
- Provide one explicit override, `--artifact-check cached|full`, with no unsafe
  `off` mode.
- Reuse a prior full SHA-256 only when an exact, safe receipt and the artifact's
  current filesystem identity agree.
- Fall back to a full SHA-256 and refresh the receipt on every ordinary cache
  miss.
- Always fully hash newly downloaded, resumed, or replaced artifact bytes before
  use.
- Avoid duplicate hashes of the same artifact within one command.
- Make the requested and effective verification modes observable in managed
  process identity and new benchmark provenance.
- Keep dry-runs read-only.

## Non-goals

- No option to skip all integrity verification.
- No cache for runtime source trees, build receipts, executables, benchmark
  fixtures, manifests, suites, or result evidence. Their existing verification
  remains unchanged.
- No daemon, database, extended attributes, or filesystem watcher.
- No claim that metadata-bound cached verification is equivalent to a fresh
  full SHA-256 against a malicious same-user local actor.
- No compatibility promise for receipt files. They are reconstructable local
  state, not a public interchange format.

## Public CLI contract

The artifact-consuming commands accept the same option:

```text
metal-llm setup MODEL [--artifact-check cached|full] [--dry-run] [--yes]

metal-llm serve MODEL
  [--profile fast|long|auto|stable|custom]
  [--vision on|off]
  [--runtime tuned|upstream --mtp on|off|dynamic --context TOKENS]
  [--artifact-check cached|full]
  [--dry-run]
  [-- EXTRA_LLAMA_ARGS]

metal-llm bench MODEL --suite SUITE
  [--mode local|endpoint]
  [existing profile/runtime/vision controls]
  [--artifact-check cached|full]
  [--dry-run]
```

Omitting the option is exactly equivalent to `--artifact-check cached`.
`--artifact-check full` forces a fresh SHA-256 of every required existing model
artifact, regardless of a valid receipt. Missing values, duplicate occurrences,
unknown values, `--artifact-check=...`, and the removed idea of `off` are usage
errors. The option must appear before `serve`'s `--` separator so it cannot be
confused with a llama-server argument.

`doctor` does not read model artifacts and therefore does not accept this
option. `report` validates benchmark/result evidence, not installed model
artifacts, and also does not accept it. Help and documentation describe the
scope as “every artifact-consuming command,” not literally every subcommand.

## Verification modes

### Cached mode

For each required artifact, cached mode performs the following decision:

1. Validate the manifest, artifact ID, expected byte count, and expected
   SHA-256 as today.
2. Require the artifact path to exist as a regular, non-symlink file and remain
   inside the model's artifact directory after canonicalization.
3. Read its current filesystem fingerprint with macOS `lstat` semantics.
4. Validate the corresponding receipt's path safety, exact schema, binding
   digest, manifest identity, artifact identity, expected values, canonical
   path, and filesystem fingerprint.
5. If every value matches, count a cache hit and do not read the artifact body.
6. Otherwise, count a cache miss, compute the full SHA-256, and reject a byte or
   checksum mismatch. If verification succeeds, publish a refreshed receipt
   atomically and count one full hash.

A missing, stale, unknown-version, malformed-JSON, or wrong-schema receipt is a
normal cache miss when the receipt path itself is safe. An unsafe receipt path,
owner, link, or parent directory fails closed instead of being overwritten.

### Full mode

Full mode does not consult receipts to decide trust. It performs the same file
safety, byte-count, full SHA-256, and pre/post-fingerprint checks for every
required artifact. A successful non-dry-run check refreshes its receipt so later
cached commands can benefit. A checksum failure publishes nothing.

### Downloads and replacements

Setup never treats downloaded or resumed `.part` bytes as cached. It verifies
the completed partial file's byte count and full SHA-256, moves it to the final
path without overwriting an existing artifact, captures the final path's
fingerprint, and then publishes a receipt. The receipt describes the final file,
not the `.part` path.

An existing final artifact that does not match its manifest continues to fail;
setup does not silently overwrite it. Safe cache behavior must not weaken the
existing download and replacement rules.

## Shared verifier and invocation state

A new shared artifact-verification module is the only code allowed to establish
model-artifact trust. Setup preflight, setup acquisition, serve, local bench,
and endpoint bench all call it. `metal_llm_artifact_path` becomes a lookup over
the current verified invocation state rather than independently hashing the
same path again.

The verifier maintains per-process state keyed by model manifest SHA-256,
artifact ID, canonical path, and current filesystem fingerprint. A repeated use
within the same command rechecks the cheap fingerprint and reuses the earlier
decision only if it is unchanged. It does not increment counters twice. A
changed fingerprint re-enters normal verification. This removes setup's current
preflight/acquisition duplication and the profile-identity/path duplication in
serve and bench without allowing a stale path to pass silently.

The state exports:

- the ordered artifact identity array already used by managed identity and
  results;
- canonical verified paths for command construction;
- requested mode;
- cache-hit, cache-miss, and full-hash counts;
- effective mode; and
- the receipt-set SHA-256.

Callers do not reconstruct these values independently.

## Receipt location and safety

Receipts live under the ignored local state tree:

```text
.lab/verification/artifacts/MODEL_ID/ARTIFACT_ID.json
```

Model and artifact IDs have already passed the repository's strict ID grammar,
so they cannot add path components. The verification root and model directory
must be real directories, owned by the effective user, and mode `0700`; no path
component may be a symlink. A receipt must be a regular non-symlink file owned
by the effective user, have link count one, and have mode `0600`.

The verifier creates missing safe directories with mode `0700`. If an existing
path violates these rules, it fails with an actionable error. It never repairs,
deletes, or replaces an unsafe object automatically.

Each refresh writes a uniquely named temporary file in the same directory with
mode `0600`, validates the completed JSON, and atomically renames it over the
safe destination. Unique temporary names allow concurrent verifiers; readers
see either a complete old receipt or a complete new receipt, never partial JSON.
Equivalent concurrent refreshes may race and the last complete rename may win.
Temporary files are not cache candidates. Atomic rename guarantees publication
visibility, not power-loss durability.

## Receipt schema

Receipt JSON uses exact keys and schema version 1:

```json
{
  "schema_version": 1,
  "model_id": "qwen3.8-flash-next",
  "model_manifest_sha256": "<64 lowercase hex>",
  "artifact_id": "qwen38-text-00001",
  "artifact_bytes": 3000000000,
  "artifact_sha256": "<64 lowercase hex>",
  "canonical_path": "/absolute/path/to/artifact.gguf",
  "file": {
    "device_id": "16777234",
    "inode": "42485393",
    "size_bytes": "3000000000",
    "birth_time": "1788557171.601454501",
    "change_time": "1788557171.601561377",
    "modify_time": "1788557171.601561377"
  },
  "binding_sha256": "<64 lowercase hex>",
  "full_verified_at": "2026-09-04T16:00:00Z"
}
```

Device, inode, size, and timestamps are decimal strings so `jq` cannot lose
64-bit or nanosecond precision. Times come from Darwin `stat`'s floating-point
`%F` forms and contain exactly nine fractional digits. `full_verified_at` comes
from `/bin/date -u`, is informational, and records the most recent successful
full read represented by that receipt.

`binding_sha256` is the SHA-256 of UTF-8, compact, recursively key-sorted JSON
containing every receipt field except `binding_sha256` and
`full_verified_at`, with no trailing newline. Excluding only the verification
timestamp keeps the binding stable when forced full verification confirms the
same file. Receipt validation recomputes this digest; it never trusts the field
by itself.

The fingerprint binds device, inode, exact size, birth time, inode-change time,
and modification time. A same-size ordinary mutation changes at least change or
modification time and misses the cache. Replacing the file changes its inode or
birth time and misses the cache. The verifier captures a fingerprint immediately
before and after a full hash and accepts it only when both are identical. One
bounded retry handles a benign race; a second change fails rather than recording
an unstable file.

## Receipt-set digest

After all required artifacts are verified, the shared verifier sorts them by
artifact ID and constructs compact, recursively key-sorted JSON with no trailing
newline:

```json
[
  {"artifact_id":"qwen38-projector-f16","binding_sha256":"..."},
  {"artifact_id":"qwen38-text-00001","binding_sha256":"..."}
]
```

The SHA-256 of those bytes is `receipt_set_sha256`. This digest identifies the
stable set of manifest/path/filesystem bindings used by the invocation. It does
not hash raw receipt files and intentionally excludes `full_verified_at`, so a
forced full recheck of unchanged artifacts does not make a running server's
artifact identity incomparable with a later endpoint benchmark.

The ordered artifact identity array remains the authoritative expected-content
list. The receipt-set digest supplements it with the local filesystem bindings
that justified reuse.

## Effective mode and reporting

Every non-dry-run artifact-consuming command prints one final summary:

```text
artifact verification: requested=cached effective=mixed cache_hits=31 cache_misses=2 full_hashes=2 receipt_set_sha256=<sha256>
```

The counters count unique artifact decisions in that invocation:

- `cache_hits`: valid receipts used without a content read;
- `cache_misses`: cached-mode lookups that required a content read; and
- `full_hashes`: successful or attempted full content hashes, whether forced,
  caused by a miss, or required for a completed download.

The command fails before printing a success summary if any required artifact
fails. Diagnostic output may still identify the failing artifact and decision.

Effective mode is derived, never user supplied:

- `cached`: one or more artifacts were verified and every decision was a cache
  hit;
- `full`: one or more artifacts were verified and every artifact was fully
  hashed; or
- `mixed`: at least one artifact was a cache hit and at least one was fully
  hashed.

There is no persisted zero-artifact case. A setup dry-run with only missing
artifacts may display `effective=not-run`, but `not-run` is not valid managed or
benchmark provenance.

## Dry-run behavior

Dry-runs may read and validate existing receipts but never create directories,
temporary files, receipts, downloads, builds, identities, or results. For an
existing artifact, cached mode uses a valid receipt or performs a read-only full
hash on a miss. Full mode performs a read-only full hash. A missing setup
artifact remains a planned download and is not invented as a verification
success.

Dry-run output includes the requested mode and the hit/miss/full counts for
artifacts that actually exist. It labels missing downloads separately and does
not emit a receipt-set digest for an incomplete set.

## Managed identity

Managed identity advances to schema version 3 and adds this exact object:

```json
"artifact_verification": {
  "requested_mode": "cached",
  "effective_mode": "mixed",
  "cache_hits": 31,
  "cache_misses": 2,
  "full_hashes": 2,
  "receipt_set_sha256": "<64 lowercase hex>"
}
```

The object is validated with exact keys and consistent non-negative counters.
Its receipt-set digest must cover exactly the artifacts in the adjacent identity
array. Old or partially upgraded live identity records fail closed under the
existing exact-schema policy.

Endpoint bench performs its own verification using its requested mode. When it
checks the live server identity, required artifact identities and
`receipt_set_sha256` must match. Its requested/effective modes and counters need
not equal those from server startup: they describe different invocations. This
allows, for example, a `--artifact-check full` endpoint benchmark to confirm an
unchanged server artifact set without a false identity mismatch.

## Benchmark provenance and compatibility

New benchmark results advance to result schema version 2 and add the same
`artifact_verification` object to provenance. It describes the benchmark
invocation, not the earlier setup run and not the server startup run.

The result schema continues to validate existing schema-version-1 tracked
results exactly as they are. Version 1 neither accepts nor requires invented
artifact-verification provenance. Version 2 requires the new object whenever
provenance is non-null. Newly generated local and endpoint benchmark results are
always version 2. Report validation and summaries preserve the distinction and
must not rewrite historical version-1 evidence.

Generated reports include requested/effective mode, counts, and receipt-set
digest for version-2 results. Report checks reject missing fields, impossible
counter/mode combinations, an invalid digest, or drift between raw data and
generated Markdown.

## Failure behavior

- Missing artifact, byte mismatch, checksum mismatch, unsafe artifact path, or
  an artifact that changes during hashing fails before process launch or result
  publication.
- Unsafe receipt storage fails closed. Safe but absent, malformed, stale, or
  unknown receipts fall back to a full hash.
- Receipt-write failure fails the non-dry-run command even after the artifact
  hash succeeds; the command must not claim cached provenance it could not
  persist.
- Unsupported `stat` output or a fingerprint field that cannot be captured
  fails with an actionable macOS/filesystem diagnostic. It never silently drops
  a binding field.
- A checksum failure leaves any prior stale receipt untrusted and publishes no
  replacement.
- Interrupt cleanup removes only the current invocation's uniquely named
  temporary receipt, never another process's receipt or artifact.

## Trust boundary

Cached verification is designed to detect ordinary local changes efficiently:
edits, truncation, replacement, download damage, and stale manifests. It is not
cryptographic proof of current content against an attacker who can act as the
same local user and preserve or spoof all bound filesystem metadata, manipulate
the file after verification, or exploit the unavoidable check/use interval.

The README and security documentation must state this limitation plainly.
Users should choose `--artifact-check full` after suspected local tampering,
after restoring artifacts through unusual snapshot/metadata-preserving tools,
and before publishing high-stakes benchmark evidence. Full mode narrows the
assumption to the existing check/use interval but cannot eliminate local TOCTOU
without changing how the runtime opens and retains the verified file.

## Required tests

Implementation is test-driven and includes at least:

1. CLI parsing/defaults for setup, serve, local bench, and endpoint bench;
   duplicate, missing, `off`, unknown, and equals-form rejection; and serve
   separator behavior.
2. First cached check misses, fully hashes, writes one exact receipt, and a
   second check hits without invoking the hash implementation.
3. Manifest SHA, expected SHA, expected bytes, canonical path, size, birth time,
   change time, or modification time changes invalidate the receipt.
4. Same-size content mutation misses because the change/modify fingerprint
   changes, then fails or refreshes according to the new content checksum.
5. Atomic inode replacement misses even when size and modification time are
   preserved.
6. Full mode hashes despite a valid receipt and refreshes
   `full_verified_at` without changing the stable binding or receipt-set digest.
7. Checksum failure publishes no new receipt and cannot be reported as success.
8. Concurrent refreshes use unique temporary files and publish only valid whole
   receipts; no process reads partial JSON.
9. Artifact mutation during a full hash triggers the bounded retry and then
   fails if instability continues.
10. Dry-run hit and miss behavior performs no filesystem mutation, including no
    receipt-directory creation or timestamp refresh.
11. Unsafe receipt symlinks, hard links, owners, modes, and parent directories
    fail closed; safe malformed receipts fall back to full verification.
12. Repeated references in one command do not duplicate hashes or counters and
    detect a changed fingerprint before reuse.
13. Downloads, completed partial files, and final rename always use full hashes
    and produce receipts bound to final paths.
14. Effective-mode derivation and hit/miss/full summary counts cover all-cached,
    all-full, and mixed runs.
15. Receipt-set canonicalization is independent of manifest traversal order and
    `full_verified_at` but changes for any stable binding field.
16. Managed identity schema, endpoint matching, result schema v1/v2
    compatibility, provenance generation, and generated-report drift checks.
17. Existing runtime/build/fixture/result verification remains fresh and is not
    accidentally routed through the model-artifact cache.

Tests use small temporary fixtures and a replaceable hash helper; lightweight CI
must never download or hash the real model set.

## Documentation updates

Implementation updates the root README, CLI help, model setup notes,
reproducibility guidance, security limitations, and contributor test guidance.
Examples show that cached mode is the normal fast path and that full mode is the
explicit audit path:

```sh
./bin/metal-llm serve qwen3.8-flash-next
./bin/metal-llm serve qwen3.8-flash-next --artifact-check full
```

The docs distinguish model-artifact verification receipts from runtime build
receipts and from the managed-process lease.

## Acceptance criteria

- A warm cached invocation does not read GGUF bodies and reports all hits.
- Any bound metadata change prevents a cache hit.
- Forced full verification reads every required artifact and leaves valid
  receipts for the next cached invocation.
- Downloads and replacements never bypass a fresh full SHA-256.
- Setup, serve, and both benchmark modes share one verifier and one CLI meaning.
- Dry-runs make no changes on either hit or miss.
- Managed identity and new result provenance identify requested/effective mode
  and the stable receipt set.
- Existing tracked results and reports remain verifiable without invented
  history.
- The full lightweight repository suite passes without model downloads.
