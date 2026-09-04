# Troubleshooting Qwen3.8-Flash-Next

## Prompt-batch decode fails with result `-3`

Stop every other full-model process, then retry. This failure was reproduced
when `llama-bench` ran beside an active server and disappeared after the server
stopped. One loaded target is the supported configuration. Normal harness
serving and local benchmarks share a managed lease across checkouts that use the
same per-user/session `TMPDIR`, and `metal-llm bench --mode local` also checks the
configured lab endpoint. A stale lease is recovered only after its PID/start
identity is no longer live; the harness never kills that process. Processes
started outside `metal-llm` are not represented by the lease and must be stopped
manually. Use `--mode endpoint` for API checks against a live server started by
`metal-llm serve`; the recorded server identity must match the requested model,
profile, verified build, artifacts, host, and port.

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
Use the `long` no-MTP preset for large documents. Dynamic mode applies the fixed
policy boundary after template and image expansion: 32,768 effective tokens or
fewer select MTP and larger requests do not. Output can diverge between and
within modes despite greedy settings; do not diagnose divergence as proof of
prompt corruption without a route-matched reproduction.

## Memory pressure or model allocation failure

Do not raise `iogpu.wired_limit_mb` as a first response; the recorded 250K
synthetic allocation completed with its automatic value of `0`, but that is not
evidence that the complete 262,144-token `auto` server fits. Stop competing model
processes, confirm the machine exactly matches the M5 Max 128 GiB manifest, and
verify the tuned receipt and target, projector, and MTP artifacts. A failure must
remain visible: do not silently lower context, disable vision, or disable MTP.
The project never changes macOS memory or power settings automatically.

## A custom profile is rejected

Custom mode requires `--runtime`, `--mtp`, and `--context` together. Valid
runtime values are `tuned` and `upstream`; valid policies are `on`, `off`, and
`dynamic`. The upstream runtime supports only `off`, and context must be a
positive integer no larger than 262,144. Named presets reject those three
overrides so the preset always resolves to one reproducible configuration.

The standalone vision preset and the context-size environment override were
removed. Select `fast`, `long`, `auto`, or `stable`, use `--vision on|off`
independently, and use a fully specified custom profile when changing context.

## Route metadata does not match the request

For dynamic mode, final `timings` metadata must report policy `dynamic`,
threshold 32,768, an integer effective prompt count, and `speculative=true`
exactly when that count is at or below the threshold. All timing-bearing events
in a stream must keep the same route. If any field is absent, changes during the
response, or contradicts the count, preserve the sanitized response and server
log but do not publish or interpret it as acceptance evidence. Recheck the
managed server identity, verified runtime revision/tree, and whether an
unrelated endpoint owns the configured port.

## Vision request is treated as text-only

Vision defaults on. Confirm the selected preset was not given `--vision off` and
that its dry-run command includes the pinned F16 projector and
`--image-min-tokens 1024`. The recorded six-case suite passed, but it is local
integration evidence rather than a lightweight CI test. Harness vision fixtures
must be Git-tracked regular non-symlink PNG/JPEG files beneath
`benchmarks/fixtures/`; path confinement, MIME, and checksum are checked before
the fixture is sent.
