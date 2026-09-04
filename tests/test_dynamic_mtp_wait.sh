#!/bin/zsh
set -euo pipefail
setopt extended_glob
unsetopt bg_nice

root=${0:A:h:h}
helper="$root/tests/integration/dynamic_mtp_helpers.zsh"
harness="$root/tests/integration/test_dynamic_mtp.sh"
[[ ! -f "$helper" ]] || source "$helper"

fail() {
    print -u2 -- "$1"
    exit 1
}

typeset -f metal_llm_wait_for_process_diagnostic >/dev/null || \
    fail 'missing diagnostic-driven process wait helper'

ps() {
    local process_pid=''
    while (( $# > 0 )); do
        [[ "$1" == -p ]] && { process_pid=$2; shift 2; continue; }
        shift
    done
    [[ -n "$process_pid" ]] || return 2
    print -- "fixture-start-$process_pid"
}

process_start_identity() {
    local process_pid=$1 start
    start=$(ps -p "$process_pid" -o lstart= 2>/dev/null) || return 1
    start=${start##[[:space:]]#}
    start=${start%%[[:space:]]#}
    print -r -- "$start"
}

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-diagnostic-wait.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT
expected='managed full-model process is already active'

delayed_log="$temporary_root/delayed.log"
: > "$delayed_log"
(
    sleep 1
    print -- "metal-llm: $expected: serve fixture-model" >> "$delayed_log"
    exit 1
) &
delayed_pid=$!
delayed_started=$(process_start_identity "$delayed_pid")
metal_llm_wait_for_process_diagnostic "$delayed_pid" "$delayed_started" \
  "$delayed_log" "$expected" 4 0.1 || \
    fail 'diagnostic wait did not accept a delayed exact lease rejection'

wrong_log="$temporary_root/wrong.log"
: > "$wrong_log"
(
    sleep 0.2
    print -- 'metal-llm: artifact checksum mismatch' >> "$wrong_log"
    exit 1
) &
wrong_pid=$!
wrong_started=$(process_start_identity "$wrong_pid" 2>/dev/null || true)
if [[ -n "$wrong_started" ]] && metal_llm_wait_for_process_diagnostic \
    "$wrong_pid" "$wrong_started" "$wrong_log" "$expected" 2 0.1; then
    fail 'diagnostic wait accepted process exit without the lease rejection'
fi

timeout_log="$temporary_root/timeout.log"
: > "$timeout_log"
sleep 60 &
timeout_pid=$!
timeout_started=$(process_start_identity "$timeout_pid")
set +e
metal_llm_wait_for_process_diagnostic "$timeout_pid" "$timeout_started" \
  "$timeout_log" "$expected" 1 0.1
timeout_status=$?
set -e
if [[ "$timeout_status" != 124 ]]; then
    kill "$timeout_pid" 2>/dev/null || true
    wait "$timeout_pid" 2>/dev/null || true
    fail "diagnostic wait returned $timeout_status instead of bounded-timeout status 124"
fi
current_started=$(process_start_identity "$timeout_pid")
[[ "$current_started" == "$timeout_started" ]] || fail 'timeout fixture PID identity changed'
kill "$timeout_pid"
wait "$timeout_pid" 2>/dev/null || true

grep -Fq 'second_serve_timeout_seconds=900' "$harness" || \
    fail 'integration harness lacks the bounded second-serve diagnostic timeout'
grep -Fq 'metal_llm_wait_for_process_diagnostic "$second_pid" "$second_started"' "$harness" || \
    fail 'integration harness does not use the diagnostic-driven wait for its second serve'
if grep -Fq 'for attempt in {1..30}' "$harness"; then
    fail 'integration harness still treats 30 seconds of artifact verification as lease failure'
fi
grep -Fq '[[ "$boundary" == 32768 || "$boundary" == 32769 ]] && stream=true' "$harness" || \
    fail 'integration harness lacks streamed boundary coverage on both dynamic routes'

print -- 'dynamic-MTP diagnostic wait checks: PASS'
