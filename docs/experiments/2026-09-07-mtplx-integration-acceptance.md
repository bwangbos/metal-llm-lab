# Managed MTPLX integration acceptance

Status: **pending**. No live test of the new managed launcher has been performed.
The existing independently launched benchmark instance must not be interrupted
or used for these checks without its owner's release.

## Offline gate

Record the integration commit, full regression command and outcome, targeted
adapter tests and independent code review. Confirm install/download tests use
small isolated fixtures and do not mutate the evaluation environment.

## Live gate (explicitly deferred)

After the existing instance is released, verify free memory and normal pressure
before loading the model. Use the committed integration and pinned artifacts;
never silently update packages while qualifying. Record OS, hardware, power,
dependency lock, model manifest, artifact verification receipts and launch
configuration, including the prompt policy and memory budget.

| Check | Required evidence |
| --- | --- |
| Startup and ownership | Matching managed lease, endpoint and `/v1/models` ID; second managed launch refuses without killing the first |
| Text and streaming | Successful complete response and ordered streaming termination; retain request/response and timings |
| Native tool prompts | Minimal no-tools and one-tool requests with exact schemas; retain prompt token counts and runtime prompt-mode evidence; no injected agent contract |
| Tool calling | Correct declared function name and parseable arguments; complete a tool-result continuation |
| Structured JSON | A constrained schema response validates; no missing llguidance error |
| Vision on/off | Actual tracked image fixture succeeds when on; image input is rejected clearly when off; text still works |
| MTP on/off | Separate owned launches and runtime evidence of configured MTP versus AR; do not infer execution from CLI flags alone |
| Cancellation | Disconnect a streaming client, then complete a fresh request without restarting |
| Short context | Record exact prompt/output counts, wall time, public timing fields and native speculative-path metrics |
| Near-max context | Leave output headroom; require exact input counts and successful completion; collect pressure, swap and actual verification path |
| Cleanup | Stop only the test-owned process and verify lease recovery; preserve failed samples and logs |

For the capacity check, use the earlier 261,888-token input with 128 output
tokens as the target only after confirming tokenizer identity and endpoint
support. Report tokenization/count mismatches as failures, not approximate
success. Do not clear caches belonging to another workload. Record reuse when
present; do not call a cached prompt a cold-prefill measurement.

Observe memory pressure and swap during tests; abort the test-owned workload on
critical pressure or sustained unexpected swapping. Do not change macOS limits
or kill unrelated applications. Do not run an entire new performance sweep as
part of this gate.

## Release decision

Only mark the managed integration accepted after all applicable checks pass and
their evidence is recorded. Keep unavailable evidence explicitly pending.
Acceptance makes the package an available alternative, not the recommended
replacement. Historical experimental smoke checks and context curves remain
separate evidence with their original configuration and limitations.
