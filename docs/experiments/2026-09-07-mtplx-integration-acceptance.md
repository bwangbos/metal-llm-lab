# Managed MTPLX integration acceptance

Status: **offline integration accepted; live acceptance pending**. No live test
of the new managed launcher has been performed.
The existing independently launched benchmark instance must not be interrupted
or used for these checks without its owner's release.

## Offline gate

Initial integration commit `34a2475` passed `zsh tests/run.sh`, including all
21 then-current MTPLX tests and the original regression suites. Independent
review subsequently identified startup credential logging, incomplete result
validation and empty-partial resume defects, resolved below.

Fix commit `25f3489` addressed all three findings, and independent scoped
re-review approved them. A fresh `zsh tests/run.sh` on that revision exited 0:
all original checks, 23 MTPLX tests and the new malformed-result report checks
passed. Final independent whole-branch review of `7b5c344..25f3489` approved the
implementation/offline scope with no remaining findings. None of these tests
loaded the real model or contacted the independent benchmark instance.

An actual isolated runtime-only install also passed on the M5 Max 128 GiB host:
45 locked packages installed with wheel hash verification; dependency checks
reported no broken requirements; 7,297 installed files were verified. The
receipt inventories 46 distributions including bootstrap pip. Approximate disk
use including managed wheel cache: 534 MB. Lock SHA256:
`88c33df0e5a6171aa503713d8b1af04b0801c39560cb2db3f5079f64a22157b0`.
This exercised the adapter's runtime installation function only, with Python
3.12, not full model setup or inference. No existing evaluation environment was
modified. No model weights were downloaded, imported, or loaded.

Setup/serve/endpoint-benchmark dry-runs passed without a managed model snapshot.
A hardware-aware serving preview selected the 104 GiB budget on the actual
M5 Max 128 GiB host; restricted hardware inspection correctly fell back to
unqualified/upstream-default reporting. Neither preview launched the server.

The offline gate is closed for this revision. Model download/import tests used
small isolated fixtures; the real dependency installation used a separate
managed environment. Re-run applicable tests and review if implementation changes
before live acceptance. Main-branch integration and publication remain deferred.

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
| Short context | Record exact prompt/output counts, wall time, public timing fields, process/runtime memory measurements, host pressure and swap, and native evidence of the actual speculative path; if the runtime exposes no path metric, record it as unavailable rather than inferring a path |
| Near-max context | Leave output headroom; require exact input counts and successful completion; collect process/runtime memory measurements, host pressure and swap, and native evidence of the actual speculative path; if the runtime exposes no path metric, record it as unavailable rather than inferring a path |
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
