#!/bin/zsh
set -euo pipefail
setopt extended_glob
unsetopt bg_nice

root=${0:A:h:h:h}
METAL_LLM_ROOT=$root
export METAL_LLM_ROOT

if [[ "${METAL_LLM_PERFORMANCE:-0}" != 1 ]]; then
    print -- 'SKIP: dynamic-MTP performance requires METAL_LLM_PERFORMANCE=1'
    exit 0
fi

source "$root/lib/common.zsh"
source "$root/lib/profile.zsh"
source "$root/lib/setup.zsh"
source "$root/lib/runtime-state.zsh"
source "$root/lib/managed-process.zsh"
source "$root/lib/bench.zsh"
source "$root/lib/report.zsh"
source "$root/lib/performance-checkpoint.zsh"
source "$root/tests/integration/dynamic_mtp_helpers.zsh"

fail() {
    print -u2 -- "dynamic-MTP performance: $1"
    exit 1
}

metal_llm_performance_policy_artifacts() {
    local policy=$1 all_artifacts=$2 mtp_artifact_id=$3
    jq -ce --arg policy "$policy" --arg mtp "$mtp_artifact_id" '
      select(type == "array" and length > 0 and
        all(.[]; type == "object" and (.id | type == "string" and length > 0))) |
      . as $artifacts |
      if $policy == "off" then
        (map(select(.id != $mtp))) as $without_mtp |
        select(($without_mtp | length) == (($artifacts | length) - 1)) | $without_mtp
      elif $policy == "on" or $policy == "dynamic" then .
      else error("invalid performance policy") end
    ' <<< "$all_artifacts"
}

retire_published_checkpoint() {
    local checkpoint_path=$1
    local expected="$root/.lab/task6-evidence/dynamic-mtp-performance-checkpoint"
    local retired="$root/.lab/task6-evidence/.dynamic-mtp-performance-completed-$$"
    metal_llm_performance_checkpoint_validate_path "$root" "$checkpoint_path" || \
        fail 'refusing checkpoint path with an unsafe repository-local ancestor'
    metal_llm_performance_checkpoint_validate_path "$root" "$retired" || \
        fail 'refusing retirement path with an unsafe repository-local ancestor'
    [[ "$checkpoint_path" == "$expected" && -d "$checkpoint_path" && ! -L "$checkpoint_path" && \
       ! -e "$retired" && ! -L "$retired" ]] || \
        fail 'refusing to remove an unexpected checkpoint path'
    mv -- "$checkpoint_path" "$retired" || fail 'could not retire the published checkpoint atomically'
    command sync
    metal_llm_performance_checkpoint_validate_path "$root" "$retired" || \
        fail 'retired checkpoint path became unsafe before deletion'
    rm -rf -- "$retired"
    command sync
}

metal_llm_dynamic_mtp_expected_correctness_ids() {
    jq -cn '[
      "boundary-32767", "boundary-32768", "boundary-32769", "calibration-offset",
      "concurrent-long", "concurrent-short", "json-long", "json-short", "reuse-long",
      "reuse-short-first", "reuse-short-second", "text-long", "text-short", "tool-long",
      "tool-short", "vision-cross-expanded", "vision-cross-text-control", "vision-long", "vision-short"
    ]'
}

metal_llm_validate_dynamic_mtp_correctness_evidence() {
    local evidence_file=$1 harness_path=$2 harness_sha expected_ids
    harness_sha=$(metal_llm_sha256 "$harness_path") || return 1
    expected_ids=$(metal_llm_dynamic_mtp_expected_correctness_ids) || return 1
    jq -e --arg sha "$harness_sha" --argjson expected "$expected_ids" '
      .model_id == "qwen3.8-flash-next" and .suite_id == "dynamic-mtp-acceptance" and
      .benchmark_mode == "endpoint" and .provenance.repository.clean == true and
      .provenance.suite.sha256 == $sha and
      ([.runs[].id] | sort) == ($expected | sort) and
      ([.runs[].id] | unique | length) == (.runs | length)
    ' "$evidence_file" >/dev/null
}

policies=(on off dynamic)
effective_lengths=(29000 30000 32767 32768 32769 33868 98304)
context=262144
warmups_per_cell=1
samples_per_cell=5
throughput_tolerance_percent=5
comparison_metric=generation_tokens_per_second
generated_tokens=128
threshold=32768
model_id=qwen3.8-flash-next
hardware_id=apple-m5-max-128gb
runtime_id=llama-cpp-qwen38-hybrid
suite_id=dynamic-mtp-performance
host=127.0.0.1
port=8080

metal_llm_performance_statistics() {
    local samples=$1
    jq -cn --argjson samples "$samples" '
      def mean: add / length;
      def sample_sd:
        . as $values | ($values | mean) as $mean |
        (($values | map((. - $mean) * (. - $mean)) | add) / ($values | length - 1)) | sqrt;
      $samples | select(type == "array" and length >= 2 and all(.[]; type == "number")) |
      {mean: mean, sample_sd: sample_sd}
    '
}

metal_llm_performance_within_tolerance() {
    local measured=$1 reference=$2 tolerance=$3
    jq -en --argjson measured "$measured" --argjson reference "$reference" \
      --argjson tolerance "$tolerance" '
      ($measured | type == "number") and ($reference | type == "number" and . > 0) and
      ((((($measured / $reference) - 1) * 100) | fabs) <= ($tolerance + 0.000000001))
    ' >/dev/null
}

metal_llm_performance_self_test() {
    local statistics selected artifact_fixture on_artifacts off_artifacts dynamic_artifacts
    local fail_fast_output fail_fast_rc correctness_fixture correctness_ids correctness_sha
    statistics=$(metal_llm_performance_statistics '[40,42,44,46,48]') || return 1
    jq -e '.mean == 44 and ((.sample_sd - 3.1622776601683795) | fabs) < 0.000000001' \
      <<< "$statistics" >/dev/null || return 1
    metal_llm_performance_within_tolerance 42 40 5 || return 1
    if metal_llm_performance_within_tolerance 42.01 40 5; then
        return 1
    fi
    metal_llm_validate_endpoint_timing \
      '{"speculative":true,"speculative_policy":"dynamic","effective_prompt_tokens":32768,"speculative_threshold":32768}' \
      dynamic 32768 api 1024 || return 1
    metal_llm_validate_endpoint_timing \
      '{"speculative":false,"speculative_policy":"dynamic","effective_prompt_tokens":32769,"speculative_threshold":32768}' \
      dynamic 32768 api 1024 || return 1
    selected=$(metal_llm_extract_speculative_route \
      '{"speculative":false,"speculative_policy":"dynamic","effective_prompt_tokens":32769,"speculative_threshold":32768}') || \
        return 1
    [[ "$selected" == false ]] || return 1
    correctness_fixture=$(mktemp "${TMPDIR:-/tmp}/metal-llm-correctness-evidence.XXXXXX") || return 1
    correctness_ids=$(metal_llm_dynamic_mtp_expected_correctness_ids) || return 1
    correctness_sha=$(metal_llm_sha256 "$root/tests/integration/test_dynamic_mtp.sh") || return 1
    jq -cn --arg sha "$correctness_sha" --argjson ids "$correctness_ids" '
      {
        model_id: "qwen3.8-flash-next", suite_id: "dynamic-mtp-acceptance",
        benchmark_mode: "endpoint", provenance: {repository: {clean: true}, suite: {sha256: $sha}},
        runs: [$ids[] | {id: .}]
      }
    ' > "$correctness_fixture" || return 1
    metal_llm_validate_dynamic_mtp_correctness_evidence \
      "$correctness_fixture" "$root/tests/integration/test_dynamic_mtp.sh" || return 1
    jq 'del(.runs[-1])' "$correctness_fixture" > "$correctness_fixture.part" || return 1
    if metal_llm_validate_dynamic_mtp_correctness_evidence \
      "$correctness_fixture.part" "$root/tests/integration/test_dynamic_mtp.sh"; then
        return 1
    fi
    jq '.provenance.suite.sha256 = ("f" * 64)' "$correctness_fixture" > \
      "$correctness_fixture.part" || return 1
    if metal_llm_validate_dynamic_mtp_correctness_evidence \
      "$correctness_fixture.part" "$root/tests/integration/test_dynamic_mtp.sh"; then
        return 1
    fi
    rm -f -- "$correctness_fixture" "$correctness_fixture.part"
    print -- 'dynamic-MTP performance self-test: PASS'
    artifact_fixture='[{"id":"model"},{"id":"mtp"}]'
    on_artifacts=$(metal_llm_performance_policy_artifacts on "$artifact_fixture" mtp) || return 1
    off_artifacts=$(metal_llm_performance_policy_artifacts off "$artifact_fixture" mtp) || return 1
    dynamic_artifacts=$(metal_llm_performance_policy_artifacts dynamic "$artifact_fixture" mtp) || return 1
    jq -e 'length == 2 and .[1].id == "mtp"' <<< "$on_artifacts" >/dev/null || return 1
    jq -e 'length == 1 and .[0].id == "model"' <<< "$off_artifacts" >/dev/null || return 1
    [[ "$dynamic_artifacts" == "$on_artifacts" ]] || return 1
    if metal_llm_performance_policy_artifacts invalid "$artifact_fixture" mtp >/dev/null 2>&1; then
        return 1
    fi
    print -- 'performance policy artifact self-test: PASS'
    set +e
    fail_fast_output=$( (fail 'fail-fast sentinel'; print -- 'false healthy output') 2>/dev/null)
    fail_fast_rc=$?
    set -e
    [[ "$fail_fast_rc" == 1 && -z "$fail_fast_output" ]] || return 1
    print -- 'performance fail-fast self-test: PASS'
    whence -w metal_llm_performance_checkpoint_open >/dev/null || return 1
    whence -w metal_llm_performance_checkpoint_publish_run >/dev/null || return 1
    whence -w metal_llm_performance_checkpoint_matches_published_runs >/dev/null || return 1
    print -- 'performance checkpoint integration self-test: PASS'
}

if (( $# == 1 )) && [[ "$1" == --self-test ]]; then
    metal_llm_performance_self_test
    exit
elif (( $# != 0 )); then
    print -u2 -- 'usage: METAL_LLM_PERFORMANCE=1 zsh tests/integration/test_dynamic_mtp_performance.sh [--self-test]'
    exit 2
fi

for required_command in git jq curl shasum system_profiler uname ps awk sync; do
    command -v "$required_command" >/dev/null 2>&1 || fail "missing required command: $required_command"
done
metal_llm_require_supported_host || exit 1
[[ -z "${METAL_LLM_HARDWARE_ID:-}" ]] || fail 'METAL_LLM_HARDWARE_ID overrides are forbidden'
[[ -z "${METAL_LLM_REPOSITORY_REVISION:-}" ]] || fail 'repository revision overrides are forbidden'
[[ -z "${METAL_LLM_NOW:-}" ]] || fail 'timestamp overrides are forbidden'
[[ -z "${METAL_LLM_HOST:-}" || "$METAL_LLM_HOST" == "$host" ]] || fail 'METAL_LLM_HOST must be 127.0.0.1'
[[ -z "${METAL_LLM_PORT:-}" || "$METAL_LLM_PORT" == "$port" ]] || fail 'METAL_LLM_PORT must be 8080'
[[ -z "${METAL_LLM_PARALLEL:-}" || "$METAL_LLM_PARALLEL" == 1 ]] || fail 'METAL_LLM_PARALLEL must be 1'
export METAL_LLM_HOST=$host METAL_LLM_PORT=$port METAL_LLM_PARALLEL=1

repository_status=$(git -C "$root" status --porcelain=v1 --untracked-files=all) || exit 1
[[ -z "$repository_status" ]] || fail 'repository checkout must be clean before performance collection'
repository_revision=$(git -C "$root" rev-parse HEAD)
repository_tree=$(git -C "$root" rev-parse 'HEAD^{tree}')
[[ "$repository_revision" =~ '^[0-9a-f]{40}$' && "$repository_tree" =~ '^[0-9a-f]{40}$' ]] || \
    fail 'repository revision and tree must be full Git object IDs'

metal_llm_detect_hardware_manifest || exit 1
[[ "$METAL_LLM_DETECTED_HARDWARE_ID" == "$hardware_id" && \
   "$METAL_LLM_DETECTED_CHIP" == 'Apple M5 Max' && \
   "$METAL_LLM_DETECTED_MEMORY_BYTES" == 137438953472 ]] || \
    fail 'requires exact Apple M5 Max with 128 GiB unified memory'

model_manifest="$root/manifests/models/$model_id.json"
runtime_manifest="$root/manifests/runtimes/$runtime_id.json"
hardware_manifest="$root/manifests/hardware/$hardware_id.json"
collector_path="$root/tests/integration/test_dynamic_mtp_performance.sh"
checkpoint_library_path="$root/lib/performance-checkpoint.zsh"
integration_evidence="$root/.lab/task6-evidence/integration-acceptance.json"
correctness_harness="$root/tests/integration/test_dynamic_mtp.sh"
allocation_evidence="$root/.lab/task6-evidence/accepted-auto-allocation-observation.json"
allocation_server_log="$root/.lab/task6-evidence/accepted-auto-allocation-server.log"
[[ -f "$model_manifest" && -f "$runtime_manifest" && -f "$hardware_manifest" ]] || \
    fail 'required manifests are missing'
[[ -f "$integration_evidence" && ! -L "$integration_evidence" ]] || \
    fail 'validated correctness evidence is required before performance collection'
[[ -f "$allocation_evidence" && ! -L "$allocation_evidence" && \
   -f "$allocation_server_log" && ! -L "$allocation_server_log" ]] || \
    fail 'validated accepted-allocation evidence and server log are required before performance collection'
metal_llm_validate_model_manifest "$model_manifest" "$model_id" || fail 'model manifest is invalid'
metal_llm_validate_runtime_manifest "$runtime_manifest" "$runtime_id" || fail 'runtime manifest is invalid'
metal_llm_validate_result "$integration_evidence" 'staged dynamic-MTP correctness evidence' || \
    fail 'staged correctness evidence is invalid'
metal_llm_validate_dynamic_mtp_correctness_evidence "$integration_evidence" "$correctness_harness" || \
    fail 'staged correctness evidence has an incomplete case set or stale harness identity'

collector_sha=$(metal_llm_sha256 "$collector_path")
checkpoint_library_sha=$(metal_llm_sha256 "$checkpoint_library_path")
integration_evidence_sha=$(metal_llm_sha256 "$integration_evidence")
correctness_harness_sha=$(metal_llm_sha256 "$correctness_harness")
allocation_evidence_sha=$(metal_llm_sha256 "$allocation_evidence")
model_manifest_sha=$(metal_llm_sha256 "$model_manifest")
runtime_manifest_sha=$(metal_llm_sha256 "$runtime_manifest")
hardware_manifest_sha=$(metal_llm_sha256 "$hardware_manifest")
system_provenance=$(metal_llm_benchmark_system_provenance)

metal_llm_verify_runtime_build "$runtime_id" "$runtime_manifest" llama-server || \
    fail 'verified tuned build and receipt are required'
[[ "$METAL_LLM_VERIFIED_RUNTIME_MANIFEST_SHA256" == "$runtime_manifest_sha" ]] || \
    fail 'verified runtime manifest identity changed'
allocation_observation=$(jq -c . "$allocation_evidence") || \
    fail 'accepted-allocation evidence is malformed'
metal_llm_validate_accepted_allocation_observation "$allocation_observation" || \
    fail 'accepted-allocation evidence is invalid'
allocation_log_sha=$(metal_llm_sha256 "$allocation_server_log") || \
    fail 'accepted-allocation server log could not be hashed'
jq -e --arg log_sha "$allocation_log_sha" \
  --arg executable_sha "$METAL_LLM_VERIFIED_EXECUTABLE_SHA256" '
  .identity.server_log_sha256 == $log_sha and .identity.executable_sha256 == $executable_sha
' "$allocation_evidence" >/dev/null || \
    fail 'accepted-allocation evidence does not match its server log and runtime executable'
metal_llm_resolve_profile "$model_manifest" auto on '' '' '' || \
    fail 'auto profile could not be resolved for artifact verification'
artifact_dir="$root/.lab/artifacts/$model_id"
metal_llm_profile_artifact_identities "$model_manifest" "$artifact_dir" "$METAL_LLM_EFFECTIVE_PROFILE" || \
    fail 'all acceptance artifacts must already exist and match their manifest checksums'
verified_artifacts=$METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES
mtp_artifact_id=$(jq -er '.capabilities.mtp.artifact_id' "$model_manifest") || \
    fail 'model manifest has no MTP artifact identity'

result_dir="$root/results/raw"
result_path="$result_dir/2026-09-03-qwen38-dynamic-mtp.json"
checkpoint="$root/.lab/task6-evidence/dynamic-mtp-performance-checkpoint"
result_already_published=false
if [[ -e "$result_path" || -L "$result_path" ]]; then
    [[ -f "$result_path" && ! -L "$result_path" && -d "$checkpoint" && ! -L "$checkpoint" ]] || \
        fail 'named performance result already exists without a recoverable checkpoint'
    result_already_published=true
fi
if [[ -e "$checkpoint" ]]; then
    [[ -d "$checkpoint" && ! -L "$checkpoint" && -f "$checkpoint/identity.json" && \
       ! -L "$checkpoint/identity.json" ]] || fail 'existing performance checkpoint is unsafe'
    collection_started=$(jq -er '.collection_started | select(type == "string")' \
      "$checkpoint/identity.json") || fail 'existing performance checkpoint has no valid start timestamp'
else
    collection_started=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
fi
metal_llm_validate_benchmark_timestamp "$collection_started" || exit 1

checkpoint_identity=$(jq -cn \
  --arg collection_started "$collection_started" \
  --arg repository_revision "$repository_revision" --arg repository_tree "$repository_tree" \
  --arg collector_sha "$collector_sha" --arg checkpoint_library_sha "$checkpoint_library_sha" \
  --arg hardware_manifest_sha "$hardware_manifest_sha" --arg model_manifest_sha "$model_manifest_sha" \
  --arg runtime_manifest_sha "$runtime_manifest_sha" --arg correctness_sha "$integration_evidence_sha" \
  --arg correctness_harness_sha "$correctness_harness_sha" \
  --arg allocation_evidence_sha "$allocation_evidence_sha" \
  --arg hardware "$hardware_id" --arg chip "$METAL_LLM_DETECTED_CHIP" \
  --argjson memory "$METAL_LLM_DETECTED_MEMORY_BYTES" --argjson system "$system_provenance" \
  --arg runtime "$runtime_id" --arg runtime_revision "$METAL_LLM_VERIFIED_RUNTIME_REVISION" \
  --arg runtime_tree "$METAL_LLM_VERIFIED_RUNTIME_TREE" \
  --arg receipt_sha "$METAL_LLM_VERIFIED_BUILD_RECEIPT_SHA256" \
  --arg executable_sha "$METAL_LLM_VERIFIED_EXECUTABLE_SHA256" \
  --argjson artifacts "$verified_artifacts" '
  {
    schema_version: 1, collection_started: $collection_started,
    repository: {revision: $repository_revision, tree_sha: $repository_tree},
    collector: {
      path: "tests/integration/test_dynamic_mtp_performance.sh", sha256: $collector_sha,
      checkpoint_library_path: "lib/performance-checkpoint.zsh",
      checkpoint_library_sha256: $checkpoint_library_sha
    },
    manifests: {
      hardware_sha256: $hardware_manifest_sha, model_sha256: $model_manifest_sha,
      runtime_sha256: $runtime_manifest_sha
    },
    correctness_evidence_sha256: $correctness_sha,
    correctness_harness_sha256: $correctness_harness_sha,
    accepted_allocation_evidence_sha256: $allocation_evidence_sha,
    hardware: {id: $hardware, chip: $chip, unified_memory_bytes: $memory},
    system: $system,
    runtime: {
      id: $runtime, tested_revision: $runtime_revision, tested_tree_sha: $runtime_tree,
      manifest_sha256: $runtime_manifest_sha, build_receipt_sha256: $receipt_sha,
      executable: {name: "llama-server", sha256: $executable_sha}
    },
    model_manifest_sha256: $model_manifest_sha, artifacts: $artifacts,
    matrix: {
      policies: ["on", "off", "dynamic"],
      effective_prompt_lengths: [29000, 30000, 32767, 32768, 32769, 33868, 98304],
      warmups_per_cell: 1, samples_per_cell: 5
    },
    generation: {
      context: 262144, vision: true, generated_tokens: 128, temperature: 0, seed: 1234,
      reasoning: false, ignore_eos: true, cache_prompt: false, parallel: 1, draft_n_max: 2
    },
    comparison: {
      metric: "generation_tokens_per_second", tolerance_percent: 5, dynamic_threshold: 32768
    }
  }
') || fail 'could not construct immutable performance checkpoint identity'
metal_llm_performance_checkpoint_open "$checkpoint" "$checkpoint_identity" "$root" || \
    fail 'performance checkpoint is not safely resumable'
if [[ "$result_already_published" == true ]]; then
    metal_llm_validate_result "$result_path" 'published dynamic-MTP performance result' || \
        fail 'published result is invalid; preserving its checkpoint'
    checkpoint_identity_sha=$(metal_llm_sha256 "$checkpoint/identity.json")
    jq -e --arg sha "$checkpoint_identity_sha" --arg revision "$repository_revision" \
      --arg tree "$repository_tree" --arg collector "$collector_sha" '
      .configuration.checkpoint_identity_sha256 == $sha and
      .provenance.repository.revision == $revision and .provenance.repository.tree_sha == $tree and
      .provenance.suite.sha256 == $collector and (.runs | length) == 105 and
      (.interpretation.performance_gate_passed | type == "boolean")
    ' "$result_path" >/dev/null || fail 'published result does not match its recoverable checkpoint'
    [[ "$METAL_LLM_PERFORMANCE_CHECKPOINT_RUN_COUNT" == 105 ]] || \
        fail 'published result checkpoint does not retain all 105 samples'
    metal_llm_performance_checkpoint_matches_published_runs "$checkpoint" "$root" "$result_path" || \
        fail 'published result rows differ from the recoverable checkpoint'
    metal_llm_validate_dynamic_mtp_derived_data "$result_path" || \
        fail 'published result gates differ from its retained sample derivation'
    published_performance_passed=$(jq -r '.interpretation.performance_gate_passed' "$result_path")
    retire_published_checkpoint "$checkpoint" || exit 1
    print -- "dynamic-MTP performance: recovered already-published evidence: ${result_path#$root/}"
    [[ "$published_performance_passed" == true ]] || \
        fail 'dynamic route exceeded the predeclared 5% generation-throughput tolerance'
    print -- 'dynamic-MTP performance: PASS'
    exit 0
fi
mkdir -p -- "$checkpoint/logs" "$checkpoint/responses"
assembly=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-dynamic-mtp-assembly.XXXXXX")
run_buffer="$assembly/runs.jsonl"
log_buffer="$assembly/logs.jsonl"
metal_llm_performance_checkpoint_runs "$checkpoint" "$root" > "$run_buffer" || \
    fail 'could not rehydrate retained performance samples'
: > "$log_buffer"
print -- "dynamic-MTP performance: checkpoint resumed=$METAL_LLM_PERFORMANCE_CHECKPOINT_RESUMED retained=$METAL_LLM_PERFORMANCE_CHECKPOINT_RUN_COUNT/105"

lease_dir=$(metal_llm_managed_lease_dir)
[[ ! -e "$lease_dir" && ! -L "$lease_dir" ]] || \
    fail 'managed full-model lease must be absent before performance collection'
if curl -fsS --connect-timeout 1 --max-time 1 "http://$host:$port/health" >/dev/null 2>&1; then
    fail 'configured endpoint is already responding'
fi

scratch=$assembly
responses_dir="$checkpoint/responses"

server_pid=''
server_started=''
server_owner_token=''
launcher_pid=''
launcher_started=''
server_log=''
current_policy=''

process_start_identity() {
    local process_pid=$1 start
    start=$(ps -p "$process_pid" -o lstart= 2>/dev/null) || return 1
    metal_llm_trim_space "$start"
}

stop_if_same_process() {
    local process_pid=$1 recorded_start=$2 current_start
    [[ "$process_pid" == <-> && "$process_pid" -gt 1 && -n "$recorded_start" ]] || return 0
    kill -0 "$process_pid" 2>/dev/null || return 0
    current_start=$(process_start_identity "$process_pid") || return 0
    [[ "$current_start" == "$recorded_start" ]] || return 0
    kill -TERM "$process_pid" 2>/dev/null || true
}

stop_server_exact() {
    local identity_record="$lease_dir/identity.json"
    [[ -n "$server_pid" && -n "$server_started" && -n "$server_owner_token" ]] || \
        fail 'no recorded server identity is available for shutdown'
    [[ -f "$identity_record" && ! -L "$identity_record" ]] || \
        fail 'recorded managed identity disappeared before shutdown'
    jq -e --argjson pid "$server_pid" --arg started "$server_started" \
      --arg token "$server_owner_token" '
      .pid == $pid and .process_started_at == $started and .owner_token == $token
    ' "$identity_record" >/dev/null || fail 'managed identity changed before shutdown'
    metal_llm_managed_identity_is_live "$identity_record" || \
        fail 'recorded managed identity is not live before shutdown'
    stop_if_same_process "$server_pid" "$server_started"
    wait "$server_pid" 2>/dev/null || true
    metal_llm_release_managed_lease "$server_owner_token" || \
        fail 'could not release recorded managed lease'
    [[ ! -e "$identity_record" && ! -e "$lease_dir" ]] || \
        fail 'recorded managed lease remained after shutdown'
    server_pid=''
    server_started=''
    server_owner_token=''
    launcher_pid=''
    launcher_started=''
}

cleanup() {
    local exit_status=$?
    local identity_record="$lease_dir/identity.json" expected_assembly_root assembly_parent
    trap - EXIT HUP INT TERM
    if [[ -n "$server_pid" && -n "$server_started" && -n "$server_owner_token" && \
          -f "$identity_record" && ! -L "$identity_record" ]] &&
       jq -e --argjson pid "$server_pid" --arg started "$server_started" \
         --arg token "$server_owner_token" '
         .pid == $pid and .process_started_at == $started and .owner_token == $token
       ' "$identity_record" >/dev/null 2>&1; then
        stop_if_same_process "$server_pid" "$server_started"
        wait "$server_pid" 2>/dev/null || true
        metal_llm_release_managed_lease "$server_owner_token" || exit_status=1
    elif [[ -n "$launcher_pid" && -n "$launcher_started" ]]; then
        stop_if_same_process "$launcher_pid" "$launcher_started"
        wait "$launcher_pid" 2>/dev/null || true
    fi
    expected_assembly_root=${TMPDIR:-/tmp}
    expected_assembly_root=${expected_assembly_root:A}
    assembly_parent=${assembly:h:A}
    if [[ -d "$assembly" && "$assembly_parent" == "$expected_assembly_root" && \
          "${assembly:t}" == metal-llm-dynamic-mtp-assembly.* ]]; then
        rm -rf -- "$assembly"
    else
        print -u2 -- 'dynamic-MTP performance: refusing to remove an unexpected assembly path'
        exit_status=1
    fi
    if (( exit_status != 0 )); then
        print -u2 -- "dynamic-MTP performance: preserving durable checkpoint diagnostics: ${checkpoint#$root/}"
    fi
    return "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

typeset -a health_arguments post_arguments
health_arguments=(-fsS --connect-timeout 1 --max-time 1)
post_arguments=(-fsS --connect-timeout 5 --max-time 900 -H 'Content-Type: application/json')
[[ -z "${METAL_LLM_API_KEY:-}" ]] || {
    health_arguments+=(-H "Authorization: Bearer $METAL_LLM_API_KEY")
    post_arguments+=(-H "Authorization: Bearer $METAL_LLM_API_KEY")
}

common_runtime_revision=$METAL_LLM_VERIFIED_RUNTIME_REVISION
common_runtime_tree=$METAL_LLM_VERIFIED_RUNTIME_TREE
common_runtime_manifest_sha=$METAL_LLM_VERIFIED_RUNTIME_MANIFEST_SHA256
common_receipt_sha=$METAL_LLM_VERIFIED_BUILD_RECEIPT_SHA256
common_executable_sha=$METAL_LLM_VERIFIED_EXECUTABLE_SHA256
common_artifacts=$verified_artifacts
server_session_id=''

start_policy_server() {
    local policy=$1 identity_record candidate_pid candidate_started candidate_owner_token session_number
    local mtp_threshold_json=null expected_server_artifacts
    [[ "$policy" == dynamic ]] && mtp_threshold_json=$threshold
    session_number=1
    while [[ -e "$checkpoint/logs/$policy-session-$session_number.log" || \
            -L "$checkpoint/logs/$policy-session-$session_number.log" ]]; do
        (( session_number += 1 ))
    done
    server_session_id="$policy-session-$session_number"
    server_log="$checkpoint/logs/$server_session_id.log"
    : > "$server_log" || fail "could not create durable $policy server log"
    command sync
    "$root/bin/metal-llm" serve "$model_id" --profile custom --runtime tuned \
      --mtp "$policy" --context "$context" --vision on > "$server_log" 2>&1 &
    launcher_pid=$!
    launcher_started=$(process_start_identity "$launcher_pid" 2>/dev/null || true)
    [[ -n "$launcher_started" ]] || {
        wait "$launcher_pid" 2>/dev/null || true
        fail "could not record $policy server start identity"
        return 1
    }

    identity_record="$lease_dir/identity.json"
    for attempt in {1..600}; do
        if [[ -f "$identity_record" && ! -L "$identity_record" ]]; then
            metal_llm_validate_managed_identity "$identity_record" || \
                fail "$policy server published an invalid managed identity"
            candidate_pid=$(jq -er '.pid' "$identity_record")
            candidate_started=$(jq -er '.process_started_at' "$identity_record")
            candidate_owner_token=$(jq -er '.owner_token' "$identity_record")
            [[ "$candidate_pid" == "$launcher_pid" && "$candidate_started" == "$launcher_started" ]] || \
                fail "$policy managed identity belongs to another process"
            server_pid=$candidate_pid
            server_started=$candidate_started
            server_owner_token=$candidate_owner_token
            break
        fi
        kill -0 "$launcher_pid" 2>/dev/null || {
            tail -40 "$server_log" >&2 || true
            fail "$policy server exited before publishing its managed identity"
            return 1
        }
        sleep 1
    done
    [[ -n "$server_pid" ]] || fail "timed out waiting for $policy managed server identity"
    metal_llm_managed_identity_is_live "$identity_record" || fail "$policy managed identity is not live"
    jq -e --arg policy "$policy" --argjson threshold "$mtp_threshold_json" \
      --arg runtime "$runtime_id" --argjson context "$context" '
      .owner_kind == "serve" and .model_id == "qwen3.8-flash-next" and
      .profile_id == "custom" and .runtime_alias == "tuned" and .runtime_id == $runtime and
      .context == $context and .vision == true and .mtp_policy == $policy and
      .mtp_threshold == $threshold and .host == "127.0.0.1" and .port == 8080 and
      .executable_name == "llama-server"
    ' "$identity_record" >/dev/null || fail "$policy managed identity does not match the measurement configuration"

    for attempt in {1..600}; do
        if curl "${health_arguments[@]}" "http://$host:$port/health" >/dev/null 2>&1; then
            break
        fi
        metal_llm_managed_identity_is_live "$identity_record" || fail "$policy server exited while waiting for health"
        sleep 1
    done
    curl "${health_arguments[@]}" "http://$host:$port/health" >/dev/null 2>&1 || \
        fail "timed out waiting for $policy server health"

    expected_server_artifacts=$(metal_llm_performance_policy_artifacts \
      "$policy" "$common_artifacts" "$mtp_artifact_id") || \
        fail "$policy expected artifact identity could not be derived"
    jq -e --arg revision "$common_runtime_revision" --arg tree "$common_runtime_tree" \
      --arg manifest "$common_runtime_manifest_sha" --arg receipt "$common_receipt_sha" \
      --arg executable "$common_executable_sha" --arg model_manifest "$model_manifest_sha" \
      --argjson artifacts "$expected_server_artifacts" '
      .runtime_revision == $revision and .runtime_tree_sha == $tree and
      .runtime_manifest_sha256 == $manifest and .build_receipt_sha256 == $receipt and
      .executable_sha256 == $executable and .model_manifest_sha256 == $model_manifest and
      .artifacts == $artifacts
    ' "$identity_record" >/dev/null || fail "$policy server changed immutable runtime or artifact provenance"
    current_policy=$policy
    print -- "dynamic-MTP performance: server healthy policy=$policy pid=$server_pid"
}

completion_payload() {
    local token=$1 token_count=$2
    jq -cn --argjson token "$token" --argjson count "$token_count" \
      --argjson predict "$generated_tokens" '
      {prompt: [range(0; $count) | $token], n_predict: $predict, temperature: 0, seed: 1234,
       ignore_eos: true, cache_prompt: false, id_slot: 0, stream: false}
    '
}

record_request() {
    local policy=$1 effective_target=$2 filler_token=$3 completion_offset=$4 sample=$5 kind=$6
    local array_count payload payload_sha case_id response response_path response_part response_sha timing
    local selected expected_selected effective generated prompt_speed generation_speed draft accepted output_sha
    local threshold_json=null timestamp notes run_json envelope
    array_count=$(( effective_target - completion_offset ))
    (( array_count > 0 )) || fail 'calibrated prompt array length is invalid'
    payload=$(completion_payload "$filler_token" "$array_count") || return 1
    payload_sha=$(print -rn -- "$payload" | shasum -a 256 | awk '{print $1}') || return 1
    if [[ "$kind" == warmup ]]; then
        case_id="warmup-$policy-$effective_target"
    else
        case_id="$policy-$effective_target-s$sample"
    fi
    response=$(curl "${post_arguments[@]}" -d "$payload" "http://$host:$port/completion") || \
        fail "$case_id request failed"
    response_path="$responses_dir/$server_session_id-$case_id.response"
    [[ ! -e "$response_path" && ! -L "$response_path" ]] || \
        fail "$case_id durable response path already exists"
    response_part=$(mktemp "$responses_dir/.part.XXXXXX") || \
        fail "$case_id durable response part could not be created"
    print -rn -- "$response" > "$response_part" || fail "$case_id response could not be preserved"
    command sync
    mv -- "$response_part" "$response_path" || fail "$case_id response could not be published"
    command sync
    response_sha=$(metal_llm_sha256 "$response_path") || fail "$case_id response could not be hashed"
    timing=$(jq -ce '.timings | select(type == "object")' "$response_path") || \
        fail "$case_id response has no timing object; response-sha256=$response_sha"
    [[ "$policy" == dynamic ]] && threshold_json=$threshold
    metal_llm_validate_endpoint_timing "$timing" "$policy" "$threshold_json" api 1024 || \
        fail "$case_id timing metadata does not match policy; response-sha256=$response_sha"
    selected=$(metal_llm_extract_speculative_route "$timing") || \
        fail "$case_id has no boolean route; response-sha256=$response_sha"
    if [[ "$policy" == on ]]; then
        expected_selected=true
    elif [[ "$policy" == off ]]; then
        expected_selected=false
    elif (( effective_target <= threshold )); then
        expected_selected=true
    else
        expected_selected=false
    fi
    [[ "$selected" == "$expected_selected" ]] || \
        fail "$case_id selected route $selected, expected $expected_selected"
    effective=$(jq -er '.effective_prompt_tokens | select(type == "number" and floor == .)' <<< "$timing") || \
        fail "$case_id has no integer effective prompt count"
    [[ "$effective" == "$effective_target" ]] || \
        fail "$case_id reported $effective effective tokens, expected $effective_target"
    generated=$(jq -er '.predicted_n | select(type == "number" and floor == .)' <<< "$timing") || \
        fail "$case_id has no integer generated-token count"
    [[ "$generated" == "$generated_tokens" ]] || \
        fail "$case_id generated $generated tokens, expected $generated_tokens"
    prompt_speed=$(jq -er '.prompt_per_second | select(type == "number" and . > 0)' <<< "$timing") || \
        fail "$case_id has no positive prompt throughput"
    generation_speed=$(jq -er '.predicted_per_second | select(type == "number" and . > 0)' <<< "$timing") || \
        fail "$case_id has no positive generation throughput"
    if [[ "$selected" == true ]]; then
        metal_llm_validate_speculative_draft_statistics "$timing" || \
            fail "$case_id lacks valid speculative draft statistics"
        draft=$(jq -er '.draft_n' <<< "$timing")
        accepted=$(jq -er '.draft_n_accepted' <<< "$timing")
    else
        jq -e '((.draft_n // 0) == 0) and ((.draft_n_accepted // 0) == 0)' \
          <<< "$timing" >/dev/null || fail "$case_id collected draft statistics while MTP was off"
        draft=0
        accepted=0
    fi
    output_sha=$(jq -ce '.content | select(type == "string")' "$response_path" | \
      shasum -a 256 | awk '{print $1}') || fail "$case_id output could not be hashed"
    if [[ "$kind" == warmup ]]; then
        print -- "dynamic-MTP performance: warmup policy=$policy effective=$effective route=$selected"
        return 0
    fi
    timestamp=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
    notes="Measured sample $sample of $samples_per_cell after $warmups_per_cell warm-up; response SHA-256 $response_sha."
    run_json=$(jq -cn \
      --arg id "$case_id" --arg timestamp "$timestamp" --arg repository "$repository_revision" \
      --arg hardware "$hardware_id" --arg runtime "$runtime_id" \
      --arg runtime_revision "$common_runtime_revision" --arg policy "$policy" \
      --argjson selected "$selected" --argjson threshold "$threshold_json" \
      --argjson prompt "$array_count" --argjson effective "$effective" \
      --argjson generated "$generated" --argjson prompt_speed "$prompt_speed" \
      --argjson generation_speed "$generation_speed" --arg output_sha "$output_sha" \
      --argjson draft "$draft" --argjson accepted "$accepted" --arg payload_sha "$payload_sha" \
      --arg notes "$notes" '
      {
        id: $id, experiment: "dynamic-mtp-performance", measurement_kind: "single_run",
        timestamp: $timestamp, repository_revision: $repository,
        hardware_id: $hardware, runtime_id: $runtime, runtime_revision: $runtime_revision,
        profile: null, profile_id: "custom", runtime_alias: "tuned", context: 262144,
        vision: true, mtp_policy: $policy, mtp_selected: $selected, mtp_threshold: $threshold,
        prompt_tokens: $prompt, effective_prompt_tokens: $effective, generated_tokens: $generated,
        prompt_tokens_per_second: $prompt_speed,
        generation_tokens_per_second: $generation_speed,
        output_sha256: $output_sha,
        draft_acceptance: (($accepted | tostring) + "/" + ($draft | tostring)),
        command: ["curl", "POST", "/completion", ("payload-sha256:" + $payload_sha)],
        generation_settings: {
          temperature: 0, seed: 1234, max_tokens: 128, reasoning: false, draft_n_max: 2
        },
        notes: $notes
      }
    ') || fail "$case_id sample could not be assembled"
    envelope=$(jq -cn --arg session "$server_session_id" --argjson run "$run_json" \
      '{schema_version: 1, server_session_id: $session, run: $run}') || \
        fail "$case_id checkpoint envelope could not be assembled"
    metal_llm_performance_checkpoint_publish_run "$checkpoint" "$envelope" "$root" || \
        fail "$case_id sample could not be atomically retained"
    jq -c --arg session "$server_session_id" '. + {server_session_id: $session}' \
      <<< "$run_json" >> "$run_buffer" || fail "$case_id assembly buffer could not be updated"
    print -- "dynamic-MTP performance: sample policy=$policy effective=$effective sample=$sample/$samples_per_cell route=$selected generation=$generation_speed"
}

for policy in "${policies[@]}"; do
    policy_missing=0
    for effective_target in "${effective_lengths[@]}"; do
        for sample in {1..5}; do
            [[ -e "$checkpoint/runs/$policy-$effective_target-s$sample.json" ]] || \
                (( policy_missing += 1 ))
        done
    done
    if (( policy_missing == 0 )); then
        print -- "dynamic-MTP performance: policy=$policy already complete; no server launch"
        continue
    fi
    start_policy_server "$policy" || exit 1
    tokenize_payload=$(jq -cn '{content: " x", add_special: false}')
    tokenize_response=$(curl "${post_arguments[@]}" -d "$tokenize_payload" "http://$host:$port/tokenize") || \
        fail "$policy tokenizer probe failed"
    filler_token=$(jq -er '.tokens | select(type == "array" and length > 0) | last |
      select(type == "number" and floor == . and . >= 0)' <<< "$tokenize_response") || \
        fail "$policy tokenizer did not return a usable filler token"
    calibration_payload=$(completion_payload "$filler_token" 32)
    calibration_response=$(curl "${post_arguments[@]}" -d "$calibration_payload" \
      "http://$host:$port/completion") || fail "$policy offset calibration failed"
    calibration_path="$responses_dir/$server_session_id-calibration-$policy.response"
    [[ ! -e "$calibration_path" && ! -L "$calibration_path" ]] || \
        fail "$policy durable calibration response already exists"
    print -rn -- "$calibration_response" > "$calibration_path"
    command sync
    calibration_timing=$(jq -ce '.timings | select(type == "object")' "$calibration_path") || \
        fail "$policy offset calibration has no timing object"
    metal_llm_validate_endpoint_timing "$calibration_timing" "$policy" \
      "$([[ "$policy" == dynamic ]] && print $threshold || print null)" api 1024 || \
        fail "$policy offset calibration route is invalid"
    calibration_effective=$(jq -er '.effective_prompt_tokens' <<< "$calibration_timing")
    completion_offset=$(( calibration_effective - 32 ))
    (( completion_offset >= 0 && completion_offset < 64 )) || \
        fail "$policy completion offset is outside the safe range"

    for effective_target in "${effective_lengths[@]}"; do
        retained_in_cell=0
        for sample in {1..5}; do
            [[ ! -e "$checkpoint/runs/$policy-$effective_target-s$sample.json" ]] || \
                (( retained_in_cell += 1 ))
        done
        if (( retained_in_cell == samples_per_cell )); then
            print -- "dynamic-MTP performance: cell policy=$policy effective=$effective_target already complete"
            continue
        fi
        if (( retained_in_cell == 0 )); then
            record_request "$policy" "$effective_target" "$filler_token" "$completion_offset" 0 warmup || exit 1
        else
            print -- "dynamic-MTP performance: resuming cell policy=$policy effective=$effective_target retained=$retained_in_cell/5 without repeating its completed warm-up"
        fi
        for sample in {1..5}; do
            if [[ -e "$checkpoint/runs/$policy-$effective_target-s$sample.json" ]]; then
                print -- "dynamic-MTP performance: retaining existing sample policy=$policy effective=$effective_target sample=$sample/5"
                continue
            fi
            record_request "$policy" "$effective_target" "$filler_token" "$completion_offset" "$sample" sample || exit 1
        done
    done
    stop_server_exact || exit 1
    server_log_sha=$(metal_llm_sha256 "$server_log")
    command sync
    print -- "dynamic-MTP performance: server stopped policy=$policy session=$server_session_id log-sha256=$server_log_sha"
done

expected_run_count=$(( ${#policies[@]} * ${#effective_lengths[@]} * samples_per_cell ))
metal_llm_performance_checkpoint_open "$checkpoint" "$checkpoint_identity" "$root" || \
    fail 'completed checkpoint failed final strict validation'
[[ "$METAL_LLM_PERFORMANCE_CHECKPOINT_RUN_COUNT" == "$expected_run_count" ]] || \
    fail "checkpoint retains $METAL_LLM_PERFORMANCE_CHECKPOINT_RUN_COUNT samples, expected $expected_run_count"
run_buffer_part=$(mktemp "$assembly/runs.jsonl.part.XXXXXX")
metal_llm_performance_checkpoint_runs "$checkpoint" "$root" > "$run_buffer_part" || \
    fail 'could not rehydrate the final retained sample set'
mv -- "$run_buffer_part" "$run_buffer"
actual_run_count=$(wc -l < "$run_buffer" | tr -d ' ')
[[ "$actual_run_count" == "$expected_run_count" ]] || \
    fail "recorded $actual_run_count samples, expected $expected_run_count"

statistics=$(jq -s '
  def mean: add / length;
  def sample_sd:
    . as $values | ($values | mean) as $mean |
    (($values | map((. - $mean) * (. - $mean)) | add) / ($values | length - 1)) | sqrt;
  sort_by(.mtp_policy, .effective_prompt_tokens) |
  group_by([.mtp_policy, .effective_prompt_tokens]) |
  map(
    . as $runs |
    ($runs | map(.prompt_tokens_per_second)) as $prompt_samples |
    ($runs | map(.generation_tokens_per_second)) as $generation_samples |
    {
      policy: $runs[0].mtp_policy,
      effective_prompt_tokens: $runs[0].effective_prompt_tokens,
      selected_route: $runs[0].mtp_selected,
      sample_count: ($runs | length),
      prompt_tokens_per_second_samples: $prompt_samples,
      prompt_tokens_per_second_mean: ($prompt_samples | mean),
      prompt_tokens_per_second_sample_sd: ($prompt_samples | sample_sd),
      generation_tokens_per_second_samples: $generation_samples,
      generation_tokens_per_second_mean: ($generation_samples | mean),
      generation_tokens_per_second_sample_sd: ($generation_samples | sample_sd),
      draft_accepted: ($runs | map(.draft_acceptance | split("/")[0] | tonumber) | add),
      draft_generated: ($runs | map(.draft_acceptance | split("/")[1] | tonumber) | add),
      output_sha256: ($runs | map(.output_sha256)),
      distinct_output_count: ($runs | map(.output_sha256) | unique | length)
    }
  )
' "$run_buffer") || fail 'could not derive sample statistics'
jq -e --argjson count "$samples_per_cell" \
  'length == 21 and all(.[]; .sample_count == $count)' <<< "$statistics" >/dev/null || \
    fail 'derived statistics do not cover every five-sample cell'

comparisons=$(jq -cn --argjson statistics "$statistics" --argjson threshold "$threshold" \
  --argjson tolerance "$throughput_tolerance_percent" '
  [$statistics[] | select(.policy == "dynamic") as $dynamic |
    (if $dynamic.effective_prompt_tokens <= $threshold then "on" else "off" end) as $fixed_policy |
    ($statistics[] | select(.policy == $fixed_policy and
      .effective_prompt_tokens == $dynamic.effective_prompt_tokens)) as $fixed |
    (((($dynamic.generation_tokens_per_second_mean /
         $fixed.generation_tokens_per_second_mean) - 1) * 100)) as $delta |
    {
      effective_prompt_tokens: $dynamic.effective_prompt_tokens,
      dynamic_selected_route: $dynamic.selected_route,
      fixed_policy: $fixed_policy,
      dynamic_generation_tokens_per_second_mean: $dynamic.generation_tokens_per_second_mean,
      fixed_generation_tokens_per_second_mean: $fixed.generation_tokens_per_second_mean,
      percent_delta: $delta,
      tolerance_percent: $tolerance,
      passed: (($delta | fabs) <= $tolerance)
    }
  ]
') || fail 'could not derive dynamic-to-fixed comparisons'
performance_passed=$(jq -r 'all(.[]; .passed)' <<< "$comparisons")

collection_completed=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
for server_log in "$checkpoint/logs"/*.log(N); do
    server_log_name=${server_log:t:r}
    server_log_policy=${server_log_name%%-session-*}
    server_log_sha=$(metal_llm_sha256 "$server_log") || fail 'durable server log could not be hashed'
    jq -cn --arg policy "$server_log_policy" --arg session "$server_log_name" \
      --arg sha "$server_log_sha" \
      '{policy: $policy, session_id: $session, sha256: $sha}' >> "$log_buffer" || \
        fail 'server log identity could not be recorded'
done
server_logs=$(jq -s 'sort_by(.policy, .session_id)' "$log_buffer")
[[ "$(jq -r 'length' <<< "$server_logs")" -ge 3 ]] || \
    fail 'fewer than three durable server logs were retained'
checkpoint_identity_sha=$(metal_llm_sha256 "$checkpoint/identity.json")
result_part=$(mktemp "$result_path.part.XXXXXX")
jq -s \
  --arg experiment "${collection_started//[-:]/}-dynamic-mtp-performance" \
  --arg date "${collection_started[1,10]}" --arg model "$model_id" --arg suite "$suite_id" \
  --arg repository_revision "$repository_revision" --arg repository_tree "$repository_tree" \
  --arg hardware "$hardware_id" --arg chip "$METAL_LLM_DETECTED_CHIP" \
  --argjson memory "$METAL_LLM_DETECTED_MEMORY_BYTES" --argjson system "$system_provenance" \
  --arg runtime "$runtime_id" --arg runtime_revision "$common_runtime_revision" \
  --arg runtime_tree "$common_runtime_tree" --arg runtime_manifest_sha "$common_runtime_manifest_sha" \
  --arg receipt_sha "$common_receipt_sha" --arg executable_sha "$common_executable_sha" \
  --arg model_manifest_sha "$model_manifest_sha" --argjson artifacts "$common_artifacts" \
  --arg collector_sha "$collector_sha" --arg integration_sha "$integration_evidence_sha" \
  --arg correctness_harness_sha "$correctness_harness_sha" \
  --arg allocation_evidence_sha "$allocation_evidence_sha" \
  --argjson allocation_observation "$allocation_observation" \
  --arg checkpoint_identity_sha "$checkpoint_identity_sha" \
  --arg collection_started "$collection_started" --arg collection_completed "$collection_completed" \
  --argjson lengths "$(printf '%s\n' "${effective_lengths[@]}" | jq -s 'map(tonumber)')" \
  --argjson statistics "$statistics" --argjson comparisons "$comparisons" \
  --argjson performance_passed "$performance_passed" --argjson server_logs "$server_logs" '
  {
    schema_version: 1,
    experiment_id: ($experiment | ascii_downcase),
    date: $date,
    model_id: $model,
    suite_id: $suite,
    benchmark_mode: "endpoint",
    summary: {
      output: "qwen3.8-flash-next-dynamic-mtp.md",
      title: "Qwen3.8 Flash Next dynamic-MTP acceptance on Apple M5 Max"
    },
    provenance: {
      repository: {revision: $repository_revision, tree_sha: $repository_tree, clean: true},
      hardware: {id: $hardware, chip: $chip, unified_memory_bytes: $memory},
      system: $system,
      profile_id: "custom", runtime_alias: "tuned", context: 262144, vision: true,
      mtp_policy: null, mtp_threshold: null,
      runtime: {
        id: $runtime, tested_revision: $runtime_revision, tested_tree_sha: $runtime_tree,
        manifest_sha256: $runtime_manifest_sha, build_receipt_sha256: $receipt_sha,
        executable: {name: "llama-server", sha256: $executable_sha}
      },
      model_manifest_sha256: $model_manifest_sha,
      artifacts: $artifacts,
      suite: {id: $suite, sha256: $collector_sha, fixtures: []}
    },
    configuration: {
      acceptance_variant: "multi-policy-endpoint",
      mtp_policies: ["on", "off", "dynamic"],
      dynamic_threshold: 32768,
      context_allocation: 262144,
      vision: true,
      effective_prompt_lengths: $lengths,
      warmups_per_cell: 1,
      samples_per_cell: 5,
      throughput_tolerance_percent: 5,
      comparison_metric: "generation_tokens_per_second",
      generation_settings: {
        temperature: 0, seed: 1234, max_tokens: 128, reasoning: false,
        ignore_eos: true, cache_prompt: false, parallel: 1, draft_n_max: 2
      },
      collection_started: $collection_started,
      collection_completed: $collection_completed,
      checkpoint_identity_sha256: $checkpoint_identity_sha,
      correctness_evidence_sha256: $integration_sha,
      correctness_harness_sha256: $correctness_harness_sha,
      accepted_allocation_observation: {
        evidence_sha256: $allocation_evidence_sha,
        observation: $allocation_observation
      },
      server_log_sha256: $server_logs,
      statistics: $statistics,
      dynamic_fixed_comparisons: $comparisons
    },
    interpretation: {
      performance_gate_passed: $performance_passed,
      limitation: "Machine-specific local measurements; output hashes are retained and no behavioral equivalence is inferred."
    },
    validations: [
      {check: "Dynamic-MTP correctness and isolation", result: ("Pass; staged evidence SHA-256 " + $integration_sha)},
      {check: "Accepted default 262,144-token allocation memory observation",
       result: "Pass; sanitized RSS and system memory pressure captured"},
      {check: "Complete 21-cell performance matrix", result: "Pass; one warm-up and five measured samples per cell"},
      {check: "Dynamic-to-corresponding-fixed 5% generation-throughput tolerance",
       result: (if $performance_passed then "Pass" else "Fail" end)}
    ],
    runs: .
  }
' "$run_buffer" > "$result_part" || {
    rm -f -- "$result_part"
    fail 'could not assemble combined performance result'
}

metal_llm_validate_result "$result_part" 'pending dynamic-MTP performance result' || {
    rm -f -- "$result_part"
    fail 'combined performance evidence failed schema/privacy/route validation'
}
metal_llm_performance_checkpoint_matches_published_runs "$checkpoint" "$root" "$result_part" || {
    rm -f -- "$result_part"
    fail 'assembled result rows differ from the completed checkpoint'
}
metal_llm_publish_benchmark_result "$result_part" "$result_path" || exit 1
metal_llm_performance_checkpoint_matches_published_runs "$checkpoint" "$root" "$result_path" || \
    fail 'published result rows differ from the completed checkpoint; preserving checkpoint'
metal_llm_validate_dynamic_mtp_derived_data "$result_path" || \
    fail 'published result gates differ from retained samples; preserving checkpoint'
retire_published_checkpoint "$checkpoint" || exit 1
print -- "dynamic-MTP performance: wrote validated evidence: ${result_path#$root/}"
if [[ "$performance_passed" != true ]]; then
    fail 'dynamic route exceeded the predeclared 5% generation-throughput tolerance'
fi
print -- 'dynamic-MTP performance: PASS'
