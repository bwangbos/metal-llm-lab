#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
max_tracked_bytes=$((10 * 1024 * 1024))

run_tracked_tests() {
    local test_file
    while IFS= read -r -d $'\0' test_file; do
        print -- "test: $test_file"
        zsh "$root/$test_file"
    done < <(git -C "$root" ls-files -z -- ':(glob)tests/test_*.sh')
}

check_shell_syntax() {
    local shell_file syntax_output
    while IFS= read -r -d $'\0' shell_file; do
        if ! syntax_output=$(zsh -n -- "$root/$shell_file" 2>&1); then
            print -u2 -- "shell syntax check failed: $shell_file"
            print -u2 -- "$syntax_output"
            return 1
        fi
    done < <(git -C "$root" ls-files -z -- ':(glob)**/*.sh' ':(glob)**/*.zsh' ':(glob)bin/**')
}

check_json() {
    local json_file
    while IFS= read -r -d $'\0' json_file; do
        jq empty -- "$root/$json_file"
    done < <(git -C "$root" ls-files -z -- ':(glob)**/*.json')
}

check_tracked_file_sizes() {
    local tracked_file byte_count
    local oversized=0
    while IFS= read -r -d $'\0' tracked_file; do
        byte_count=$(stat -f '%z' -- "$root/$tracked_file")
        if (( byte_count > max_tracked_bytes )); then
            print -u2 -- "tracked file exceeds ${max_tracked_bytes} bytes: $tracked_file ($byte_count)"
            oversized=1
        fi
    done < <(git -C "$root" ls-files -z)
    (( oversized == 0 ))
}

check_secrets() {
    local token_pattern
    local matches
    local scan_rc
    token_pattern='(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|hf_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})'

    if matches=$(git -C "$root" grep -nEI -- "$token_pattern"); then
        print -u2 -- 'secret-like token found in tracked files:'
        print -u2 -- "$matches"
        return 1
    else
        scan_rc=$?
    fi
    (( scan_rc == 1 )) || return "$scan_rc"
}

run_tracked_tests
check_shell_syntax
check_json
git -C "$root" diff --check
git -C "$root" diff --cached --check
check_secrets
check_tracked_file_sizes
print -- 'all checks: PASS'
