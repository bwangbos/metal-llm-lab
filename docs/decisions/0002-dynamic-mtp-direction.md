# ADR 0002: Dynamic MTP direction

- Status: Implemented; pending hardware acceptance
- Date: 2026-09-03

## Context

Local measurements show a material MTP benefit for short requests and a no-MTP
benefit at long context, with a repeated gray zone around 29–30K effective tokens.
Multimodal expansion changes the effective token count, and output sometimes
diverged across decoding routes. Running separate full-model servers is not a
viable routing design on the tested 128 GB machine.

## Decision and implementation

The tuned runtime loads one target model, the vision projector, and the MTP head
once. Patch `0013-server-gate-mtp-by-effective-prompt.patch` is recorded at
tested revision `b814e84c45f00fb0d9f3283175acc1a24fa90b95` and tested tree
`4f3c051ed7ae4e856cb6d7d95f5c1af6984fc72d`. After template application and
multimodal tokenization, each request compares its effective prompt-token count
with the configured threshold, chooses speculative MTP or conventional decoding
once, and keeps that route fixed for the entire response.

For this model policy the threshold is fixed at 32,768: effective counts less
than or equal to 32,768 use MTP, and larger counts do not. The server resets the
decision on slot reuse and permits simultaneous slots to select opposite routes.
The attached-image interpolation near 33.6K was not promoted as a universal
claim; 32,844–33,868 remains only that workload's measured bracket.

Final non-streaming responses and terminal streaming events expose
`speculative`, `speculative_policy`, `effective_prompt_tokens`, and
`speculative_threshold` in timing metadata. Endpoint capture rejects evidence
that disagrees with the managed policy or changes route during a stream.

## Required evidence before acceptance

- Correctness comparisons for deterministic text, structured output, tool calls,
  and every vision fixture on both sides of the threshold.
- Performance repeats that report means and sample standard deviations near the
  boundary, plus single-run calibration away from it.
- Tests that gating uses post-multimodal effective tokens, honors configuration,
  remains fixed for each response, and cannot start a second target server.
- Output hashes and divergence reporting where outputs are available; no claim
  that MTP is behavior-neutral without evidence.

The launcher and runtime implementation are present, but `auto` remains
`pending-acceptance`. Promotion requires a complete opt-in integration run on
the exact Apple M5 Max 128 GiB manifest, including a successful 262,144-token
allocation with target, projector, and MTP sidecar loaded. Until that evidence is
reviewed, this ADR does not claim the configuration fits and does not recommend
`auto` as an accepted performance default.
