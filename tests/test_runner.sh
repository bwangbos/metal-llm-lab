#!/bin/zsh
set -euo pipefail

source_root=${0:A:h:h}
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-runner.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT

fail() {
    print -u2 -- "$1"
    exit 1
}

assert_secret_rejected() {
    local fixture_root=$1
    local expected_file=$2
    local secret_value=$3
    local output

    if output=$(cd "$fixture_root" && zsh tests/run.sh --check-secrets 2>&1); then
        fail "secret check accepted $expected_file"
    fi
    [[ "$output" == *"secret-like token found in tracked file: $expected_file"* ]] || \
        fail "secret check did not name $expected_file"
    [[ "$output" != *"$secret_value"* ]] || fail 'secret check printed a token value'
}

project_root="$temporary_root/project-key"
git clone --no-local --quiet "$source_root" "$project_root"
cp "$source_root/tests/run.sh" "$project_root/tests/run.sh"
project_key='sk-proj-'
project_key+='abcdefghijklmnopqrstuvwxyz0123456789'
print -- "example project key: $project_key" >> "$project_root/README.md"
assert_secret_rejected "$project_root" 'README.md' "$project_key"

binary_root="$temporary_root/binary-key"
git clone --no-local --quiet "$source_root" "$binary_root"
cp "$source_root/tests/run.sh" "$binary_root/tests/run.sh"
binary_key='sk-proj-'
binary_key+='ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
printf '\0binary-prefix-%s-binary-suffix\377' "$binary_key" > "$binary_root/tests/runner-secret.bin"
git -C "$binary_root" add -- tests/runner-secret.bin
assert_secret_rejected "$binary_root" 'tests/runner-secret.bin' "$binary_key"

print -- 'runner checks: PASS'
