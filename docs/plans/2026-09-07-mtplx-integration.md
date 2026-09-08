# MTPLX first-class integration

## Global constraints

Preserve the existing qwen3.8-flash-next interface and profiles. Add
qwen3.8-flash-next-mtplx with default/custom profiles and common setup,
serve and API bench workflows. Do not touch any running model instance,
send inference, clear caches, change global settings, or publish before
live acceptance. Keep downloads, environments and private paths out of Git.

## Task 1: Runtime integration

Implement versioned model/runtime manifests and runtime adapters for setup,
verification, launch, identity and benchmark capabilities. Use MTPLX 2.11.2
and Youssofal/Qwen3.8-Flash-Next-MTPLX-Optimized-Speed revision
6bc2f6e8426ccb4af73c81bc56ba7718afc92cc6. Pin a fully hashed dependency lock
including llguidance. Automate resumable verified snapshot downloads into
managed .lab storage and explicit --import-from directory setup that verifies
and copies without modifying its source. Preserve cached/full artifact checks.

The default profile uses context 262144, MTP depth 3, serial serving, vision
on. Custom requires --mtp on|off and --context; reject dynamic and --runtime
for MTPLX. Support --vision on|off and dry-run. Use existing host/port/key
environment conventions; reject concurrency other than one. API model ID is
the package ID. Disable agent rewrites (native prompt path), telemetry and
SSD session caching; retain evaluated reasoning/sampling defaults and default
fan mode. 104 GiB memory default only on M5 Max 128 GiB; respect explicit
MTPLX_MEMORY_LIMIT_BYTES and otherwise upstream default with unqualified notice.
Dry-run reports effective configuration and hardware qualification.

Share managed lease protections. API benchmark suites support the new runtime
with full identity/settings/timing/native-path provenance. Reject llama-bench
local suites explicitly. Tests first: manifest validation, installation
integrity, cached invalidation, resume/import, argument rejection, dry-run,
identity, bench capabilities. Run original regression tests. No actual model
launch, large download, or live acceptance in this task.

## Task 2: Documentation and acceptance handoff

Document copy-paste setup/serve/bench for both packages, presets and custom
equivalents, memory/storage qualification, licenses, prompt behavior and
troubleshooting. Preserve and link existing portable evaluation/readouts.
Provide acceptance checklist covering text, streaming, tools, JSON, vision
on/off, MTP on/off, cancellation, API identity, native tool prompt token counts,
short/near-max context memory and actual speculative paths. Mark live acceptance
pending, retain existing model recommendation. No full fresh sweep or dynamic
MTPLX policy in this integration.
