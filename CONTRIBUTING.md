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

## Dynamic-MTP acceptance evidence

The real acceptance harness is intentionally excluded from lightweight test
runs. It skips unless the operator explicitly opts in, and it requires the exact
Apple M5 Max 128 GiB manifest plus already verified artifacts and build receipts:

```sh
METAL_LLM_INTEGRATION=1 zsh tests/integration/test_dynamic_mtp.sh
```

Do not make that run download weights, build a runtime, recover or replace a
live managed lease, or silently change the 262,144-token `auto` configuration.
Review the sanitized, validator-approved raw result in `results/raw/` before
changing acceptance or recommendation status. Include failures and output
divergences; a route or throughput result is not evidence of behavioral
equivalence.
