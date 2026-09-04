#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
checkpoint_library="$root/lib/performance-checkpoint.zsh"

fail() {
    print -u2 -- "$1"
    exit 1
}

[[ -f "$checkpoint_library" && ! -L "$checkpoint_library" ]] || \
    fail 'missing durable performance checkpoint implementation'
source "$checkpoint_library"

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-checkpoint-test.XXXXXX")
temporary_root=${temporary_root:A}
trap '[[ "${METAL_LLM_TEST_KEEP_TEMP:-0}" == 1 ]] || rm -rf -- "$temporary_root"' EXIT
repository_root="$temporary_root/repository"
mkdir -- "$repository_root"
checkpoint="$repository_root/checkpoint"
fixture_response='fixture response without private data'
fixture_response_sha=$(print -rn -- "$fixture_response" | shasum -a 256 | awk '{print $1}')

identity=$(jq -cn '
  {
    schema_version: 1,
    collection_started: "2026-09-04T12:00:00Z",
    repository: {revision: ("1" * 40), tree_sha: ("2" * 40)},
    collector: {
      path: "tests/integration/test_dynamic_mtp_performance.sh", sha256: ("3" * 64),
      checkpoint_library_path: "lib/performance-checkpoint.zsh", checkpoint_library_sha256: ("0" * 64)
    },
    manifests: {
      hardware_sha256: ("4" * 64), model_sha256: ("5" * 64), runtime_sha256: ("6" * 64)
    },
    correctness_evidence_sha256: ("7" * 64), correctness_harness_sha256: ("d" * 64),
    accepted_allocation_evidence_sha256: ("e" * 64),
    hardware: {id: "apple-m5-max-128gb", chip: "Apple M5 Max", unified_memory_bytes: 137438953472},
    system: {
      operating_system: "macOS", operating_system_version: "26.0",
      compiler: "Apple clang fixture", sdk: "MacOSX26.0.sdk",
      power_source: "AC Power", low_power_mode: false
    },
    runtime: {
      id: "llama-cpp-qwen38-hybrid", tested_revision: ("8" * 40), tested_tree_sha: ("9" * 40),
      manifest_sha256: ("6" * 64), build_receipt_sha256: ("a" * 64),
      executable: {name: "llama-server", sha256: ("b" * 64)}
    },
    model_manifest_sha256: ("5" * 64),
    artifacts: [range(0; 35) | {id: ("fixture-artifact-" + tostring), bytes: 123, sha256: ("c" * 64)}],
    matrix: {
      policies: ["on", "off", "dynamic"],
      effective_prompt_lengths: [29000, 30000, 32767, 32768, 32769, 33868, 98304],
      warmups_per_cell: 1, samples_per_cell: 5
    },
    generation: {
      context: 262144, vision: true, generated_tokens: 128,
      temperature: 0, seed: 1234, reasoning: false, ignore_eos: true,
      cache_prompt: false, parallel: 1, draft_n_max: 2
    },
    comparison: {metric: "generation_tokens_per_second", tolerance_percent: 5, dynamic_threshold: 32768}
  }
')

run=$(jq -cn --arg response_sha "$fixture_response_sha" '
  {
    id: "on-29000-s1", experiment: "dynamic-mtp-performance", measurement_kind: "single_run",
    request_kind: "text",
    timestamp: "2026-09-04T12:01:00Z", repository_revision: ("1" * 40),
    hardware_id: "apple-m5-max-128gb", runtime_id: "llama-cpp-qwen38-hybrid",
    runtime_revision: ("8" * 40), profile: null, profile_id: "custom", runtime_alias: "tuned",
    context: 262144, vision: true, mtp_policy: "on", mtp_selected: true, mtp_threshold: null,
    prompt_tokens: 28999, effective_prompt_tokens: 29000, generated_tokens: 128,
    prompt_tokens_per_second: 100.25, generation_tokens_per_second: 40.5,
    output_sha256: ("d" * 64), draft_acceptance: "100/120",
    command: ["curl", "POST", "/completion", ("payload-sha256:" + ("e" * 64))],
    generation_settings: {temperature: 0, seed: 1234, max_tokens: 128, reasoning: false, draft_n_max: 2},
    notes: ("Measured sample 1 of 5 after 1 warm-up; response SHA-256 " + $response_sha + ".")
  }
')
envelope=$(jq -cn --argjson run "$run" \
  '{schema_version: 1, server_session_id: "on-session-1", run: $run}')

metal_llm_performance_checkpoint_open "$checkpoint" "$identity" "$repository_root" || \
    fail 'could not initialize a valid checkpoint'
[[ "$METAL_LLM_PERFORMANCE_CHECKPOINT_RESUMED" == false && \
   "$METAL_LLM_PERFORMANCE_CHECKPOINT_RUN_COUNT" == 0 ]] || \
    fail 'new checkpoint did not report an empty initial state'

mkdir -- "$checkpoint/logs" "$checkpoint/responses"
print -- 'fixture server log' > "$checkpoint/logs/on-session-1.log"
print -rn -- "$fixture_response" > "$checkpoint/responses/on-session-1-on-29000-s1.response"
metal_llm_performance_checkpoint_publish_run "$checkpoint" "$envelope" "$repository_root" || \
    fail 'could not publish a valid retained sample'
original_row_sha=$(shasum -a 256 "$checkpoint/runs/on-29000-s1.json" | awk '{print $1}')

metal_llm_performance_checkpoint_open "$checkpoint" "$identity" "$repository_root" || \
    fail 'valid checkpoint did not resume'
[[ "$METAL_LLM_PERFORMANCE_CHECKPOINT_RESUMED" == true && \
   "$METAL_LLM_PERFORMANCE_CHECKPOINT_RUN_COUNT" == 1 ]] || \
    fail 'resumed checkpoint did not retain exactly one sample'
rehydrated=$(metal_llm_performance_checkpoint_runs "$checkpoint" "$repository_root")
expected_rehydrated=$(jq -cn --arg session 'on-session-1' --argjson run "$run" \
  '$run + {server_session_id: $session}')
[[ "$rehydrated" == "$expected_rehydrated" ]] || \
    fail 'resumed sample lost its exact server-session provenance'

published_result="$temporary_root/published-result.json"
jq -cn --argjson run "$expected_rehydrated" '{runs: [$run]}' > "$published_result"
metal_llm_performance_checkpoint_matches_published_runs \
  "$checkpoint" "$repository_root" "$published_result" || \
    fail 'checkpoint rows did not match identical published runs'
jq '.runs[0].generation_tokens_per_second += 1' "$published_result" > "$published_result.part"
mv -- "$published_result.part" "$published_result"
if metal_llm_performance_checkpoint_matches_published_runs \
  "$checkpoint" "$repository_root" "$published_result"; then
    fail 'checkpoint rows matched a published result with different measured values'
fi

if metal_llm_performance_checkpoint_publish_run "$checkpoint" "$envelope" "$repository_root" 2>/dev/null; then
    fail 'checkpoint overwrote a retained sample with the same identity'
fi
[[ "$(shasum -a 256 "$checkpoint/runs/on-29000-s1.json" | awk '{print $1}')" == "$original_row_sha" ]] || \
    fail 'duplicate publication changed a retained sample'

assert_identity_mismatch_rejected() {
    local filter=$1 description=$2 mutated
    mutated=$(jq "$filter" <<< "$identity")
    if metal_llm_performance_checkpoint_open "$checkpoint" "$mutated" "$repository_root" 2>/dev/null; then
        fail "checkpoint accepted mismatched immutable identity: $description"
    fi
}

assert_identity_mismatch_rejected '.repository.tree_sha = ("f" * 40)' 'repository tree'
assert_identity_mismatch_rejected '.collector.sha256 = ("f" * 64)' 'collector identity'
assert_identity_mismatch_rejected '.collector.checkpoint_library_sha256 = ("f" * 64)' 'checkpoint implementation identity'
assert_identity_mismatch_rejected '.manifests.model_sha256 = ("f" * 64)' 'model manifest'
assert_identity_mismatch_rejected '.hardware.unified_memory_bytes = 1' 'hardware'
assert_identity_mismatch_rejected '.matrix.effective_prompt_lengths[-1] = 131072' 'matrix'
assert_identity_mismatch_rejected '.generation.generated_tokens = 64' 'generation settings'
assert_identity_mismatch_rejected '.runtime.executable.sha256 = ("f" * 64)' 'runtime provenance'
assert_identity_mismatch_rejected '.artifacts[0].sha256 = ("f" * 64)' 'artifact provenance'
assert_identity_mismatch_rejected '.comparison.tolerance_percent = 10' 'comparison tolerance'
assert_identity_mismatch_rejected '.correctness_harness_sha256 = ("f" * 64)' 'correctness harness'
assert_identity_mismatch_rejected '.accepted_allocation_evidence_sha256 = ("f" * 64)' 'allocation evidence'

malformed="$repository_root/malformed"
cp -R "$checkpoint" "$malformed"
jq '.run.effective_prompt_tokens = 30000' "$malformed/runs/on-29000-s1.json" > \
  "$malformed/runs/on-29000-s1.json.part"
mv -- "$malformed/runs/on-29000-s1.json.part" "$malformed/runs/on-29000-s1.json"
if metal_llm_performance_checkpoint_open "$malformed" "$identity" "$repository_root" 2>/dev/null; then
    fail 'checkpoint accepted a retained row whose ID disagrees with its matrix cell'
fi

missing_request_kind="$repository_root/missing-request-kind"
cp -R "$checkpoint" "$missing_request_kind"
jq 'del(.run.request_kind)' "$missing_request_kind/runs/on-29000-s1.json" > \
  "$missing_request_kind/runs/on-29000-s1.json.part"
mv -- "$missing_request_kind/runs/on-29000-s1.json.part" \
  "$missing_request_kind/runs/on-29000-s1.json"
if metal_llm_performance_checkpoint_open \
  "$missing_request_kind" "$identity" "$repository_root" 2>/dev/null; then
    fail 'checkpoint accepted a future performance row without typed request kind'
fi

unsafe="$repository_root/unsafe"
cp -R "$checkpoint" "$unsafe"
rm -- "$unsafe/runs/on-29000-s1.json"
ln -s -- "$checkpoint/runs/on-29000-s1.json" "$unsafe/runs/on-29000-s1.json"
if metal_llm_performance_checkpoint_open "$unsafe" "$identity" "$repository_root" 2>/dev/null; then
    fail 'checkpoint accepted a symlinked retained row'
fi

orphan="$repository_root/orphan"
cp -R "$checkpoint" "$orphan"
print -- '{"partial":' > "$orphan/runs/.part.interrupted"
if metal_llm_performance_checkpoint_open "$orphan" "$identity" "$repository_root" 2>/dev/null; then
    fail 'checkpoint accepted interrupted unsafe state'
fi

log_orphan="$repository_root/log-orphan"
cp -R "$checkpoint" "$log_orphan"
print -- 'partial log identity' > "$log_orphan/logs/.part.interrupted"
if metal_llm_performance_checkpoint_open "$log_orphan" "$identity" "$repository_root" 2>/dev/null; then
    fail 'checkpoint accepted an unexpected durable log entry'
fi

response_unsafe="$repository_root/response-unsafe"
cp -R "$checkpoint" "$response_unsafe"
rm -- "$response_unsafe/responses/on-session-1-on-29000-s1.response"
ln -s -- "$checkpoint/logs/on-session-1.log" \
  "$response_unsafe/responses/on-session-1-on-29000-s1.response"
if metal_llm_performance_checkpoint_open "$response_unsafe" "$identity" "$repository_root" 2>/dev/null; then
    fail 'checkpoint accepted a symlinked durable response'
fi

response_tampered="$repository_root/response-tampered"
cp -R "$checkpoint" "$response_tampered"
print -rn -- 'different response bytes' > \
  "$response_tampered/responses/on-session-1-on-29000-s1.response"
if metal_llm_performance_checkpoint_open "$response_tampered" "$identity" "$repository_root" 2>/dev/null; then
    fail 'checkpoint accepted a response that no longer matches its retained row'
fi

ancestor_repository="$temporary_root/ancestor-repository"
outside_evidence="$temporary_root/outside-evidence"
mkdir -- "$ancestor_repository" "$outside_evidence"
ln -s -- "$outside_evidence" "$ancestor_repository/.lab"
ancestor_checkpoint="$ancestor_repository/.lab/task6-evidence/dynamic-mtp-performance-checkpoint"
if metal_llm_performance_checkpoint_open \
  "$ancestor_checkpoint" "$identity" "$ancestor_repository" 2>/dev/null; then
    fail 'checkpoint accepted a symlinked ancestor beneath the repository root'
fi
[[ ! -e "$outside_evidence/task6-evidence" ]] || \
    fail 'checkpoint wrote through a symlinked ancestor before rejecting it'

print -- 'performance checkpoint checks: PASS'
