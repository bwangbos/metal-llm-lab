# Explicit model verification opt-out

Approved September 8, 2026. This supersedes the no-opt-out restriction in the
September 4 artifact-verification cache design; that document remains history.

`cached` remains the default for setup, serve, and bench in both packages.
It hashes files when their trusted receipts are missing or stale. `full`
explicitly hashes every required model artifact.

`disabled` is an explicit per-command opt-out from model-file hashing, including
new downloads, local imports, and MTPLX launch rechecks. File existence, size,
safe-path checks and runtime integrity checks remain enforced. This mode cannot
detect same-size corruption and is not recommended for audited measurements.
It neither creates nor refreshes trusted receipts. Subsequent cached commands
still need valid receipts or fresh hashes.

Results use requested/effective mode `disabled`, zero hit/miss/hash counts and
a null receipt-set digest. Their model hashes are expected manifest values,
not measured evidence. Readouts explicitly mark artifacts UNVERIFIED. An
endpoint started without verification must be benchmarked with the same opt-out
or restarted with verification before collecting verified results.

Offline tests exercise imports, completed downloads, launch propagation,
runtime tampering, command parsing, receipt preservation, and benchmark/report
round trips. No live inference or running-instance changes are part of this
change.
