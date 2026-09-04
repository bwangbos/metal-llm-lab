#!/bin/zsh
set -euo pipefail
root=${0:A:h:h}
for file_path in README.md AGENTS.md CONTRIBUTING.md SECURITY.md LICENSE .gitignore .gitattributes; do
  [[ -f "$root/$file_path" ]] || { print -u2 -- "missing $file_path"; exit 1; }
done
grep -q 'MIT License' "$root/LICENSE"
grep -Fq 'Supported platforms: macOS on Apple Silicon only.' "$root/README.md"
tr '\n' ' ' < "$root/README.md" | grep -Fq 'Non-macOS and non-Apple-Silicon environments are unsupported; commands must fail with clear, actionable diagnostics.'
for equivalent in \
  'custom --runtime tuned --mtp on --context 32768 --vision on' \
  'custom --runtime tuned --mtp off --context 262144 --vision on' \
  'custom --runtime tuned --mtp dynamic --context 262144 --vision on' \
  'custom --runtime upstream --mtp off --context 32768 --vision on'; do
  grep -Fq -- "$equivalent" "$root/README.md" || {
    print -u2 -- "README is missing preset custom equivalent: $equivalent"
    exit 1
  }
done
stable_row=$(grep -E '^\| `stable` ' "$root/README.md" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
[[ "$stable_row" == *reference* && "$stable_row" == *'not recommended'* ]] || {
  print -u2 -- 'README must describe stable as reference-only and not recommended'
  exit 1
}
tr '[:upper:]\n' '[:lower:] ' < "$root/README.md" | grep -Eq 'vision[^.]{0,100}defaults[^.]{0,20}on' || {
  print -u2 -- 'README must state that vision defaults on'
  exit 1
}
public_docs=(
  "$root/README.md"
  "$root/CONTRIBUTING.md"
  "$root/.github/ISSUE_TEMPLATE/benchmark.yml"
  "$root/docs/models/qwen3.8-flash-next.md"
  "$root/docs/hardware/apple-m5-max-128gb.md"
  "$root/docs/decisions/0002-dynamic-mtp-direction.md"
  "$root/docs/troubleshooting/qwen3.8-flash-next.md"
)
for obsolete in '--profile vision' '--profile hybrid' 'METAL_LLM_CONTEXT' \
  "selects the detected hardware manifest's recommendation"; do
  if rg -n --fixed-strings -- "$obsolete" "${public_docs[@]}"; then
    print -u2 -- "public documentation still contains obsolete interface prose: $obsolete"
    exit 1
  fi
done
grep -Fq 'uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1' "$root/.github/workflows/ci.yml" || {
  print -u2 -- 'GitHub checkout action is not pinned to reviewed v7.0.1 commit'
  exit 1
}
for pattern in '/.lab/' '/models/' '/build/' '.env' '*.gguf' '*.part'; do
  grep -Fqx "$pattern" "$root/.gitignore" || { print -u2 -- "missing ignore: $pattern"; exit 1; }
done
git -C "$root" ls-files -z | xargs -0 stat -f '%z %N' | awk '$1 > 10485760 { bad=1; print } END { exit bad }'
print -- 'repository checks: PASS'
