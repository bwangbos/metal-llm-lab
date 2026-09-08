# MTPLX full-model evaluation

Status: September 7 initial smoke/cache/capacity checks passed, followed by a
[completed synthetic context comparison](2026-09-07-mtplx-context-sweep.md).
Sustained stability and representative quality qualification remain open.

## Approved scope

Execute the September 6 setup research recommendation: preserve the working
llama.cpp baseline; evaluate full-model MTPLX first for speed, then a
higher-expert-precision quant for quality. MLX Serve remains a conditional
second runtime. Do not promote a candidate merely because upstream reports
better throughput.

## Constraints

- Isolated worktree; no main-branch changes or publishing without authorization.
- No global packages, fan-control installation, telemetry enablement, wired-memory
  setting changes, or stopping unrelated applications.
- Pin releases, model revisions, dependency versions and artifact hashes.
- Verify downloads before inference. Keep weights, environments and raw logs in
  ignored `.lab/mtplx-evaluation/`.
- One inference server at a time; localhost only; vision enabled by default.
- Distinguish end-to-end setup comparisons (different quants) from within-runtime
  MTP on/off comparisons. Preserve all measurements, including failed runs.

## Sequence and gates

1. Freeze baseline and inventory hardware, free disk, power, competing workloads.
2. Download MTPLX 2.11.2 and Optimized Speed at the pinned revision; verify all
   files and inspect runtime side effects before launching.
3. Validate text, template/reasoning, tool/schema and actual image requests.
4. Run matched cold and cached-context tests: near-zero, 32K and 32K increments
   to 261,888 input tokens; separately isolate MTP within each runtime. Add denser
   points near observed crossovers. Alternate order; warm up and retain at least
   five repetitions. Match tokenized inputs and generation settings or disclose
   any differences. Report TTFT, prefill, generation, wall time and memory.
5. Compare representative task quality and successful-task latency before
   promoting any setup. Then evaluate higher-expert-precision GGUF and, if
   necessary, MLX Serve as separate challengers.

## Pinned candidate

- Runtime: [MTPLX v2.11.2](https://github.com/youssofal/MTPLX/releases/tag/v2.11.2),
  released 2026-09-06 14:04:18 UTC.
- Release wheel: `mtplx-2.11.2-py3-none-any.whl`, 2,783,662 bytes.
- Published and locally verified SHA256:
  `55482748c91fcd1992e16a58426642f5f0e0655a004785014cdd6c2822171597`.
- Runtime license: Apache-2.0; preserve NOTICE and required attribution if
  distributing an integration. Evaluation is not redistribution.
- Model: [Youssofal/Qwen3.8-Flash-Next-MTPLX-Optimized-Speed](https://huggingface.co/Youssofal/Qwen3.8-Flash-Next-MTPLX-Optimized-Speed).
- Model revision: `6bc2f6e8426ccb4af73c81bc56ba7718afc92cc6`.
- Model license: Qwen Community License 1.0, retained from the pinned snapshot;
  not the repository's MIT license.
- Model files: 19 trunk shards, vision weights, MTP weights, external n-gram table,
  tokenizer/template/configuration files. Full experts retained.

## Baseline and preparation evidence

- Baseline repository commit: `7b5c3449d6f6d8523c5025d6b779c5e0dfa67b0d`.
- Existing measured results: [extended context readout](../../results/experiments/2026-09-06-extended-context-sweep/comparison.md).
- Host: Mac17,6 / M5 Max / 128GiB, AC power, approximately 908GiB disk free at
  preparation. Initial observation: a virtual machine occupies approximately
  23GiB RSS. User asked to pause/quit it before inference; not stopped by scripts.
- CLI-only installation in a local virtual environment avoids the app's global
  PATH/fan-control/onboarding changes. Dependency versions will be recorded.

## Recovery ledger

- Worktree `experiment/mtplx-evaluation` created with user approval.
- Release wheel checksum passed; model metadata with source hashes captured.
- Lightweight baseline validation: `zsh tests/run.sh`, exit 0, all checks PASS.
- Isolated installation completed: Python 3.12.14, MTPLX 2.11.2, MLX/MLX-Metal
  0.32.2, MLX-LM 0.31.3, Transformers 5.14.1. Full dependency inventory retained
  in ignored `dependencies.json`; no model import or inference validation yet.
- Pinned model download started with two workers, local cache, telemetry disabled
  and implicit credential use disabled. Full model verification remains pending.
- User confirmed the virtual machine belongs to another workstream and will
  signal when it can be shut down. **Do not load a model or run inference until
  that signal.** Continue preparation only; do not stop the VM.
- Launch audit: avoid app onboarding/start/tune fan workflows. Explicitly select
  Apple-managed fans, localhost, isolated config/log/cache paths; disable SSD
  session cache for cold tests. Process-local MLX memory caps are distinct from
  macOS system-wide wired-memory settings; preserve system settings.
- Runtime safety checks, full download verification and inference gates remain open.

## September 7 research refresh and authorized resume

The user authorized resuming evaluation after freeing the earlier Docker
workload. Do not stop unrelated applications. A fresh read-only check still
showed Docker/virtualization processes at a much smaller resident footprint;
recheck live memory pressure before any load rather than assuming an empty host.

- Release 2.11.2, wheel digest and model revision remain unchanged.
- Previous download process had ended; resumed the same snapshot with two
  workers, retaining partial-download metadata. Never run duplicate downloads.
- Fresh `zsh tests/run.sh`: exit 0, all checks passed.
- Begin with exact stock decoding and actual vision tests; no approximate
  typical-acceptance PR, raised memory limit, swap opt-in or fan override.
- Add first-line streaming, cancellation/retry and sustained memory checks for
  the open upstream issues before promotion. No measured quality winner yet.
- The public `serve` parser rejects `--dry-run --json`; an ignored local helper
  inspects the existing internal dry-run route without importing MLX. This is a
  launch audit, not a patched runtime or an inference result.
- Local download verification helper checks every metadata size, SHA-256 for
  LFS files and Git blob SHA-1 for small files before emitting a receipt.

Relevant upstream evidence: [stream buffering issue](https://github.com/youssofal/MTPLX/issues/468),
[memory follow-ups](https://github.com/youssofal/MTPLX/issues/456),
[exact experimental optimizations](https://github.com/youssofal/MTPLX/pull/475),
[approximate acceptance, excluded from baseline](https://github.com/youssofal/MTPLX/pull/478).

## September 7 initial execution

- Download completed; all 39 snapshot files passed recorded LFS SHA-256 or
  Git-blob verification, totaling 115,061,253,338 bytes.
- Sampled attention Q-projection tensor headers confirm 4-bit/group-32 packing
  (U32 weights with width 320, BF16 scales width 80 for hidden width 2560),
  consistent with configuration rather than the conflicting model card.
- First stock load succeeded; 262,144-token configured window, vision enabled,
  default 96GiB engine budget, Apple-managed fans, one serial request. This is
  startup acceptance, not a full-context allocation/performance acceptance.
- Exact-text and simple probability smoke responses passed. Structured JSON
  returned HTTP 400 because the optional server extra was missing: llguidance.
  This is a dependency failure, not evidence of a model reasoning failure.
- Added only `llguidance==1.8.0` to the isolated environment (wheel declares
  `llguidance>=1.7` in its server extra), then restarted only the candidate.
  Initial failed-run responses and launch log are preserved separately.

## September 7 initial qualification (not a performance benchmark)

Raw evidence below is local and ignored under `.lab/mtplx-evaluation/`.

- `smoke-20260907-091322/`: exact text, probability reasoning (5/33), constrained
  JSON schema, structured tool invocation and an actual image request passed.
  Vision identified the blue circle and orange square in the synthetic fixture;
  this does not establish broad image/video quality.
- `stream-cache-20260907-091447/`: both AR and MTP answered the probability
  correctly, but greedy text and reasoning were not identical. Server request
  logs confirm AR depth 0/zero verify calls versus MTP depth 3/30 verify calls.
  One correct pair is not proof of distributional parity or quality equivalence.
- The identical 3,552-token prompt reported 0 cached tokens on its first request
  and 3,552 on repeat. First streamed token fell from 3.357s to 0.113s; total
  request time from 4.975s to 1.862s. These are single smoke observations with
  short outputs, not retained benchmark samples or long-context cache claims.
- The tools-enabled final-answer-first-line `value` case produced 248 content
  chunks spanning 1.420–6.450s after dispatch. It did not reproduce issue #468
  in this request; that does not prove the upstream defect fixed.
- Stock released runtime only: no approximate acceptance PR or external runtime
  patch applied. Existing llama.cpp profiles remain unchanged.
- `capacity-20260907-091847/`: three client-disconnect/retry cycles succeeded;
  the server health counter confirmed three cancellations. A 32,737-token input
  retrieved the exact leading key with 67 output tokens and `stop` in 27.766s.
  This is an easy synthetic retrieval gate, not a general long-context evaluation.
- `provenance-20260907-092103.json` records dependencies after adding llguidance,
  OS and live health. System swap was zero at this observation. The runtime
  applied its default 96GiB process-local MLX memory limit; no macOS-wide limit
  or fan setting was changed.

### Retrieval capacity checkpoint

`capacity-20260907-092005/` preserves continuation requests and streamed results.
All returned the exact leading secret key with 67 completion tokens and `stop`.

| Actual input tokens | Reused prefix tokens | Request wall time | Result |
| ---: | ---: | ---: | --- |
| 32,737 | 0 | 27.766s | Pass (earlier capacity directory) |
| 65,542 | 32,512 | 32.521s | Pass |
| 131,047 | 65,280 | 63.942s | Pass |
| 261,547 | 130,816 | 132.468s | Pass |

These use highly repetitive synthetic text, a key at the beginning and short
outputs. They do not establish full-context reasoning quality, cold-prefill
speed, sustained decode performance, or superiority over llama.cpp. Vision was
enabled in the runtime, but these capacity requests were text-only.

Near-full prefill triggered allocator pressure/cache trimming within the default
96GiB process limit. The request nevertheless completed. Final provenance
`provenance-20260907-092456.json` reports zero system swap after the run; this is
not continuous swap monitoring or a long-running memory-leak clearance.
The fixed-M4 compiled verification lane declined near-full-context promotion
for memory headroom and used plain eager batched verification. MTP therefore
did not use the same optimized route at every context in these checks.

Initial qualification checkpoint is complete. A later user-requested
three-retained-sample context matrix matching the old sweep is documented
[separately](2026-09-07-mtplx-context-sweep.md); the originally proposed
five-retained-sample matrix was not run. Long-duration cancellation/cache churn, representative task
quality comparison, and higher-expert-precision challenger remain pending.
Do not promote the candidate or extrapolate smoke-request throughput into a
comparative benchmark. Test server stopped via SIGTERM (session exit 143);
downloaded model and environment retained for resumption.
