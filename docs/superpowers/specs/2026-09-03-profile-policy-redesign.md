# Profile policy redesign and dynamic MTP

- Status: Approved design; awaiting implementation plan
- Date: 2026-09-03

## Context

The initial repository couples vision capability to named profiles and uses
`auto` as hardware-manifest indirection. That makes the preset list harder to
understand and does not implement the measured need to use MTP at short context
but conventional decoding at long context.

The replacement contract separates three concerns:

1. A preset selects a runtime, context allocation, and MTP policy.
2. Vision is an independent option that defaults on.
3. A normalized effective configuration is the single input to setup, serving,
   managed-process identity, benchmarking, and result provenance.

The change deliberately removes obsolete interfaces because the repository has
no external compatibility requirement yet.

## Goals

- Provide four precise presets: `fast`, `long`, `auto`, and `stable`.
- Make `auto` the default and select MTP once per request from the effective
  post-multimodal prompt length.
- Provide `custom` with explicit runtime, MTP policy, and context controls.
- Make vision independently selectable for every preset and custom run.
- Keep one target model, one optional vision projector, and one optional MTP
  head loaded in a single server process.
- Make the selected per-request route observable and benchmarkable.
- Preserve immutable runtime, artifact, build, process, and result provenance.
- Validate the complete 262,144-token `auto` configuration on the Apple M5 Max
  with 128 GiB unified memory before recommending it as ready.

## Non-goals

- No CPU-only or Metal on/off public option.
- No two-server router or second full-model process.
- No user-configurable dynamic threshold in the initial interface.
- No silent context reduction, MTP fallback, or profile substitution.
- No claim that MTP and conventional decoding are behaviorally equivalent.

## Public CLI contract

Serving uses this grammar:

```text
metal-llm serve MODEL
  [--profile fast|long|auto|stable|custom]
  [--vision on|off]
  [--runtime tuned|upstream --mtp on|off|dynamic --context TOKENS]
  [--dry-run]
  [-- EXTRA_LLAMA_ARGS]
```

Omitting `--profile` selects `auto`. Omitting `--vision` selects `on`.
`--runtime`, `--mtp`, and `--context` are valid only with `--profile custom`,
and all three are required for custom. Named profiles reject those controls so
their names always describe reproducible configurations.

`--runtime upstream` is compatible only with `--mtp off`. The `on` and
`dynamic` policies require `--runtime tuned`. Context must be a positive integer
no larger than the model's declared maximum, initially 262,144 tokens.

The existing bind address, port, parallel-slot, API-key, dry-run, and safe
passthrough behavior remains. Passthrough continues to reject arguments that
could change managed model, runtime, artifact, context, MTP, vision, batching,
or offload identity after validation.

## Presets

All context values use binary token counts: 32K is 32,768 and 256K is 262,144.

| Profile | Runtime | Context | MTP policy | Vision default | Positioning |
| --- | --- | ---: | --- | --- | --- |
| `fast` | `tuned` | 32,768 | `on` | `on` | Short-request preset |
| `long` | `tuned` | 262,144 | `off` | `on` | Long-context preset |
| `auto` | `tuned` | 262,144 | `dynamic` | `on` | Recommended default after acceptance |
| `stable` | `upstream` | 32,768 | `off` | `on` | Reference only; not recommended |

Documentation, including the root README, must show the exact custom equivalent
of every preset:

```sh
# fast
--profile custom --runtime tuned --mtp on --context 32768 --vision on

# long
--profile custom --runtime tuned --mtp off --context 262144 --vision on

# auto
--profile custom --runtime tuned --mtp dynamic --context 262144 --vision on

# stable
--profile custom --runtime upstream --mtp off --context 32768 --vision on
```

Appending `--vision off` is the exact vision-disabled variant of any row.

## Removed and changed interfaces

- Remove the standalone `vision` profile.
- Do not add a `hybrid` profile; the dynamic preset is named `auto`.
- Replace the old hardware-manifest meaning of `auto` with the dynamic preset.
- Remove `METAL_LLM_CONTEXT`; context changes require `custom`.
- Remove hardware-level `recommended_profile` selection. The model manifest
  declares `auto` as its default profile.
- Do not add `--metal` or a CPU-only named profile.
- Reject removed options and profile names with direct migration guidance.

## Manifest and resolver architecture

The model manifest separates capabilities from presets:

- Runtime aliases map `tuned` and `upstream` to immutable runtime manifest IDs.
- One model-level vision capability declares the projector artifact, image token
  floor, and default enabled state.
- One model-level MTP capability declares the sidecar artifact, speculative type,
  draft-token limit, draft offload settings, and dynamic threshold.
- Named profiles contain only their stable ID, runtime alias, context, MTP
  policy, and recommendation/status metadata.
- The model declares `default_profile: "auto"` and `max_context: 262144`.

A single resolver produces normalized JSON for both named and custom inputs. It
contains the requested profile, runtime alias and resolved runtime ID, context,
vision state and artifacts, MTP policy and artifacts, dynamic threshold when
applicable, and all fixed inference flags. Serve, bench, setup, managed identity,
and dry-run output consume this object rather than resolving profiles separately.

Setup provisions both immutable runtimes and every artifact reachable from the
model capabilities. A custom configuration therefore never requires an
untracked build variant.

## Native dynamic-MTP implementation

As of upstream llama.cpp commit
`d230ddd763ffe27781c7ffd237ea78b639b36b6d`, request-level speculative
parameter adjustment remains disabled in `tools/server/server-schema.cpp`.
Dynamic selection therefore ships as an additional versioned patch against the
pinned tuned runtime, with an updated tested revision and tree hash.

The patched server accepts an internal startup option equivalent to
`--spec-draft-max-prompt-tokens 32768`. It still initializes and retains the MTP
head once. After chat templating and multimodal tokenization produce the server
task's effective token sequence, each slot records whether speculative decoding
is enabled for that task:

- effective prompt tokens less than or equal to 32,768: MTP enabled;
- effective prompt tokens greater than 32,768: MTP disabled.

The flag is fixed until that response completes. Slot reuse resets it before the
next task. Concurrent slots may choose different routes. Disabled slots never
begin, draft, checkpoint, restore, or collect acceptance statistics from the MTP
context. Enabled slots retain existing behavior. The target context, projector,
and MTP head remain in the same process, and the managed full-model lease remains
the one-process safety boundary.

`fast` starts the tuned server with MTP unconditionally enabled. `long` does not
load the MTP head. `auto` and custom `dynamic` load it and pass the threshold.
Custom `on` and `off` behave like the corresponding fixed modes.

## Vision behavior

Vision defaults on independently of the selected profile. When enabled, the
resolver supplies the verified projector and image-token floor. When disabled,
the projector is not loaded and multimodal requests fail clearly.

Dynamic routing uses the effective prompt length after image expansion, not the
text-only request length. The vision state and projector identity remain part of
the managed-server record and result provenance.

## Observability and API compatibility

The server adds route fields to the existing timing metadata in final
non-streaming responses and terminal streaming events:

```json
{
  "speculative": true,
  "speculative_policy": "dynamic",
  "effective_prompt_tokens": 24172,
  "speculative_threshold": 32768
}
```

Fixed policies report `on` or `off`; an inapplicable threshold is `null`. Server
logs record the same decision without request content or credentials. These are
additive response fields, so OpenAI-compatible clients may ignore them.

Managed-server identity records the configured policy and threshold. It does not
pretend that dynamic MTP has one server-wide on/off value. Endpoint benchmarks
verify the managed identity and record the route reported for each request.

## Benchmark and result changes

Benchmarks use the same normalized resolver as serve. New result provenance
records requested/resolved profile, runtime alias and immutable runtime identity,
context capacity, vision state, configured MTP policy, actual per-request route,
effective prompt length, and threshold. Imported historical data remains
explicitly distinguishable and is not rewritten with invented profile metadata.

Boundary correctness tests use effective lengths 32,767, 32,768, and 32,769.
Multimodal tests include requests whose text-only length is below the threshold
but whose expanded prompt crosses it. Streaming, non-streaming, structured
output, tool calling, ordinary text, and vision cover both routing sides. Slot
reuse and simultaneous short/long requests verify that decisions are per request
and reset correctly.

Performance acceptance repeats near-boundary measurements and reports means and
sample standard deviations. Output hashes and divergences are preserved; a
throughput win does not imply behavioral equivalence.

## Validation and failure behavior

- Invalid profile, runtime, MTP policy, vision value, or context fails before
  checking artifacts or launching a process.
- Custom missing any required policy option fails with the complete expected
  syntax.
- Upstream plus MTP `on` or `dynamic` fails as an unsupported combination.
- Requests over the configured context fail rather than changing policy.
- Missing or stale tuned patches, receipts, executables, MTP/projector artifacts,
  or managed identity fail under the existing strict verification rules.
- Dynamic-route metadata must agree with effective prompt length and configured
  threshold before benchmark publication.
- Dry-run prints the normalized configuration and exact redacted command without
  writing state.

## Acceptance and recommendation gate

The implementation is not described as the recommended ready-to-run default
until a local integration run on the recorded Apple M5 Max 128 GiB machine
proves all of the following:

1. Target weights, vision projector, MTP head, and a 262,144-token server context
   load together without allocation failure.
2. Text and expanded multimodal prompts select the correct side of the threshold.
3. The decision remains fixed for streaming and non-streaming responses and
   resets on slot reuse.
4. Structured output, tool calls, ordinary text, and vision complete correctly
   on both routes.
5. Concurrent slots can use opposite routes without cross-contamination.
6. No second full-model process is created.
7. Repeated boundary performance supports 32,768 as the default threshold.

If the complete 256K configuration does not fit, the command fails honestly and
the measured memory/cache findings return for a design decision. It must not
silently reduce context, disable vision or MTP, or promote `auto` prematurely.

## Documentation

Update the root README, model guide, hardware guide, dynamic-MTP ADR, profile
help, examples, troubleshooting, benchmark methodology, schemas, and contributor
templates. The README profile table must include each preset's exact custom
equivalent and clearly label `stable` as upstream reference-only and not
recommended.

