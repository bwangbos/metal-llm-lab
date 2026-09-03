# Contributing

Contributions should make a result easier to reproduce. Include exact repository
and upstream revisions, patches, commands, hardware and OS context, fixtures,
and raw measurements. Run relevant lightweight tests before proposing benchmark
or correctness claims, and label local integration-only validation clearly.

## Reporting reproducibility defects

Open an issue with a minimal reproducer, expected and observed behavior,
sanitized logs, relevant checksums, and commands used. Do not publish API tokens,
credentials, usernames, or private absolute paths. If the defect also creates a
security risk, follow [SECURITY.md](SECURITY.md) instead.

Preserve raw benchmark outputs. Summaries should link to raw results and state
known anomalies rather than replacing inconvenient measurements.
