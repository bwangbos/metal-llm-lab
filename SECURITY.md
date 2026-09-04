# Security policy

Report suspected vulnerabilities privately to the repository maintainer through
GitHub's private vulnerability reporting channel, if enabled, rather than in a
public issue. Include a minimal reproduction, impact, affected revision, and
safe mitigation details.

Do not include tokens, credentials, model-access secrets, usernames, or private
absolute paths in any report. Redact logs and configuration before sharing.

Cached artifact verification trusts the same-user local receipt store and the
bound file metadata. A malicious same-user actor able to spoof all bound
metadata, or to modify an artifact after verification, is outside cached mode's
integrity claim. `--artifact-check full` narrows this exposure by rereading and
hashing artifact bodies, but it does not eliminate check/use races; keep
untrusted actors out of the local account and artifact paths.

For non-security reproducibility problems, use [CONTRIBUTING.md](CONTRIBUTING.md).
