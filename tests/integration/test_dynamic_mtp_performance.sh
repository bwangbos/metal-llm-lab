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
source "$root/lib/runtime-state.zsh"
source "$root/lib/managed-process.zsh"
source "$root/lib/bench.zsh"
source "$root/lib/report.zsh"
source "$root/tests/integration/dynamic_mtp_helpers.zsh"

fail() {
    print -u2 -- "dynamic-MTP performance: $1"
    return 1
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
    local statistics selected
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
    print -- 'dynamic-MTP performance self-test: PASS'
}

if (( $# == 1 )) && [[ "$1" == --self-test ]]; then
    metal_llm_performance_self_test
    exit
elif (( $# != 0 )); then
    print -u2 -- 'usage: METAL_LLM_PERFORMANCE=1 zsh tests/integration/test_dynamic_mtp_performance.sh [--self-test]'
    exit 2
fi

for required_command in git jq curl shasum system_profiler uname ps awk; do
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
collector_path="$root/tests/integration/test_dynamic_mtp_performance.sh"
integration_evidence="$root/.lab/task6-evidence/integration-acceptance.json"
[[ -f "$model_manifest" && -f "$runtime_manifest" ]] || fail 'required manifests are missing'
[[ -f "$integration_evidence" && ! -L "$integration_evidence" ]] || \
    fail 'validated correctness evidence is required before performance collection'
metal_llm_validate_model_manifest "$model_manifest" "$model_id" || fail 'model manifest is invalid'
metal_llm_validate_runtime_manifest "$runtime_manifest" "$runtime_id" || fail 'runtime manifest is invalid'
metal_llm_validate_result "$integration_evidence" 'staged dynamic-MTP correctness evidence' || \
    fail 'staged correctness evidence is invalid'
jq -e '
  .model_id == "qwen3.8-flash-next" and .suite_id == "dynamic-mtp-acceptance" and
  .benchmark_mode == "endpoint" and .provenance.repository.clean == true and
  (.runs | length) == 19 and
  ([.runs[].id] | index("boundary-32767") != null and index("boundary-32768") != null and
    index("boundary-32769") != null and index("concurrent-short") != null and
    index("concurrent-long") != null and index("vision-cross-expanded") != null)
' "$integration_evidence" >/dev/null || fail 'staged correctness evidence is incomplete'

collector_sha=$(metal_llm_sha256 "$collector_path")
integration_evidence_sha=$(metal_llm_sha256 "$integration_evidence")
model_manifest_sha=$(metal_llm_sha256 "$model_manifest")
system_provenance=$(metal_llm_benchmark_system_provenance)
collection_started=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
metal_llm_validate_benchmark_timestamp "$collection_started" || exit 1

result_dir="$root/results/raw"
result_path="$result_dir/2026-09-03-qwen38-dynamic-mtp.json"
[[ ! -e "$result_path" && ! -L "$result_path" ]] || fail 'named performance result already exists'
lease_dir=$(metal_llm_managed_lease_dir)
[[ ! -e "$lease_dir" && ! -L "$lease_dir" ]] || \
    fail 'managed full-model lease must be absent before performance collection'
if curl -fsS --connect-timeout 1 --max-time 1 "http://$host:$port/health" >/dev/null 2>&1; then
    fail 'configured endpoint is already responding'
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-dynamic-mtp-performance.XXXXXX")
run_buffer="$scratch/runs.jsonl"
log_buffer="$scratch/logs.jsonl"
responses_dir="$scratch/responses"
mkdir -- "$responses_dir"
: > "$run_buffer"
: > "$log_buffer"

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
    local identity_record="$lease_dir/identity.json" expected_scratch_root scratch_parent
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
    expected_scratch_root=${TMPDIR:-/tmp}
    expected_scratch_root=${expected_scratch_root:A}
    scratch_parent=${scratch:h:A}
    if (( exit_status != 0 )); then
        print -u2 -- "dynamic-MTP performance: preserving failure diagnostics: ${scratch:t}"
    elif [[ -d "$scratch" && "$scratch_parent" == "$expected_scratch_root" && \
            "${scratch:t}" == metal-llm-dynamic-mtp-performance.* ]]; then
        rm -rf -- "$scratch"
    else
        print -u2 -- 'dynamic-MTP performance: refusing to remove an unexpected scratch path'
        exit_status=1
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

common_runtime_revision=''
common_runtime_tree=''
common_runtime_manifest_sha=''
common_receipt_sha=''
common_executable_sha=''
common_artifacts=''

start_policy_server() {
    local policy=$1 identity_record candidate_pid candidate_started candidate_owner_token
    local mtp_threshold_json=null
    [[ "$policy" == dynamic ]] && mtp_threshold_json=$threshold
    server_log="$scratch/server-$policy.log"
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

    if [[ -z "$common_runtime_revision" ]]; then
        common_runtime_revision=$(jq -er '.runtime_revision' "$identity_record")
        common_runtime_tree=$(jq -er '.runtime_tree_sha' "$identity_record")
        common_runtime_manifest_sha=$(jq -er '.runtime_manifest_sha256' "$identity_record")
        common_receipt_sha=$(jq -er '.build_receipt_sha256' "$identity_record")
        common_executable_sha=$(jq -er '.executable_sha256' "$identity_record")
        common_artifacts=$(jq -c '.artifacts' "$identity_record")
    else
        jq -e --arg revision "$common_runtime_revision" --arg tree "$common_runtime_tree" \
          --arg manifest "$common_runtime_manifest_sha" --arg receipt "$common_receipt_sha" \
          --arg executable "$common_executable_sha" '
          .runtime_revision == $revision and .runtime_tree_sha == $tree and
          .runtime_manifest_sha256 == $manifest and .build_receipt_sha256 == $receipt and
          .executable_sha256 == $executable
        ' "$identity_record" >/dev/null || fail "$policy server changed immutable runtime provenance"
    fi
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
    local array_count payload payload_sha case_id response response_path response_sha timing
    local selected expected_selected effective generated prompt_speed generation_speed draft accepted output_sha
    local threshold_json=null timestamp notes
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
    response_path="$responses_dir/$case_id.response"
    print -rn -- "$response" > "$response_path" || fail "$case_id response could not be preserved"
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
    jq -cn \
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
    ' >> "$run_buffer" || fail "$case_id sample could not be recorded"
    print -- "dynamic-MTP performance: sample policy=$policy effective=$effective sample=$sample/$samples_per_cell route=$selected generation=$generation_speed"
}

for policy in "${policies[@]}"; do
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
    calibration_path="$responses_dir/calibration-$policy.response"
    print -rn -- "$calibration_response" > "$calibration_path"
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
        record_request "$policy" "$effective_target" "$filler_token" "$completion_offset" 0 warmup || exit 1
        for sample in {1..5}; do
            record_request "$policy" "$effective_target" "$filler_token" "$completion_offset" "$sample" sample || exit 1
        done
    done
    stop_server_exact || exit 1
    server_log_sha=$(metal_llm_sha256 "$server_log")
    jq -cn --arg policy "$policy" --arg sha "$server_log_sha" \
      '{policy: $policy, sha256: $sha}' >> "$log_buffer"
    print -- "dynamic-MTP performance: server stopped policy=$policy"
done

expected_run_count=$(( ${#policies[@]} * ${#effective_lengths[@]} * samples_per_cell ))
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
server_logs=$(jq -s 'sort_by(.policy)' "$log_buffer")
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
      correctness_evidence_sha256: $integration_sha,
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
metal_llm_publish_benchmark_result "$result_part" "$result_path" || exit 1
print -- "dynamic-MTP performance: wrote validated evidence: ${result_path#$root/}"
if [[ "$performance_passed" != true ]]; then
    fail 'dynamic route exceeded the predeclared 5% generation-throughput tolerance'
fi
print -- 'dynamic-MTP performance: PASS'
