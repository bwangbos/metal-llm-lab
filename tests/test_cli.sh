#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
cli="$root/bin/metal-llm"

fail() {
    print -u2 -- "$1"
    exit 1
}

assert_contains() {
    local haystack=$1
    local needle=$2
    [[ "$haystack" == *"$needle"* ]] || fail "missing expected output: $needle"
}

[[ -x "$cli" ]] || fail 'missing executable bin/metal-llm'

help_output=$("$cli" help)
for command_name in doctor setup serve bench report help; do
    assert_contains "$help_output" "$command_name"
done
assert_contains "$help_output" 'metal-llm setup MODEL [--dry-run] [--yes]'

if unknown_output=$("$cli" definitely-not-a-command 2>&1); then
    fail 'unknown command succeeded'
else
    unknown_status=$?
fi
(( unknown_status == 2 )) || fail "unknown command exited $unknown_status, expected 2"
assert_contains "$unknown_output" 'unknown command: definitely-not-a-command'

for reserved_command in serve bench report; do
    if reserved_output=$("$cli" "$reserved_command" 2>&1); then
        fail "reserved command succeeded: $reserved_command"
    else
        reserved_status=$?
    fi
    (( reserved_status == 2 )) || fail "reserved command exited $reserved_status, expected 2"
    assert_contains "$reserved_output" "not implemented yet: $reserved_command"
done

outside_dir=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-cli.XXXXXX")
trap 'rm -rf -- "$outside_dir"' EXIT
outside_help=$(cd "$outside_dir" && "$cli" help)
assert_contains "$outside_help" 'metal-llm doctor'

bootstrap_output=$(cd "$outside_dir" && "$root/scripts/bootstrap-macos.sh" 2>&1 || true)
assert_contains "$bootstrap_output" './bin/metal-llm setup qwen3.8-flash-next'

print -- 'cli checks: PASS'
