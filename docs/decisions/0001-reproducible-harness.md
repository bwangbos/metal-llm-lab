# ADR 0001: Use a reproducible harness instead of vendoring runtimes

**Status:** Accepted

## Context

The project needs repeatable Apple-Silicon LLM setup, serving, validation, and
benchmarking without committing large model artifacts, compiled products, or
third-party runtime trees. It must preserve enough provenance to reproduce
comparisons and support more than one model, machine, or runtime.

## Decision

Maintain a compact harness that tracks exact upstream revisions, versioned
patch series, model and runtime manifests, scripts, benchmark definitions, raw
results, and human-readable summaries. Keep reconstructable local state in
ignored directories. Treat experimental runtime changes as tested patches
against pinned revisions until a dedicated fork is warranted.

## Consequences

Setup can fetch, verify, patch, build, and smoke-test declared inputs while
benchmark records retain verified provenance and sanitized exact argument
arrays. Serving and local benchmarks accept only a strict build receipt tied to
the current runtime manifest, tested revision/tree, clean source checkout, and
both expected executable hashes. Source verification rejects hidden index flags,
checks raw tracked bytes with Git filters disabled plus executable modes against
the index, and does not support submodules. Serve passthrough is limited to
positive thread tuning and logging flags, leaving identity and profile semantics
manifest-controlled.
Benchmark timestamps come only from the absolute `/bin/date` system clock, not
from `PATH` or an environment override. New benchmark
publication validates the full document and refuses a filename collision.

A full-model lease under the per-user/session temporary root coordinates only
`metal-llm` managed serving and local benchmark processes across checkouts using
that same root. Endpoint benchmarks additionally bind to the live managed server
identity. This does not detect or control unrelated model processes. Vision
fixtures are tracked, checksum-recorded, regular non-symlink PNG/JPEG files
confined to the repository fixture directory. Their lowercase extensions must
match detected MIME exactly, and upload payloads use the detected MIME.

The repository remains compact and auditable, but maintainers must update
manifests and patch applicability deliberately when upstream changes. Evidence
that was not captured is stored as `null`, not inferred later.
