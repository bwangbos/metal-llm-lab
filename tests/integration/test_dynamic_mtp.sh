#!/bin/zsh
set -euo pipefail
setopt extended_glob
unsetopt bg_nice

root=${0:A:h:h:h}
METAL_LLM_ROOT=$root
export METAL_LLM_ROOT

if [[ "${METAL_LLM_INTEGRATION:-0}" != 1 ]]; then
    print -- 'SKIP: dynamic-MTP integration requires METAL_LLM_INTEGRATION=1'
    exit 0
fi

source "$root/lib/common.zsh"
source "$root/lib/profile.zsh"
source "$root/lib/setup.zsh"
source "$root/lib/runtime-state.zsh"
source "$root/lib/managed-process.zsh"
source "$root/lib/bench.zsh"
source "$root/lib/report.zsh"
source "$root/tests/integration/dynamic_mtp_helpers.zsh"

fail() {
    print -u2 -- "dynamic-MTP integration: $1"
    return 1
}

for required_command in git jq curl shasum system_profiler uname ps awk base64; do
    command -v "$required_command" >/dev/null 2>&1 || fail "missing required command: $required_command"
done
metal_llm_require_supported_host || exit 1

model_id=qwen3.8-flash-next
hardware_id=apple-m5-max-128gb
runtime_id=llama-cpp-qwen38-hybrid
suite_id=dynamic-mtp-acceptance
threshold=32768
context=262144
host=${METAL_LLM_HOST:-127.0.0.1}
port=${METAL_LLM_PORT:-8080}
parallel=${METAL_LLM_PARALLEL:-2}
[[ "$host" == 127.0.0.1 ]] || fail 'METAL_LLM_HOST must be 127.0.0.1'
[[ "$port" == <-> && "$port" -ge 1 && "$port" -le 65535 ]] || fail 'METAL_LLM_PORT must be an integer from 1 to 65535'
[[ "$parallel" == 2 ]] || fail 'METAL_LLM_PARALLEL must be 2 for opposite-route concurrency coverage'
export METAL_LLM_HOST=$host METAL_LLM_PORT=$port METAL_LLM_PARALLEL=2

[[ -z "${METAL_LLM_HARDWARE_ID:-}" ]] || fail 'METAL_LLM_HARDWARE_ID overrides are forbidden'
[[ -z "${METAL_LLM_REPOSITORY_REVISION:-}" ]] || fail 'repository revision overrides are forbidden'
[[ -z "${METAL_LLM_NOW:-}" ]] || fail 'timestamp overrides are forbidden'

repository_status=$(git -C "$root" status --porcelain=v1 --untracked-files=all) || exit 1
[[ -z "$repository_status" ]] || fail 'repository checkout must be clean before integration'
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
[[ -f "$model_manifest" && -f "$runtime_manifest" && -f "$hardware_manifest" ]] || \
    fail 'required manifests are missing'
metal_llm_validate_model_manifest "$model_manifest" "$model_id" || fail 'model manifest is invalid'
metal_llm_validate_runtime_manifest "$runtime_manifest" "$runtime_id" || fail 'runtime manifest is invalid'
jq -e '
  .schema_version == 2 and .id == "apple-m5-max-128gb" and
  .chip == "Apple M5 Max" and .architecture == "arm64" and
  .unified_memory_bytes == 137438953472
' "$hardware_manifest" >/dev/null || fail 'hardware manifest no longer describes the accepted exact machine'

metal_llm_resolve_profile "$model_manifest" auto on '' '' '' || fail 'auto profile did not resolve'
effective_profile=$METAL_LLM_EFFECTIVE_PROFILE
jq -e --arg runtime "$runtime_id" --argjson threshold "$threshold" --argjson context "$context" '
  .profile_id == "auto" and .runtime_alias == "tuned" and .runtime_id == $runtime and
  .context == $context and .vision.enabled == true and
  .mtp.policy == "dynamic" and .mtp.threshold == $threshold
' <<< "$effective_profile" >/dev/null || fail 'auto no longer resolves to the acceptance configuration'

# These checks are read-only. The harness never invokes setup, runtime-sync,
# cmake, ninja, a package manager, or any network download.
metal_llm_verify_runtime_build "$runtime_id" "$runtime_manifest" llama-server || \
    fail 'verified tuned build and receipt are required'
artifact_dir="$root/.lab/artifacts/$model_id"
metal_llm_profile_artifact_identities "$model_manifest" "$artifact_dir" "$effective_profile" || \
    fail 'all auto artifacts must already exist and match their manifest checksums'
verified_artifacts=$METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES

fixture_relative=benchmarks/fixtures/vision-spatial.png
metal_llm_validate_vision_fixture "$fixture_relative" || fail 'tracked vision fixture is invalid'
fixture_path=$METAL_LLM_VERIFIED_FIXTURE_PATH
fixture_sha=$METAL_LLM_VERIFIED_FIXTURE_SHA256
fixture_mime=$METAL_LLM_VERIFIED_FIXTURE_MIME

lease_dir=$(metal_llm_managed_lease_dir)
[[ ! -e "$lease_dir" && ! -L "$lease_dir" ]] || \
    fail 'managed full-model lease must be absent; this harness does not recover or replace it'

typeset -a health_arguments
health_arguments=(-fsS --connect-timeout 1 --max-time 1)
[[ -z "${METAL_LLM_API_KEY:-}" ]] || health_arguments+=(-H "Authorization: Bearer $METAL_LLM_API_KEY")
if curl "${health_arguments[@]}" "http://$host:$port/health" >/dev/null 2>&1; then
    fail 'configured endpoint is already responding; stop it before integration'
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-dynamic-mtp.XXXXXX")
run_buffer="$scratch/runs.jsonl"
server_log="$scratch/server.log"
responses_dir="$scratch/responses"
mkdir -- "$responses_dir"
: > "$run_buffer"

server_pid=''
server_started=''
server_owner_token=''
launcher_pid=''
launcher_started=''
second_pid=''
second_started=''

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

cleanup() {
    local exit_status=$?
    local expected_scratch_root scratch_parent
    trap - EXIT HUP INT TERM
    [[ -z "$second_pid" ]] || stop_if_same_process "$second_pid" "$second_started"
    if [[ -n "$server_pid" && -n "$server_started" && -n "$server_owner_token" ]]; then
        local identity_record="$lease_dir/identity.json"
        if [[ -f "$identity_record" && ! -L "$identity_record" ]] &&
           jq -e --argjson pid "$server_pid" --arg started "$server_started" \
             --arg token "$server_owner_token" '
             .pid == $pid and .process_started_at == $started and .owner_token == $token
           ' "$identity_record" >/dev/null 2>&1; then
            stop_if_same_process "$server_pid" "$server_started"
            wait "$server_pid" 2>/dev/null || true
            if ! metal_llm_release_managed_lease "$server_owner_token"; then
                print -u2 -- 'dynamic-MTP integration: failed to release the recorded managed lease'
                exit_status=1
            elif [[ -e "$identity_record" || -e "$lease_dir" ]]; then
                print -u2 -- 'dynamic-MTP integration: recorded managed lease remained after release'
                exit_status=1
            fi
        else
            print -u2 -- 'dynamic-MTP integration: managed identity changed before cleanup; refusing to signal or release it'
            exit_status=1
        fi
    elif [[ -n "$launcher_pid" && -n "$launcher_started" ]]; then
        # Startup may still be performing read-only verification before the
        # managed identity is published. Stop only the exact child we recorded.
        stop_if_same_process "$launcher_pid" "$launcher_started"
        wait "$launcher_pid" 2>/dev/null || true
    fi
    expected_scratch_root=${TMPDIR:-/tmp}
    expected_scratch_root=${expected_scratch_root:A}
    scratch_parent=${scratch:h:A}
    if (( exit_status != 0 )); then
        print -u2 -- "dynamic-MTP integration: preserving failure diagnostics: ${scratch:t}"
    elif [[ -d "$scratch" && "$scratch_parent" == "$expected_scratch_root" && \
            "${scratch:t}" == metal-llm-dynamic-mtp.* ]]; then
        rm -rf -- "$scratch"
    else
        print -u2 -- 'dynamic-MTP integration: refusing to remove an unexpected scratch path'
        exit_status=1
    fi
    return "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

"$root/bin/metal-llm" serve "$model_id" --profile auto --vision on > "$server_log" 2>&1 &
launcher_pid=$!
launcher_started=$(process_start_identity "$launcher_pid" 2>/dev/null || true)
[[ -n "$launcher_started" ]] || {
    wait "$launcher_pid" 2>/dev/null || true
    fail 'could not record the launched server process start identity'
}

identity_record="$lease_dir/identity.json"
for attempt in {1..600}; do
    if [[ -f "$identity_record" && ! -L "$identity_record" ]]; then
        metal_llm_validate_managed_identity "$identity_record" || fail 'server published an invalid managed identity'
        candidate_pid=$(jq -er '.pid' "$identity_record")
        candidate_started=$(jq -er '.process_started_at' "$identity_record")
        candidate_owner_token=$(jq -er '.owner_token' "$identity_record")
        [[ "$candidate_pid" == "$launcher_pid" && "$candidate_started" == "$launcher_started" ]] || \
            fail 'managed identity belongs to a process other than the one started by this harness'
        server_pid=$candidate_pid
        server_started=$candidate_started
        server_owner_token=$candidate_owner_token
        break
    fi
    kill -0 "$launcher_pid" 2>/dev/null || fail 'server exited before publishing its managed identity'
    sleep 1
done
[[ -n "$server_pid" ]] || fail 'timed out waiting for managed server identity'
metal_llm_managed_identity_is_live "$identity_record" || fail 'managed server identity is not live'

model_manifest_sha=$(metal_llm_sha256 "$model_manifest")
jq -e --arg host "$host" --argjson port "$port" --argjson context "$context" \
  --arg runtime "$runtime_id" --arg revision "$METAL_LLM_VERIFIED_RUNTIME_REVISION" \
  --arg tree "$METAL_LLM_VERIFIED_RUNTIME_TREE" \
  --arg runtime_manifest_sha "$METAL_LLM_VERIFIED_RUNTIME_MANIFEST_SHA256" \
  --arg receipt_sha "$METAL_LLM_VERIFIED_BUILD_RECEIPT_SHA256" \
  --arg executable_sha "$METAL_LLM_VERIFIED_EXECUTABLE_SHA256" \
  --arg model_manifest_sha "$model_manifest_sha" --argjson artifacts "$verified_artifacts" '
  .owner_kind == "serve" and .model_id == "qwen3.8-flash-next" and
  .profile_id == "auto" and .runtime_alias == "tuned" and .runtime_id == $runtime and
  .context == $context and .vision == true and .mtp_policy == "dynamic" and
  .mtp_threshold == 32768 and .host == $host and .port == $port and
  .runtime_revision == $revision and .runtime_tree_sha == $tree and
  .runtime_manifest_sha256 == $runtime_manifest_sha and
  .build_receipt_sha256 == $receipt_sha and .executable_name == "llama-server" and
  .executable_sha256 == $executable_sha and .model_manifest_sha256 == $model_manifest_sha and
  .artifacts == $artifacts
' "$identity_record" >/dev/null || fail 'managed identity does not match the verified auto configuration'

for attempt in {1..600}; do
    if curl "${health_arguments[@]}" "http://$host:$port/health" >/dev/null 2>&1; then
        break
    fi
    metal_llm_managed_identity_is_live "$identity_record" || fail 'managed server exited while waiting for health'
    sleep 1
done
curl "${health_arguments[@]}" "http://$host:$port/health" >/dev/null 2>&1 || \
    fail 'timed out waiting for server health'

typeset -a post_arguments
post_arguments=(-fsS --connect-timeout 5 --max-time 900 -H 'Content-Type: application/json')
[[ -z "${METAL_LLM_API_KEY:-}" ]] || post_arguments+=(-H "Authorization: Bearer $METAL_LLM_API_KEY")

extract_timing() {
    local response=$1 streaming=$2 parsed signatures
    if [[ "$streaming" == true ]]; then
        parsed=$(jq -Rsce '
          [splits("\n") | rtrimstr("\r") | select(startswith("data:")) |
           sub("^data:[ ]?"; "") | select(length > 0 and . != "[DONE]") | fromjson] |
          select(length > 0)
        ' <<< "$response") || fail 'invalid streaming response'
        jq -e 'last | .timings | type == "object"' <<< "$parsed" >/dev/null || \
            fail 'stream has no terminal timing metadata'
        signatures=$(jq -c '[.[] | select(.timings? != null) | .timings |
          {speculative, speculative_policy, effective_prompt_tokens, speculative_threshold}]' \
          <<< "$parsed")
        jq -e 'length > 0 and (unique | length) == 1' <<< "$signatures" >/dev/null || \
            fail 'stream changed route metadata'
        jq -c 'last.timings' <<< "$parsed"
    else
        jq -ce 'select(type == "object") | .timings | select(type == "object")' <<< "$response" || \
            fail 'non-streaming response has no timing metadata'
    fi
}

append_validated_run() {
    local case_id=$1 response=$2 streaming=$3 case_kind=$4 expected_count=$5 expected_route=$6
    local max_tokens=$7 notes=$8 endpoint=$9 payload_sha=${10}
    local timing speculative effective draft_n accepted output_sha
    timing=$(extract_timing "$response" "$streaming")
    metal_llm_validate_endpoint_timing "$timing" dynamic "$threshold" "$case_kind" 1024 || \
        fail "$case_id has route metadata inconsistent with the managed policy"
    speculative=$(metal_llm_extract_speculative_route "$timing") || \
        fail "$case_id has no boolean speculative route"
    effective=$(jq -er '.effective_prompt_tokens' <<< "$timing") || \
        fail "$case_id has no effective prompt-token count"
    if [[ "$expected_count" != any && "$effective" != "$expected_count" ]]; then
        fail "$case_id reported $effective effective tokens, expected $expected_count"
    fi
    if [[ "$expected_route" == on && "$speculative" != true ]] ||
       [[ "$expected_route" == off && "$speculative" != false ]]; then
        fail "$case_id selected the wrong fixed route"
    fi
    if [[ "$speculative" == true ]]; then
        metal_llm_validate_speculative_draft_statistics "$timing" || \
            fail "$case_id lacks valid speculative draft statistics"
        draft_n=$(jq -er '.draft_n' <<< "$timing") || \
            fail "$case_id has no speculative draft count"
        accepted=$(jq -er '.draft_n_accepted' <<< "$timing") || \
            fail "$case_id has no accepted speculative draft count"
    else
        jq -e '
          ((.draft_n // 0) == 0) and ((.draft_n_accepted // 0) == 0)
        ' <<< "$timing" >/dev/null || fail "$case_id collected draft statistics on the conventional route"
        draft_n=0
        accepted=0
    fi
    output_sha=$(print -rn -- "$response" | shasum -a 256 | awk '{print $1}') || \
        fail "$case_id response could not be hashed"
    jq -cn \
      --arg id "$case_id" --arg timestamp "$integration_timestamp" \
      --arg repository "$repository_revision" --arg hardware "$hardware_id" \
      --arg runtime "$runtime_id" --arg runtime_revision "$METAL_LLM_VERIFIED_RUNTIME_REVISION" \
      --argjson context "$context" --argjson selected "$speculative" \
      --argjson effective "$effective" --argjson threshold "$threshold" \
      --argjson max_tokens "$max_tokens" --arg sha "$output_sha" \
      --argjson draft "$draft_n" --argjson accepted "$accepted" \
      --arg endpoint "$endpoint" --arg payload_sha "$payload_sha" --arg notes "$notes" '
      {
        id: $id, experiment: "dynamic-mtp-acceptance", measurement_kind: "single_run",
        timestamp: $timestamp, repository_revision: $repository,
        hardware_id: $hardware, runtime_id: $runtime, runtime_revision: $runtime_revision,
        profile: null, profile_id: "auto", runtime_alias: "tuned", context: $context,
        vision: true, mtp_policy: "dynamic", mtp_selected: $selected,
        mtp_threshold: $threshold, prompt_tokens: null, effective_prompt_tokens: $effective,
        generated_tokens: null, prompt_tokens_per_second: null,
        generation_tokens_per_second: null, output_sha256: $sha,
        draft_acceptance: (($accepted | tostring) + "/" + ($draft | tostring)),
        command: ["curl", "POST", $endpoint, ("payload-sha256:" + $payload_sha)],
        generation_settings: {temperature: 0, seed: 1234, max_tokens: $max_tokens, reasoning: false, draft_n_max: 2},
        notes: $notes
      }
    ' >> "$run_buffer" || fail "$case_id validated run could not be recorded"
    typeset -g LAST_EFFECTIVE=$effective
    typeset -g LAST_SPECULATIVE=$speculative
}

post_case() {
    local case_id=$1 endpoint=$2 payload=$3 streaming=$4 case_kind=$5 expected_count=$6
    local expected_route=$7 max_tokens=$8 notes=$9 response payload_sha response_path response_sha
    response=$(curl "${post_arguments[@]}" -d "$payload" "http://$host:$port$endpoint") || \
        fail "$case_id request failed"
    response_path="$responses_dir/$case_id.response"
    print -rn -- "$response" > "$response_path" || fail "$case_id raw response could not be preserved"
    response_sha=$(metal_llm_sha256 "$response_path") || fail "$case_id raw response could not be hashed"
    payload_sha=$(print -rn -- "$payload" | shasum -a 256 | awk '{print $1}')
    append_validated_run "$case_id" "$response" "$streaming" "$case_kind" \
      "$expected_count" "$expected_route" "$max_tokens" "$notes" "$endpoint" "$payload_sha" || {
        fail "$case_id response validation failed; response-sha256=$response_sha"
        return 1
    }
    typeset -g LAST_RESPONSE="$response"
}

integration_timestamp=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
metal_llm_validate_benchmark_timestamp "$integration_timestamp" || exit 1

# Reject a second managed full-model launch. The candidate PID and its start
# identity are recorded before it can ever be stopped by this harness. A normal
# serve verifies the full build and artifact set before it reaches the lease, so
# wait for the exact lease diagnostic rather than assuming verification finishes
# within a short process-duration window.
second_log="$scratch/second-server.log"
expected_lease_rejection='managed full-model process is already active'
second_serve_timeout_seconds=900
"$root/bin/metal-llm" serve "$model_id" --profile fast --vision on > "$second_log" 2>&1 &
second_pid=$!
second_started=$(process_start_identity "$second_pid" 2>/dev/null || true)
[[ -n "$second_started" ]] || fail 'could not record the second serve attempt start identity'
set +e
metal_llm_wait_for_process_diagnostic "$second_pid" "$second_started" \
  "$second_log" "$expected_lease_rejection" "$second_serve_timeout_seconds" 1
second_wait_status=$?
set -e
case "$second_wait_status" in
    0) ;;
    124) fail "timed out after $second_serve_timeout_seconds seconds waiting for second serve lease rejection" ;;
    *) fail "second managed serve did not exit with the exact lease rejection (wait status $second_wait_status)" ;;
esac
second_pid=''
second_started=''

# /completion accepts token arrays. Calibrate its constant special-token offset,
# then derive literal array lengths for the three exact effective boundaries.
tokenize_payload=$(jq -cn '{content: " x", add_special: false}')
tokenize_response=$(curl "${post_arguments[@]}" -d "$tokenize_payload" "http://$host:$port/tokenize") || \
    fail 'tokenizer probe failed'
filler_token=$(jq -er '.tokens | select(type == "array" and length > 0) | last |
  select(type == "number" and floor == . and . >= 0)' <<< "$tokenize_response") || \
    fail 'tokenizer did not return a usable filler token'

completion_payload() {
    local token_count=$1 stream=$2 slot=$3 predict=${4:-16}
    jq -cn --argjson token "$filler_token" --argjson count "$token_count" \
      --argjson stream "$stream" --argjson slot "$slot" --argjson predict "$predict" '
      {prompt: [range(0; $count) | $token], n_predict: $predict, temperature: 0, seed: 1234,
       ignore_eos: true, cache_prompt: false, id_slot: $slot, stream: $stream}
    '
}

probe_payload=$(completion_payload 32 false 0)
post_case calibration-offset /completion "$probe_payload" false api any on 16 \
  'Calibrated the completion endpoint special-token offset; route and draft statistics validated.'
completion_offset=$(( LAST_EFFECTIVE - 32 ))
(( completion_offset >= 0 && completion_offset < 64 )) || fail 'completion special-token offset is outside the safe calibration range'

for boundary in 32767 32768 32769; do
    array_count=$(( boundary - completion_offset ))
    (( array_count > 0 )) || fail 'calibrated boundary array length is invalid'
    stream=false
    [[ "$boundary" == 32768 || "$boundary" == 32769 ]] && stream=true
    route=on
    (( boundary > threshold )) && route=off
    payload=$(completion_payload "$array_count" "$stream" 0)
    post_case "boundary-$boundary" /completion "$payload" "$stream" api "$boundary" "$route" 16 \
      "Exact effective-token boundary $boundary; terminal route and draft statistics validated."
done

# Force both route transitions through slot 0: short -> long -> short.
for reuse_case in short-first long short-second; do
    if [[ "$reuse_case" == long ]]; then
        effective_target=32769
        route=off
    else
        effective_target=32767
        route=on
    fi
    array_count=$(( effective_target - completion_offset ))
    payload=$(completion_payload "$array_count" false 0)
    post_case "reuse-$reuse_case" /completion "$payload" false api "$effective_target" "$route" 16 \
      "Explicit slot 0 reuse case $reuse_case; route reset and draft statistics validated."
done

# Send opposite routes to explicit slots concurrently and validate both only
# after both requests complete.
short_payload=$(completion_payload $(( 32767 - completion_offset )) false 0 64)
long_payload=$(completion_payload $(( 32769 - completion_offset )) false 1 64)
short_response_file="$scratch/concurrent-short.json"
long_response_file="$scratch/concurrent-long.json"
curl "${post_arguments[@]}" -d "$short_payload" "http://$host:$port/completion" > "$short_response_file" &
short_curl_pid=$!
curl "${post_arguments[@]}" -d "$long_payload" "http://$host:$port/completion" > "$long_response_file" &
long_curl_pid=$!
wait "$short_curl_pid" || fail 'concurrent short request failed'
wait "$long_curl_pid" || fail 'concurrent long request failed'
append_validated_run concurrent-short "$(command cat -- "$short_response_file")" false api 32767 on 64 \
  'Concurrent explicit slot 0 request selected the speculative route.' /completion \
  "$(print -rn -- "$short_payload" | shasum -a 256 | awk '{print $1}')"
append_validated_run concurrent-long "$(command cat -- "$long_response_file")" false api 32769 off 64 \
  'Concurrent explicit slot 1 request selected the conventional route.' /completion \
  "$(print -rn -- "$long_payload" | shasum -a 256 | awk '{print $1}')"

short_text='Reply with exactly: DYNAMIC-MTP-TEXT'
long_filler=$(awk 'BEGIN { for (i = 0; i < 33000; ++i) printf " x" }')
long_text="$long_filler
Reply with exactly: DYNAMIC-MTP-TEXT"

chat_payload() {
    local content=$1 stream=$2
    jq -cn --arg model "$model_id" --arg content "$content" --argjson stream "$stream" '
      {model: $model, messages: [{role: "user", content: $content}], max_tokens: 64,
       temperature: 0, seed: 1234, stream: $stream,
       chat_template_kwargs: {enable_thinking: false}} +
      (if $stream then {stream_options: {include_usage: true}} else {} end)
    '
}

for route_name in short long; do
    if [[ "$route_name" == short ]]; then
        content=$short_text
        route=on
        streaming=true
    else
        content=$long_text
        route=off
        streaming=false
    fi
    payload=$(chat_payload "$content" "$streaming")
    post_case "text-$route_name" /v1/chat/completions "$payload" "$streaming" api any "$route" 64 \
      "Deterministic text completed on the $route_name route."
    if [[ "$streaming" == true ]]; then
        rendered=$(jq -Rsre '[splits("\n") | rtrimstr("\r") | select(startswith("data:")) |
          sub("^data:[ ]?"; "") | select(length > 0 and . != "[DONE]") | fromjson |
          .choices[]?.delta.content? | select(type == "string")] | join("")' <<< "$LAST_RESPONSE")
    else
        rendered=$(jq -er '.choices[0].message.content | select(type == "string")' <<< "$LAST_RESPONSE")
    fi
    [[ "$rendered" == DYNAMIC-MTP-TEXT ]] || fail "deterministic text failed on the $route_name route"
done

for route_name in short long; do
    [[ "$route_name" == short ]] && { content='Return JSON with answer exactly "DYNAMIC-MTP-JSON".'; route=on; } || \
      { content="$long_filler
Return JSON with answer exactly \"DYNAMIC-MTP-JSON\"."; route=off; }
    payload=$(jq -cn --arg model "$model_id" --arg content "$content" '
      {model: $model, messages: [{role: "user", content: $content}], max_tokens: 256,
       temperature: 0, seed: 1234, chat_template_kwargs: {enable_thinking: false},
       response_format: {type: "json_schema", json_schema: {name: "answer", strict: true,
         schema: {type: "object", properties: {answer: {type: "string"}}, required: ["answer"], additionalProperties: false}}}}
    ')
    post_case "json-$route_name" /v1/chat/completions "$payload" false api any "$route" 256 \
      "Structured JSON completed and parsed on the $route_name route."
    jq -er '.choices[0].message.content | fromjson | .answer == "DYNAMIC-MTP-JSON"' \
      <<< "$LAST_RESPONSE" >/dev/null || fail "structured JSON failed on the $route_name route"
done

for route_name in short long; do
    [[ "$route_name" == short ]] && { content='Call report_route with value "ok".'; route=on; } || \
      { content="$long_filler
Call report_route with value \"ok\"."; route=off; }
    payload=$(jq -cn --arg model "$model_id" --arg content "$content" '
      {model: $model, messages: [{role: "user", content: $content}], max_tokens: 128,
       temperature: 0, seed: 1234, chat_template_kwargs: {enable_thinking: false},
       tools: [{type: "function", function: {name: "report_route", description: "Report the requested route value",
         parameters: {type: "object", properties: {value: {type: "string"}}, required: ["value"], additionalProperties: false}}}],
       tool_choice: {type: "function", function: {name: "report_route"}}}
    ')
    post_case "tool-$route_name" /v1/chat/completions "$payload" false api any "$route" 128 \
      "Forced tool call completed and parsed on the $route_name route."
    jq -er '.choices[0].message.tool_calls[0].function |
      .name == "report_route" and ((.arguments | fromjson).value == "ok")' \
      <<< "$LAST_RESPONSE" >/dev/null || fail "tool call failed on the $route_name route"
done

image_base64=$(base64 < "$fixture_path" | tr -d '\n')
image_url="data:$fixture_mime;base64,$image_base64"
for route_name in short long; do
    [[ "$route_name" == short ]] && { content='Describe the relative positions of the shapes in one sentence.'; route=on; } || \
      { content="$long_filler
Describe the relative positions of the shapes in one sentence."; route=off; }
    payload=$(jq -cn --arg model "$model_id" --arg content "$content" --arg image "$image_url" '
      {model: $model, messages: [{role: "user", content: [
        {type: "text", text: $content}, {type: "image_url", image_url: {url: $image}}
      ]}], max_tokens: 128, temperature: 0, seed: 1234,
       chat_template_kwargs: {enable_thinking: false}}
    ')
    post_case "vision-$route_name" /v1/chat/completions "$payload" false vision any "$route" 128 \
      "Tracked vision fixture completed on the $route_name route."
    jq -er '.choices[0].message.content | select(type == "string" and length > 0)' \
      <<< "$LAST_RESPONSE" >/dev/null || fail "vision response was empty on the $route_name route"
done

# The same text is below the boundary alone but must cross it after image
# expansion. This is separate from the ordinary vision route pair above.
cross_filler=$(awk 'BEGIN { for (i = 0; i < 31800; ++i) printf " x" }')
cross_content="$cross_filler
Describe the relative positions of the shapes."
text_cross_payload=$(chat_payload "$cross_content" false)
post_case vision-cross-text-control /v1/chat/completions "$text_cross_payload" false api any on 64 \
  'The same text used by the following image case is below the dynamic threshold.'
text_cross_effective=$LAST_EFFECTIVE
(( text_cross_effective <= threshold )) || fail 'vision text control was not below the threshold'
cross_payload=$(jq -cn --arg model "$model_id" --arg content "$cross_content" --arg image "$image_url" '
  {model: $model, messages: [{role: "user", content: [
    {type: "text", text: $content}, {type: "image_url", image_url: {url: $image}}
  ]}], max_tokens: 64, temperature: 0, seed: 1234,
   chat_template_kwargs: {enable_thinking: false}}
')
post_case vision-cross-expanded /v1/chat/completions "$cross_payload" false vision any off 64 \
  'The identical text was below the threshold while multimodal expansion selected the conventional route.'
(( LAST_EFFECTIVE > threshold && LAST_EFFECTIVE > text_cross_effective )) || \
  fail 'vision-expanded effective count did not cross the threshold'

system_provenance=$(metal_llm_benchmark_system_provenance)
script_sha=$(metal_llm_sha256 "$root/tests/integration/test_dynamic_mtp.sh")
provenance=$(jq -cn \
  --arg repository_revision "$repository_revision" --arg repository_tree "$repository_tree" \
  --arg hardware "$hardware_id" --arg chip "$METAL_LLM_DETECTED_CHIP" \
  --argjson memory "$METAL_LLM_DETECTED_MEMORY_BYTES" --argjson system "$system_provenance" \
  --arg runtime "$runtime_id" --arg runtime_revision "$METAL_LLM_VERIFIED_RUNTIME_REVISION" \
  --arg runtime_tree "$METAL_LLM_VERIFIED_RUNTIME_TREE" \
  --arg runtime_manifest_sha "$METAL_LLM_VERIFIED_RUNTIME_MANIFEST_SHA256" \
  --arg receipt_sha "$METAL_LLM_VERIFIED_BUILD_RECEIPT_SHA256" \
  --arg executable_sha "$METAL_LLM_VERIFIED_EXECUTABLE_SHA256" \
  --arg model_manifest_sha "$model_manifest_sha" --argjson artifacts "$verified_artifacts" \
  --arg suite "$suite_id" --arg suite_sha "$script_sha" \
  --arg fixture "$fixture_relative" --arg fixture_sha "$fixture_sha" '
  {
    repository: {revision: $repository_revision, tree_sha: $repository_tree, clean: true},
    hardware: {id: $hardware, chip: $chip, unified_memory_bytes: $memory}, system: $system,
    profile_id: "auto", runtime_alias: "tuned", context: 262144, vision: true,
    mtp_policy: "dynamic", mtp_threshold: 32768,
    runtime: {id: $runtime, tested_revision: $runtime_revision, tested_tree_sha: $runtime_tree,
      manifest_sha256: $runtime_manifest_sha, build_receipt_sha256: $receipt_sha,
      executable: {name: "llama-server", sha256: $executable_sha}},
    model_manifest_sha256: $model_manifest_sha, artifacts: $artifacts,
    suite: {id: $suite, sha256: $suite_sha, fixtures: [{path: $fixture, sha256: $fixture_sha}]}
  }
')

compact_timestamp=${integration_timestamp//[-:]/}
experiment_id=${(L)compact_timestamp}-dynamic-mtp-acceptance
result_dir="$root/results/raw"
result_path="$result_dir/$compact_timestamp-dynamic-mtp-acceptance-$model_id.json"
result_part=$(mktemp "$result_path.part.XXXXXX")
jq -s --arg experiment "$experiment_id" --arg date "${integration_timestamp[1,10]}" \
  --arg model "$model_id" --arg suite "$suite_id" --argjson provenance "$provenance" '
  {schema_version: 1, experiment_id: $experiment, date: $date, model_id: $model,
   suite_id: $suite, benchmark_mode: "endpoint", provenance: $provenance, runs: .}
' "$run_buffer" > "$result_part"

metal_llm_validate_result "$result_part" 'pending dynamic-MTP integration result' || {
    rm -f -- "$result_part"
    fail 'sanitized integration evidence failed the existing result validator'
}
metal_llm_publish_benchmark_result "$result_part" "$result_path" || exit 1
print -- "dynamic-MTP integration: PASS; wrote validated evidence: ${result_path#$root/}"
