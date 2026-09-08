# MTPLX fixed-M4 memory-admission experiment

Status: 104GiB prevented fallback in the sequence and a near-full repeat.
User authorized raising the isolated candidate's allocation
budget until the near-full-context optimized verification lane is admitted,
subject to host memory safety.

## Hypothesis and controls

The prior 96GiB run fell back at 261,547 input tokens: approximately 94.0 GB
live plus 7.5 GB promotion exceeded the 100.0 GB admission line. The pinned
runtime's `generation.py::_qwen4_fixed_m4_lane_fits` uses 97% of the applied
Metal allocation budget after attempting allocator and session-cache reclaim.

Begin at 104GiB (111,669,149,696 bytes), then inspect evidence before any further
increase. Keep runtime 2.11.2, model revision, vision enabled, turbo profile,
MTP depth 3, context 262144, Apple-managed fans and existing wired limit unchanged.
Only set `MTPLX_MEMORY_LIMIT_BYTES` for the candidate process; no global changes.
The budget also influences cache sizing, so admission must be measured rather
than inferred from adding 8GiB to the previous run.

## Procedure

- Use the same synthetic key-retrieval context sequence: raw-token targets
  32700, 65500, 131000, 261500; capture actual template-token counts and cache use.
- Confirm applied memory budget from `/health`, not just launch environment.
- Capture request-level `fixed_m4_admission` and `compiled_verify` telemetry.
  A correct answer alone does not prove the optimized lane ran.
- Retain raw requests, SSE events, output, logs and health under ignored
  `.lab/mtplx-evaluation/`; monitor host pressure and swap every five seconds.
- Stop the request client on critical host pressure, reported free percentage
  below 8%, swap use above 128MiB, or a 20-minute sequence deadline. Runtime
  guards remain enabled. Inspect and stop only the candidate if cleanup needed.
- These are path-admission tests with short outputs, not retained speed or
  sustained stability benchmarks. Do not claim the smallest viable budget
  without testing smaller intervening budgets.

Initial host check: AC power, zero swap, no other model server observed.
Unrelated Docker processes remain present and untouched.

Baseline evidence and pins: [initial evaluation](2026-09-06-mtplx-evaluation.md).

## Measured results

Applied budget was confirmed as 111,669,149,696 bytes (104GiB), giving a
108,319,075,205-byte admission threshold. The wired limit remained
89,480,048,859 bytes, unchanged from the baseline.

| Input tokens | Cached tokens | Compiled verify calls / total | Fallback calls | Demotions |
| ---: | ---: | ---: | ---: | ---: |
| 32,737 | 0 | 18 / 18 | 0 | 0 |
| 65,542 | 32,512 | 18 / 18 | 0 | 0 |
| 131,047 | 65,280 | 17 / 17 | 0 | 0 |
| 261,547 | 130,816 | 18 / 18 | 0 | 0 |
| 261,547 (repeat) | 261,546 | 18 / 18 | 0 | 0 |

All five requests returned the exact key with 67 output tokens and `stop`.
All request admission receipts show `engaged: true`, `reason: admitted`.
Near-full promotion was 7,461,217,536 bytes. `live_bytes_before` in the receipt
is captured before reclaim, so adding it to promotion can exceed the threshold
even when post-reclaim admission succeeds; it is not a final-live measurement.

55 host telemetry samples across the two runs showed pressure level 1 (normal)
and zero swap. Lowest reported free percentage was 20% in the sequence, 14% on
repeat. These are sampled observations, not proof against future memory spikes.

No higher budget was needed or tested. 104GiB is a demonstrated working budget
for this fixture, not a proven minimum or a universal no-fallback guarantee.

### Speed caveat

The first near-full compiled request reported 40.74 decode tok/s and the repeat
52.64 tok/s, versus 62.09 tok/s in the earlier 96GiB eager-path observation.
Only 67 output tokens were generated; compiler traces, cache state, and run
history differ. The experiment proves path admission, **not a speed improvement**.
Do not call eager verification categorically slower based on its name.

### Retained local evidence

Under `.lab/mtplx-evaluation/`:

- `launch-104gib-2026-09-07.log`
- `budget-104gib-20260907-094600/`: health before/after, metrics, telemetry,
  client output; sequence completed with exit 0 and no safety stop.
- `budget-104gib-repeat-20260907-095038/`: same evidence for repeat; exit 0.
- Capacity fixture request/response directories are identified in each client log.
- `test_memory_budget.py`: monitoring harness; existing `check_capacity.py`
  generated the requests without modifying runtime source.

The override was supplied only to the test process. No production profile,
global setting, wired-limit override, fan setting, model or runtime was changed.
Server stopped after qualification (session exit 143); artifacts retained, not pushed.
