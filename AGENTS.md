# Repository guidance

Metal LLM Lab is a reproducible research repository. Keep changes explicit
about whether information is measured, claimed upstream, hypothesized, or
planned.

## Required practices

- Record provenance for runtime revisions, ordered patches and checksums, model
  artifacts, hardware and OS state, build settings, commands, fixtures,
  generation settings, and raw measurements.
- Verify cryptographic checksums before using downloaded artifacts; retain each
  artifact's source, license, and expected checksum.
  Explicit `--artifact-check disabled` is a user-authorized model-only exception:
  retain basic file checks, mark results unverified, and never mint trusted
  receipts. Runtime integrity verification is not disabled.
- Do not perform hidden system mutation: scripts must not use `sudo`, silently
  install global packages, alter macOS settings, or enable telemetry.
- Run relevant automated tests before benchmark or correctness claims, clearly
  distinguishing local integration checks from lightweight validation.
- Preserve raw results and link summaries and claims back to them. Do not
  overwrite, hand-edit, or discard measurements to improve a result.

## Repository boundaries

Keep model weights, build outputs, third-party sources, caches, partial
downloads, local environments, logs, and secrets out of Git. Use
repository-relative or configured paths. Never publish tokens, credentials,
usernames, or unnecessary private absolute paths in manifests, results, issues,
or documentation.

Experimental changes stay as versioned patch series against pinned upstream
revisions until a dedicated runtime fork is justified. Stop on a patch-context
or revision mismatch rather than guessing.
