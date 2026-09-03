#!/bin/zsh
set -euo pipefail
root=${0:A:h:h}
for file_path in README.md AGENTS.md CONTRIBUTING.md SECURITY.md LICENSE .gitignore .gitattributes; do
  [[ -f "$root/$file_path" ]] || { print -u2 -- "missing $file_path"; exit 1; }
done
grep -q 'MIT License' "$root/LICENSE"
grep -Fq 'Supported platforms: macOS on Apple Silicon only.' "$root/README.md"
tr '\n' ' ' < "$root/README.md" | grep -Fq 'Non-macOS and non-Apple-Silicon environments are unsupported; commands must fail with clear, actionable diagnostics.'
grep -Fq 'Dynamic per-request MTP selection is future work.' "$root/README.md"
for pattern in '/.lab/' '/models/' '/build/' '.env' '*.gguf' '*.part'; do
  grep -Fqx "$pattern" "$root/.gitignore" || { print -u2 -- "missing ignore: $pattern"; exit 1; }
done
git -C "$root" ls-files -z | xargs -0 stat -f '%z %N' | awk '$1 > 10485760 { bad=1; print } END { exit bad }'
print -- 'repository checks: PASS'
