# Troubleshooting Qwen3.8-Flash-Next

## Prompt-batch decode fails with result `-3`

Stop every other full-model process, then retry. This failure was reproduced
when `llama-bench` ran beside an active server and disappeared after the server
stopped. One loaded target is the supported configuration. `metal-llm bench`
checks the configured lab port before starting `--mode local`. Use `--mode
endpoint` for API checks against the already running server; the modes never run
together.

## Structured JSON is empty or clipped

Reasoning tokens count against `max_tokens`. In the recorded check, 64 tokens
were consumed before visible structured content; 256 tokens passed. Increase the
output budget or disable reasoning through a supported request/template control.

## A long-context retrieval returns only part of the key

Separate retrieval from visible-output budget. At approximately 96K, the model
identified `VIOLET-483027`, but a 96-token cap exposed only `VIOLET-483`; a cached
retry with 160 returned the complete key. The recorded 23.80 tok/s run used MTP.

## MTP becomes slower or output changes

MTP was faster at short context and slower at long context on the tested machine.
Use the `long` no-MTP profile for large documents. The practical gray zone is
approximately 29–30K effective tokens, but request route, image expansion, cache
state, and residency can move the observed boundary. Output can also diverge
between and within modes despite greedy settings; do not diagnose divergence as
proof of prompt corruption without a route-matched reproduction.

## Memory pressure or model allocation failure

Do not raise `iogpu.wired_limit_mb` as a first response; the recorded 250K
synthetic allocation completed with its automatic value of `0`. Stop competing
model processes, verify the selected artifact/profile, and compare current
memory pressure with the tested hardware notes. The project never changes
macOS memory or power settings automatically.

## Vision request is treated as text-only

Use the `vision` profile and confirm its dry-run command includes the pinned F16
projector and `--image-min-tokens 1024`. The recorded six-case suite passed, but
it is local integration evidence rather than a lightweight CI test.
