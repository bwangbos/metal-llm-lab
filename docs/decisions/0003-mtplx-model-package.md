# 0003 — Separate model packages with shared commands

Date: 2026-09-07. Decision approved; offline integration accepted; live acceptance pending.

## Decision

Keep `qwen3.8-flash-next` for the existing GGUF/llama.cpp setup and add
`qwen3.8-flash-next-mtplx` for the evaluated Optimized Speed/MTPLX setup.
Users select the complete package with the model ID and use the same top-level
setup, serve and API benchmark commands.

Profiles are package-specific. The original auto/fast/long/stable/custom
contract remains unchanged. MTPLX starts with default/custom; its default uses
the evaluated 256K, MTP depth-3, serial configuration. Vision is independently
on by default. The original 32K dynamic-MTP cutoff is not copied into MTPLX.

## Why

The packages differ in quantized weights, storage behavior, runtime and
speculative execution paths. A backend switch on one model ID would imply
interchangeable checkpoints and could hide the quantization difference in
comparisons. Identical profile labels would also suggest an unimplemented,
unqualified dynamic policy.

Share user-facing workflow and safety checks, but preserve truthful runtime
capabilities and provenance. A Python environment is not a llama.cpp source
revision; an MLX API test is not a local llama-bench run. Unsupported controls
must fail clearly instead of being ignored.

## Consequences

- Existing automation keeps its original model ID and profile behavior.
- MTPLX setup owns a verified snapshot and isolated environment, independently
  of exploratory worktrees. Local import copies, never destructively relocates.
- The lab's MIT license does not cover downloaded runtime/model licenses.
- Native tool prompting excludes MTPLX's extra agent contract, but still uses
  required chat-template and tool-schema tokens.
- The 104 GiB process budget is hardware-qualified, not a global Mac default.
- Availability is separate from recommendation. The original accepted setup
  remains recommended until representative quality and performance evidence
  supports a change.

## Follow-up boundary

No dynamic MTPLX policy, automatic backend selection, quant/runtime upgrade,
system-wide memory tuning or fresh full sweep is included. Live acceptance
waits for the existing benchmark instance to be released; it is never stopped
automatically by this integration.

After offline verification and review, the owner authorized source publication
on the main branch before live acceptance. Publish the pending qualification
status explicitly and retain the original recommendation. The normal checkout
must remain self-contained; preserving the old evaluation worktree for an
ongoing benchmark does not make it a dependency of the published integration.

See the [package guide](../models/qwen3.8-flash-next-mtplx.md) and
[acceptance record](../experiments/2026-09-07-mtplx-integration-acceptance.md).
