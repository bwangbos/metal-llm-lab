#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
collector="$root/tests/integration/test_dynamic_mtp_performance.sh"

fail() {
    print -u2 -- "$1"
    exit 1
}

[[ -f "$collector" && -x "$collector" ]] || fail 'missing executable dynamic-MTP performance collector'

skip_output=$(zsh "$collector")
[[ "$skip_output" == 'SKIP: dynamic-MTP performance requires METAL_LLM_PERFORMANCE=1' ]] || \
    fail 'performance collector does not skip explicitly by default'

self_test_output=$(METAL_LLM_PERFORMANCE=1 zsh "$collector" --self-test)
[[ "$self_test_output" == $'dynamic-MTP performance self-test: PASS\nperformance policy artifact self-test: PASS\nperformance fail-fast self-test: PASS\nperformance checkpoint integration self-test: PASS' ]] || \
    fail 'performance collector self-test failed'

for required_text in \
  'policies=(on off dynamic)' \
  'effective_lengths=(29000 30000 32767 32768 32769 33868 98304)' \
  'context=262144' \
  'warmups_per_cell=1' \
  'samples_per_cell=5' \
  'throughput_tolerance_percent=5' \
  'generated_tokens=128' \
  'source "$root/lib/setup.zsh"' \
  'source "$root/lib/performance-checkpoint.zsh"' \
  'metal_llm_validate_dynamic_mtp_correctness_evidence' \
  'correctness_harness_sha256' \
  'metal_llm_performance_checkpoint_matches_published_runs' \
  'metal_llm_validate_dynamic_mtp_derived_data' \
  'metal_llm_performance_checkpoint_validate_path "$root" "$checkpoint_path"' \
  'cache_prompt: false' \
  'temperature: 0' \
  'seed: 1234' \
  'response_path="$responses_dir/$server_session_id-$case_id.response"' \
  'metal_llm_managed_identity_is_live "$identity_record"' \
  'metal_llm_release_managed_lease "$server_owner_token"' \
  'metal_llm_validate_result "$result_part"' \
  '2026-09-03-qwen38-dynamic-mtp.json'; do
    grep -Fq "$required_text" "$collector" || \
        fail "performance collector lacks required contract: $required_text"
done

if grep -Eq -- '--context (32768|65536|98304|131072)|--vision off|--runtime upstream' "$collector"; then
    fail 'performance collector contains a reduced-context, no-vision, or upstream fallback'
fi

print -- 'dynamic-MTP performance collector checks: PASS'
