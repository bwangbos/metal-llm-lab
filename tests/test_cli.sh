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
assert_contains "$help_output" 'metal-llm setup MODEL [--artifact-check cached|full|disabled] [--dry-run] [--yes]'
assert_contains "$help_output" 'METAL_LLM_BUILD_RESERVE_BYTES'
assert_contains "$help_output" 'metal-llm serve MODEL [--profile auto|fast|long|stable] [--vision on|off] [--artifact-check cached|full|disabled]'
assert_contains "$help_output" 'metal-llm serve MODEL --profile custom --runtime tuned|upstream --mtp on|off|dynamic --context TOKENS [--vision on|off] [--artifact-check cached|full|disabled]'
assert_contains "$help_output" 'serve defaults: --profile auto and model vision default'
assert_contains "$help_output" 'metal-llm bench MODEL --suite SUITE [--mode MODE] [--artifact-check cached|full|disabled] [--dry-run]'
assert_contains "$help_output" 'metal-llm report [--check]'
[[ "$help_output" != *'METAL_LLM_CONTEXT'* ]] || fail 'help advertises removed METAL_LLM_CONTEXT'

if unknown_output=$("$cli" definitely-not-a-command 2>&1); then
    fail 'unknown command succeeded'
else
    unknown_status=$?
fi
(( unknown_status == 2 )) || fail "unknown command exited $unknown_status, expected 2"
assert_contains "$unknown_output" 'unknown command: definitely-not-a-command'

if serve_output=$("$cli" serve 2>&1); then
    fail 'serve without arguments succeeded'
else
    serve_status=$?
fi
(( serve_status == 2 )) || fail "serve without arguments exited $serve_status, expected 2"
assert_contains "$serve_output" 'usage: metal-llm serve MODEL [--profile auto|fast|long|stable] [--vision on|off] [--artifact-check cached|full|disabled]'
assert_contains "$serve_output" 'metal-llm serve MODEL --profile custom --runtime tuned|upstream --mtp on|off|dynamic --context TOKENS [--vision on|off] [--artifact-check cached|full|disabled]'

if bench_output=$("$cli" bench 2>&1); then
    fail 'bench without arguments succeeded'
else
    bench_status=$?
fi
(( bench_status == 2 )) || fail "bench without arguments exited $bench_status, expected 2"
assert_contains "$bench_output" 'usage: metal-llm bench MODEL --suite SUITE'

if report_output=$("$cli" report unexpected 2>&1); then
    fail 'report with an unknown argument succeeded'
else
    report_status=$?
fi
(( report_status == 2 )) || fail "report with an unknown argument exited $report_status, expected 2"
assert_contains "$report_output" 'usage: metal-llm report [--check]'

outside_dir=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-cli.XXXXXX")
trap 'rm -rf -- "$outside_dir"' EXIT
outside_help=$(cd "$outside_dir" && "$cli" help)
assert_contains "$outside_help" 'metal-llm doctor'

bootstrap_output=$(cd "$outside_dir" && "$root/scripts/bootstrap-macos.sh" 2>&1 || true)
assert_contains "$bootstrap_output" './bin/metal-llm setup qwen3.8-flash-next'

print -- 'cli checks: PASS'
