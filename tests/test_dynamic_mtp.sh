#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
collector="$root/tests/integration/test_dynamic_mtp.sh"

fail() {
    print -u2 -- "$1"
    exit 1
}

[[ -f "$collector" && -x "$collector" ]] || fail 'missing executable dynamic-MTP correctness collector'

skip_output=$(zsh "$collector")
[[ "$skip_output" == 'SKIP: dynamic-MTP integration requires METAL_LLM_INTEGRATION=1' ]] || \
    fail 'correctness collector does not skip explicitly by default'

self_test_output=$(zsh "$collector" --self-test)
[[ "$self_test_output" == 'dynamic-MTP correctness collector self-test: PASS' ]] || \
    fail 'correctness collector self-test failed'

print -- 'dynamic-MTP correctness collector checks: PASS'
