# ADR 0002: Dynamic MTP direction

- Status: Implemented and accepted on Apple M5 Max 128 GiB
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

## Acceptance evidence

- Correctness comparisons for deterministic text, structured output, tool calls,
  and every vision fixture on both sides of the threshold.
- Performance repeats that report means and sample standard deviations near the
  boundary, plus single-run calibration away from it.
- Tests that gating uses post-multimodal effective tokens, honors configuration,
  remains fixed for each response, and cannot start a second target server.
- Output hashes and divergence reporting where outputs are available; no claim
  that MTP is behavior-neutral without evidence.

The exact Apple M5 Max 128 GiB manifest passed a 262,144-token allocation with
the target, projector, and MTP sidecar loaded. The 19-row integration evidence
passed boundary, multimodal, streaming, slot-reuse, concurrency, correctness,
and one-process checks. The canonical performance run retained all 105 samples:
three policies, seven effective lengths, and five measured repetitions after one
warm-up per cell. Every dynamic mean was within the predeclared 5% tolerance of
the corresponding fixed route. Dynamic 32,767 was +1.2630904893804473% versus
fixed-on; dynamic 32,769 was +4.909370120449208% versus fixed-off, a narrow
0.090629879550792-point margin. The `auto` profile is therefore promoted to
`recommended` for the exact accepted configuration.

Recovery history is part of the decision record. A host power loss removed an
earlier non-durable 83/105 scratch run, so none of those values were reconstructed
or used. During recovery, a 35-row fixed-on attempt exposed an invalid
policy-agnostic loaded-artifact assertion and a fail-fast propagation defect; it
was preserved as diagnostics and invalidated before the collector identity
changed. A slowdown previously observed for dynamic 32,767 was noncanonical and
did not reproduce in the fresh 105-row run. The raw result contains only the
fresh canonical rows bound to the corrected collector identity.

The machine-specific raw result and derived summary are documented in the
[acceptance record](../experiments/2026-09-03-dynamic-mtp-acceptance.md). The
narrow 32,769 margin and possible run-to-run variance remain reasons to repeat
the matrix when the runtime, model artifacts, OS, or power conditions change.
