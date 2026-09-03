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
benchmark records retain their command and environment. The repository remains
compact and auditable, but maintainers must update manifests and patch
applicability deliberately when upstream changes.
