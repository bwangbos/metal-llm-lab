# ADR 0002: Dynamic MTP direction

- Status: Proposed; not implemented
- Date: 2026-09-03

## Context

Local measurements show a material MTP benefit for short requests and a no-MTP
benefit at long context, with a repeated gray zone around 29–30K effective tokens.
Multimodal expansion changes the effective token count, and output sometimes
diverged across decoding routes. Running separate full-model servers is not a
viable routing design on the tested 128 GB machine.

## Direction

A future implementation should load one target model, the vision projector, and
the MTP head once. After template application and multimodal tokenization, each
request should compare its effective prompt-token count with a configurable,
measurement-backed threshold. It should then choose speculative MTP decoding or
conventional decoding once and keep that choice fixed for the entire response.
It must not switch decoding modes mid-response.

The default threshold must be conservative about the measured gray zone and may
vary by tested model/profile. The attached-image interpolation near 33.6K must
not be promoted as a universal default; 32,844–33,868 is only that workload's
measured bracket.

## Required evidence before acceptance

- Correctness comparisons for deterministic text, structured output, tool calls,
  and every vision fixture on both sides of the threshold.
- Performance repeats that report means and sample standard deviations near the
  boundary, plus single-run calibration away from it.
- Tests that gating uses post-multimodal effective tokens, honors configuration,
  remains fixed for each response, and cannot start a second target server.
- Output hashes and divergence reporting where outputs are available; no claim
  that MTP is behavior-neutral without evidence.

No runtime, launcher, or request router in this repository currently implements
this decision.
