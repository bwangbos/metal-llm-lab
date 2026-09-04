metal_llm_bench_usage() {
    metal_llm_error 'usage: metal-llm bench MODEL --suite SUITE [--mode local] [--runtime tuned|upstream] [--dry-run]'
    metal_llm_error '       metal-llm bench MODEL --suite SUITE --mode endpoint [--profile auto|fast|long|stable] [--vision on|off] [--dry-run]'
    metal_llm_error '       metal-llm bench MODEL --suite SUITE --mode endpoint --profile custom --runtime tuned|upstream --mtp on|off|dynamic --context TOKENS [--vision on|off] [--dry-run]'
    return 2
}

metal_llm_validate_benchmark_suite() {
    local suite_file=$1
    local expected_id=$2
    jq -e --arg expected_id "$expected_id" '
      .schema_version == 1 and .id == $expected_id and
      (.default_mode == "local" or .default_mode == "endpoint") and
      (has("default_profile") | not) and
      (.cases | type == "array" and length > 0 and all(.[];
        (.id | type == "string" and test("^[a-z0-9]+([.-][a-z0-9]+)*$")) and
        (.mode == "local" or .mode == "endpoint") and
        (.kind == "llama-bench" or .kind == "api" or .kind == "vision") and
        (if .mode == "local" then .kind == "llama-bench" else (.kind == "api" or .kind == "vision") end) and
        (.notes | type == "string" and length > 0) and
        (if has("stream") then .mode == "endpoint" and (.stream | type == "boolean") else true end) and
        (if .kind == "llama-bench" then
          (.prompt_tokens | type == "number" and . >= 0 and floor == .) and
          (.generated_tokens | type == "number" and . >= 0 and floor == .) and
          (.repetitions | type == "number" and . > 0 and floor == .)
        else
          (.prompt | type == "string" and length > 0) and
          (.max_tokens | type == "number" and . > 0 and floor == .) and
          (.temperature | type == "number") and
          (.seed | type == "number" and floor == .)
        end)
      ))
    ' "$suite_file" >/dev/null 2>&1
}

metal_llm_command_json() {
    jq -cn --args '$ARGS.positional' -- "$@"
}

metal_llm_publish_benchmark_result() {
    local result_part=$1
    local result_path=$2
    if ! ln "$result_part" "$result_path" 2>/dev/null; then
        rm -f -- "$result_part"
        metal_llm_die "benchmark result already exists: ${result_path:t}"
        return 1
    fi
    rm -f -- "$result_part" || return 1
}

metal_llm_validate_benchmark_timestamp() {
    local now=$1
    [[ "$now" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' ]] || {
        metal_llm_die 'system UTC clock did not produce an RFC 3339 timestamp'
        return 1
    }
    jq -en --arg now "$now" '
      try (($now | fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $now) catch false
    ' >/dev/null || {
        metal_llm_die 'system UTC clock did not produce a real RFC 3339 UTC calendar timestamp'
        return 1
    }
}

metal_llm_benchmark_system_provenance() {
    local os_version='' compiler_output='' compiler='' sdk='' power_output='' power_source=''
    local power_settings='' low_power_mode_json=null
    if command -v sw_vers >/dev/null 2>&1; then
        os_version=$(sw_vers -productVersion 2>/dev/null || true)
    fi
    typeset -a compiler_lines
    if command -v xcrun >/dev/null 2>&1; then
        compiler_output=$(xcrun clang --version 2>/dev/null || true)
        if [[ -n "$compiler_output" ]]; then
            compiler_lines=("${(@f)compiler_output}")
            compiler=$compiler_lines[1]
        fi
        sdk=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)
    fi
    if command -v pmset >/dev/null 2>&1; then
        power_output=$(pmset -g batt 2>/dev/null || true)
        if [[ "$power_output" =~ "Now drawing from '([^']+)'" ]]; then
            power_source=$match[1]
        fi
        power_settings=$(pmset -g custom 2>/dev/null || true)
        if [[ "$power_settings" =~ '(^|\n)[[:space:]]*lowpowermode[[:space:]]+([01])([[:space:]]|$)' ]]; then
            [[ "$match[2]" == 1 ]] && low_power_mode_json=true || low_power_mode_json=false
        fi
    fi
    jq -cn --arg os_version "$os_version" --arg compiler "$compiler" --arg sdk "$sdk" \
      --arg power_source "$power_source" --argjson low_power_mode "$low_power_mode_json" '
      {
        operating_system: "macOS",
        operating_system_version: (if $os_version == "" then null else $os_version end),
        compiler: (if $compiler == "" then null else $compiler end),
        sdk: (if $sdk == "" then null else $sdk end),
        power_source: (if $power_source == "" then null else $power_source end),
        low_power_mode: $low_power_mode
      }
    '
}

metal_llm_validate_vision_fixture() {
    local fixture=$1
    local fixture_root="$METAL_LLM_ROOT/benchmarks/fixtures"
    [[ "$fixture" == benchmarks/fixtures/* && "$fixture" != /* && "$fixture" != *'/../'* && \
      "$fixture" != '../'* && "$fixture" != *'/./'* && "$fixture" != './'* ]] || {
        metal_llm_die "vision fixture must stay under benchmarks/fixtures: $fixture"
        return 1
    }
    local expected_mime
    case "$fixture" in
        *.png) expected_mime=image/png ;;
        *.jpg|*.jpeg) expected_mime=image/jpeg ;;
        *) metal_llm_die "unsupported vision fixture type: $fixture"; return 1 ;;
    esac
    git -C "$METAL_LLM_ROOT" ls-files --error-unmatch -- "$fixture" >/dev/null 2>&1 || {
        metal_llm_die "vision fixture is not tracked: $fixture"
        return 1
    }
    local fixture_path="$METAL_LLM_ROOT/$fixture"
    [[ -e "$fixture_path" ]] || { metal_llm_die "vision fixture is missing: $fixture"; return 1; }
    [[ -f "$fixture_path" && ! -L "$fixture_path" ]] || {
        metal_llm_die "vision fixture is not a regular file: $fixture"
        return 1
    }
    local canonical_root=${fixture_root:A}
    local canonical_path=${fixture_path:A}
    [[ "$canonical_path" == "$canonical_root"/* ]] || {
        metal_llm_die "vision fixture escapes benchmarks/fixtures: $fixture"
        return 1
    }
    command -v file >/dev/null 2>&1 || { metal_llm_die 'file is required for vision fixtures'; return 1; }
    local mime
    mime=$(file -b --mime-type "$canonical_path" 2>/dev/null) || return 1
    [[ "$mime" == "$expected_mime" ]] || {
        metal_llm_die "vision fixture extension and MIME do not match: $fixture"
        return 1
    }
    typeset -g METAL_LLM_VERIFIED_FIXTURE_PATH="$canonical_path"
    typeset -g METAL_LLM_VERIFIED_FIXTURE_MIME="$mime"
    typeset -g METAL_LLM_VERIFIED_FIXTURE_SHA256
    METAL_LLM_VERIFIED_FIXTURE_SHA256=$(metal_llm_sha256 "$canonical_path") || return 1
}

metal_llm_bench_port_is_owned() {
    local host=$1
    local port=$2
    command -v curl >/dev/null 2>&1 || return 1
    typeset -a health_arguments
    health_arguments=(-fsS --connect-timeout 1 --max-time 1)
    [[ -z "${METAL_LLM_API_KEY:-}" ]] || health_arguments+=(-H "Authorization: Bearer $METAL_LLM_API_KEY")
    health_arguments+=("http://$host:$port/health")
    curl "${health_arguments[@]}" >/dev/null 2>&1
}

metal_llm_parse_endpoint_response() {
    local response=$1
    local streaming=$2
    local parsed_response timing_signatures

    unset METAL_LLM_BENCH_RESPONSE_CONTENT METAL_LLM_BENCH_RESPONSE_USAGE METAL_LLM_BENCH_RESPONSE_TIMING
    if [[ "$streaming" == true ]]; then
        parsed_response=$(jq -Rsce '
          [splits("\n") |
            rtrimstr("\r") |
            select(startswith("data:")) |
            sub("^data:[ ]?"; "") |
            select(length > 0 and . != "[DONE]") |
            fromjson] |
          select(length > 0)
        ' <<< "$response" 2>/dev/null) || {
            metal_llm_die 'invalid streaming API response'
            return 1
        }
        jq -e 'last | .timings | type == "object"' <<< "$parsed_response" >/dev/null 2>&1 || {
            metal_llm_die 'missing final endpoint timing metadata'
            return 1
        }
        timing_signatures=$(jq -c '[.[] | select(.timings? != null) | .timings | {
          speculative, speculative_policy, effective_prompt_tokens, speculative_threshold
        }]' <<< "$parsed_response") || return 1
        jq -e 'length > 0 and (unique | length) == 1' <<< "$timing_signatures" >/dev/null 2>&1 || {
            metal_llm_die 'endpoint stream changed MTP route metadata'
            return 1
        }
        METAL_LLM_BENCH_RESPONSE_CONTENT=$(jq -er '
          [.[] | .choices[]?.delta.content? | select(type == "string")] | join("")
        ' <<< "$parsed_response") || return 1
        METAL_LLM_BENCH_RESPONSE_USAGE=$(jq -c '
          ([.[] | select(.usage? != null) | .usage] | last) // {}
        ' <<< "$parsed_response") || return 1
        METAL_LLM_BENCH_RESPONSE_TIMING=$(jq -c 'last.timings' <<< "$parsed_response") || return 1
    else
        parsed_response=$(jq -ce 'select(type == "object")' <<< "$response" 2>/dev/null) || {
            metal_llm_die 'invalid API response'
            return 1
        }
        jq -e '.timings | type == "object"' <<< "$parsed_response" >/dev/null 2>&1 || {
            metal_llm_die 'missing final endpoint timing metadata'
            return 1
        }
        METAL_LLM_BENCH_RESPONSE_CONTENT=$(jq -er '
          .choices[0].message.content | select(type == "string")
        ' <<< "$parsed_response") || return 1
        METAL_LLM_BENCH_RESPONSE_USAGE=$(jq -c '.usage // {}' <<< "$parsed_response") || return 1
        METAL_LLM_BENCH_RESPONSE_TIMING=$(jq -c '.timings' <<< "$parsed_response") || return 1
    fi
}

metal_llm_validate_endpoint_timing() {
    local timing=$1
    local configured_policy=$2
    local configured_threshold=$3
    local case_kind=$4
    local image_min_tokens=$5
    local threshold_json=${configured_threshold/__null__/null}

    jq -e --arg policy "$configured_policy" --argjson threshold "$threshold_json" '
      (.speculative | type == "boolean") and
      (.speculative_policy == $policy) and
      (.effective_prompt_tokens | type == "number" and floor == . and . >= 0) and
      (if $policy == "dynamic" then
        .speculative_threshold == $threshold and
        .speculative == (.effective_prompt_tokens <= $threshold)
      elif $policy == "on" then
        .speculative == true and .speculative_threshold == null
      else
        .speculative == false and .speculative_threshold == null
      end)
    ' <<< "$timing" >/dev/null 2>&1 || {
        metal_llm_die 'endpoint timing metadata does not match managed MTP policy'
        return 1
    }
    if [[ "$case_kind" == vision ]]; then
        jq -e --argjson image_min_tokens "${image_min_tokens/__null__/null}" '
          ($image_min_tokens | type == "number" and floor == . and . > 0) and
          .effective_prompt_tokens >= $image_min_tokens
        ' <<< "$timing" >/dev/null 2>&1 || {
            metal_llm_die 'endpoint effective prompt count is below resolved vision expansion minimum'
            return 1
        }
    fi
    typeset -g METAL_LLM_BENCH_MTP_SELECTED
    typeset -g METAL_LLM_BENCH_EFFECTIVE_PROMPT_TOKENS
    METAL_LLM_BENCH_MTP_SELECTED=$(jq -r '.speculative' <<< "$timing") || return 1
    METAL_LLM_BENCH_EFFECTIVE_PROMPT_TOKENS=$(jq -r '.effective_prompt_tokens' <<< "$timing") || return 1
}

metal_llm_bench() {
    local model_id='' suite_id='' mode='' dry_run=0 argument
    local requested_profile='' requested_vision='' requested_runtime=''
    local requested_mtp='' requested_context=''
    local profile_seen=0 vision_seen=0 runtime_seen=0 mtp_seen=0 context_seen=0
    while (( $# > 0 )); do
        argument=$1
        shift
        case "$argument" in
            --dry-run)
                (( dry_run == 0 )) || { metal_llm_bench_usage; return $?; }
                dry_run=1
                ;;
            --suite)
                (( $# > 0 )) || { metal_llm_bench_usage; return $?; }
                [[ -z "$suite_id" ]] || { metal_llm_bench_usage; return $?; }
                suite_id=$1
                shift
                ;;
            --mode)
                (( $# > 0 )) || { metal_llm_bench_usage; return $?; }
                [[ -z "$mode" ]] || { metal_llm_bench_usage; return $?; }
                mode=$1
                shift
                ;;
            --profile)
                (( $# > 0 && profile_seen == 0 )) || { metal_llm_bench_usage; return $?; }
                [[ -n "$1" ]] || { metal_llm_bench_usage; return $?; }
                profile_seen=1
                requested_profile=$1
                shift
                ;;
            --vision)
                (( $# > 0 && vision_seen == 0 )) || { metal_llm_bench_usage; return $?; }
                [[ -n "$1" ]] || { metal_llm_bench_usage; return $?; }
                vision_seen=1
                requested_vision=$1
                shift
                ;;
            --runtime)
                (( $# > 0 && runtime_seen == 0 )) || { metal_llm_bench_usage; return $?; }
                [[ -n "$1" ]] || { metal_llm_bench_usage; return $?; }
                runtime_seen=1
                requested_runtime=$1
                shift
                ;;
            --mtp)
                (( $# > 0 && mtp_seen == 0 )) || { metal_llm_bench_usage; return $?; }
                [[ -n "$1" ]] || { metal_llm_bench_usage; return $?; }
                mtp_seen=1
                requested_mtp=$1
                shift
                ;;
            --context)
                (( $# > 0 && context_seen == 0 )) || { metal_llm_bench_usage; return $?; }
                [[ -n "$1" ]] || { metal_llm_bench_usage; return $?; }
                context_seen=1
                requested_context=$1
                shift
                ;;
            -*) metal_llm_bench_usage; return $? ;;
            *)
                [[ -z "$model_id" ]] || { metal_llm_bench_usage; return $?; }
                model_id=$argument
                ;;
        esac
    done
    [[ -n "$model_id" && -n "$suite_id" ]] || { metal_llm_bench_usage; return $?; }
    metal_llm_valid_id "$model_id" || { metal_llm_die "invalid model id: $model_id"; return 1; }
    metal_llm_valid_id "$suite_id" || { metal_llm_die "invalid suite id: $suite_id"; return 1; }
    metal_llm_require_supported_host || return 1
    command -v jq >/dev/null 2>&1 || { metal_llm_die 'jq is required'; return 1; }

    local model_manifest="$METAL_LLM_ROOT/manifests/models/$model_id.json"
    local suite_file="$METAL_LLM_ROOT/benchmarks/suites/$suite_id.json"
    [[ -f "$model_manifest" ]] || { metal_llm_die "model manifest not found: $model_id"; return 1; }
    [[ -f "$suite_file" ]] || { metal_llm_die "benchmark suite not found: $suite_id"; return 1; }
    metal_llm_validate_model_manifest "$model_manifest" "$model_id" || {
        metal_llm_die "invalid model manifest: $model_manifest"
        return 1
    }
    metal_llm_validate_benchmark_suite "$suite_file" "$suite_id" || {
        metal_llm_die "invalid benchmark suite: $suite_file"
        return 1
    }
    [[ -n "$mode" ]] || mode=$(jq -er '.default_mode' "$suite_file") || return 1
    if ! jq -e --arg mode "$mode" 'any(.cases[]; .mode == $mode)' "$suite_file" >/dev/null; then
        metal_llm_die "mode not found: $mode"
        return 1
    fi

    local profile_id='__null__' runtime_alias runtime_id model_artifact_id context='__null__'
    local vision_enabled='__null__' vision_image_min_tokens='__null__'
    local mtp_policy='__null__' mtp_threshold='__null__'
    local gpu_layers fit flash_attention load_mode lazy_mmap
    local effective_profile='' managed_identity_record='' artifact_configuration
    local mtp_artifact_id='__null__' spec_type='__null__' draft_n_max='__null__'
    local draft_gpu_layers='__null__'
    if [[ "$mode" == local ]]; then
        (( profile_seen == 0 && vision_seen == 0 && mtp_seen == 0 && context_seen == 0 )) || {
            metal_llm_die 'local benchmark accepts only --runtime tuned|upstream'
            return 1
        }
        [[ -n "$requested_runtime" ]] || requested_runtime=tuned
        [[ "$requested_runtime" == tuned || "$requested_runtime" == upstream ]] || {
            metal_llm_die 'runtime must be tuned or upstream'
            return 1
        }
        runtime_alias=$requested_runtime
        runtime_id=$(jq -er --arg alias "$runtime_alias" '.runtime_aliases[$alias]' "$model_manifest") || {
            metal_llm_die "model manifest has no valid runtime alias: $runtime_alias"
            return 1
        }
        local local_record
        local_record=$(jq -er '
          [.text_model.entry_artifact_id, (.metal.gpu_layers | tostring), (.metal.fit | tostring),
           (.metal.flash_attention | tostring), (.metal.load_mode | tostring),
           (.metal.lazy_mmap | tostring)] | @tsv
        ' "$model_manifest") || return 1
        IFS=$'\t' read -r model_artifact_id gpu_layers fit flash_attention load_mode lazy_mmap \
          <<< "$local_record"
        artifact_configuration=$(jq -cn --arg runtime_alias "$runtime_alias" --arg runtime_id "$runtime_id" \
          --arg model_artifact_id "$model_artifact_id" --argjson metal "$(jq -c '.metal' "$model_manifest")" '
          {
            profile_id: null, runtime_alias: $runtime_alias, runtime_id: $runtime_id, context: null,
            vision: {enabled: false, projector_artifact_id: null, image_min_tokens: null},
            mtp: {policy: "off", artifact_id: null, spec_type: null, draft_n_max: null,
              gpu_layers: null, threshold: null},
            model_artifact_id: $model_artifact_id, metal: $metal
          }
        ') || return 1
    else
        if (( dry_run == 0 )); then
            metal_llm_read_live_managed_identity || return 1
            managed_identity_record=$METAL_LLM_MANAGED_IDENTITY_RECORD
            jq -e --arg model "$model_id" '
              .owner_kind == "serve" and .model_id == $model
            ' "$managed_identity_record" >/dev/null || {
                metal_llm_die "managed endpoint identity does not match model: $model_id"
                return 1
            }
            if (( profile_seen == 0 )); then
                requested_profile=$(jq -er '.profile_id' "$managed_identity_record") || return 1
            fi
            if (( vision_seen == 0 )); then
                requested_vision=$(jq -er 'if .vision then "on" else "off" end' \
                  "$managed_identity_record") || return 1
            fi
            if (( profile_seen == 0 )) && [[ "$requested_profile" == custom ]]; then
                (( runtime_seen == 1 )) || requested_runtime=$(jq -er '.runtime_alias' "$managed_identity_record") || return 1
                (( mtp_seen == 1 )) || requested_mtp=$(jq -er '.mtp_policy' "$managed_identity_record") || return 1
                (( context_seen == 1 )) || requested_context=$(jq -er '.context | tostring' "$managed_identity_record") || return 1
            fi
        fi
        metal_llm_resolve_profile "$model_manifest" "$requested_profile" "$requested_vision" \
          "$requested_runtime" "$requested_mtp" "$requested_context" || return 1
        effective_profile=$METAL_LLM_EFFECTIVE_PROFILE
        local profile_record
        profile_record=$(jq -er '
          [
            .profile_id, .runtime_alias, .runtime_id, .model_artifact_id, (.context | tostring),
            (.vision.enabled | tostring),
            (if .vision.image_min_tokens == null then "__null__"
             else (.vision.image_min_tokens | tostring) end),
            .mtp.policy, (.mtp.artifact_id // "__null__"),
            (.mtp.spec_type // "__null__"),
            (if .mtp.draft_n_max == null then "__null__" else (.mtp.draft_n_max | tostring) end),
            (if .mtp.gpu_layers == null then "__null__" else (.mtp.gpu_layers | tostring) end),
            (if .mtp.threshold == null then "__null__" else (.mtp.threshold | tostring) end),
            (.metal.gpu_layers | tostring), (.metal.fit | tostring),
            (.metal.flash_attention | tostring), (.metal.load_mode | tostring),
            (.metal.lazy_mmap | tostring)
          ] | @tsv
        ' <<< "$effective_profile") || return 1
        IFS=$'\t' read -r profile_id runtime_alias runtime_id model_artifact_id context \
          vision_enabled vision_image_min_tokens mtp_policy mtp_artifact_id spec_type draft_n_max draft_gpu_layers \
          mtp_threshold gpu_layers fit flash_attention load_mode lazy_mmap <<< "$profile_record"
        artifact_configuration=$effective_profile
    fi

    local runtime_manifest="$METAL_LLM_ROOT/manifests/runtimes/$runtime_id.json"
    [[ -f "$runtime_manifest" ]] || { metal_llm_die "runtime manifest not found: $runtime_id"; return 1; }
    metal_llm_validate_runtime_manifest "$runtime_manifest" "$runtime_id" || {
        metal_llm_die "invalid runtime manifest: $runtime_manifest"
        return 1
    }
    local bench_executable='' model_path=''
    if [[ "$mode" == local ]]; then
        metal_llm_verify_runtime_build "$runtime_id" "$runtime_manifest" llama-bench || return 1
        bench_executable=$METAL_LLM_VERIFIED_EXECUTABLE
        local artifact_dir="$METAL_LLM_ROOT/.lab/artifacts/$model_id"
        metal_llm_profile_artifact_identities "$model_manifest" "$artifact_dir" \
          "$artifact_configuration" || return 1
        model_path=$(metal_llm_artifact_path "$model_manifest" "$artifact_dir" "$model_artifact_id") || return 1
    elif (( dry_run == 0 )); then
        metal_llm_verify_runtime_build "$runtime_id" "$runtime_manifest" llama-server || return 1
        local endpoint_artifact_dir="$METAL_LLM_ROOT/.lab/artifacts/$model_id"
        metal_llm_profile_artifact_identities "$model_manifest" "$endpoint_artifact_dir" \
          "$artifact_configuration" || return 1
    fi

    [[ -z "${METAL_LLM_HARDWARE_ID:-}" ]] || {
        metal_llm_die 'METAL_LLM_HARDWARE_ID is not accepted; hardware is detected and matched exactly'
        return 1
    }
    metal_llm_detect_hardware_manifest || return 1
    local hardware_id=$METAL_LLM_DETECTED_HARDWARE_ID

    local host=${METAL_LLM_HOST:-127.0.0.1}
    local port=${METAL_LLM_PORT:-8080}
    [[ "$port" == <-> && "$port" -ge 1 && "$port" -le 65535 ]] || {
        metal_llm_die 'METAL_LLM_PORT must be an integer from 1 to 65535'
        return 1
    }
    if [[ "$mode" == endpoint && "$dry_run" == 0 ]]; then
        local current_model_manifest_sha
        current_model_manifest_sha=$(metal_llm_sha256 "$model_manifest") || return 1
        jq -e --arg host "$host" --argjson port "$port" \
          --arg profile "$profile_id" --arg runtime_alias "$runtime_alias" \
          --argjson context "$context" --argjson vision "$vision_enabled" \
          --arg mtp_policy "$mtp_policy" \
          --argjson mtp_threshold "${mtp_threshold/__null__/null}" \
          --arg runtime "$runtime_id" \
          --arg revision "$METAL_LLM_VERIFIED_RUNTIME_REVISION" \
          --arg tree "$METAL_LLM_VERIFIED_RUNTIME_TREE" \
          --arg manifest_sha "$METAL_LLM_VERIFIED_RUNTIME_MANIFEST_SHA256" \
          --arg receipt_sha "$METAL_LLM_VERIFIED_BUILD_RECEIPT_SHA256" \
          --arg executable_sha "$METAL_LLM_VERIFIED_EXECUTABLE_SHA256" \
          --arg model_manifest_sha "$current_model_manifest_sha" \
          --argjson artifacts "$METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES" '
          .host == $host and .port == $port and
          .profile_id == $profile and .runtime_alias == $runtime_alias and
          .context == $context and .vision == $vision and
          .mtp_policy == $mtp_policy and .mtp_threshold == $mtp_threshold and
          .runtime_id == $runtime and
          .runtime_revision == $revision and .runtime_tree_sha == $tree and
          .runtime_manifest_sha256 == $manifest_sha and .build_receipt_sha256 == $receipt_sha and
          .executable_name == "llama-server" and .executable_sha256 == $executable_sha and
          .model_manifest_sha256 == $model_manifest_sha and .artifacts == $artifacts
        ' "$managed_identity_record" >/dev/null || {
            metal_llm_die "managed endpoint identity does not match resolved configuration at $host:$port"
            return 1
        }
    fi
    if (( dry_run == 0 )); then
        if [[ "$mode" == local ]] && metal_llm_bench_port_is_owned "$host" "$port"; then
            metal_llm_die "configured port is owned by a running lab server: $host:$port"
            return 1
        elif [[ "$mode" == endpoint ]] && ! metal_llm_bench_port_is_owned "$host" "$port"; then
            metal_llm_die "endpoint mode requires a running endpoint: $host:$port"
            return 1
        fi
    fi

    [[ -z "${METAL_LLM_NOW:-}" ]] || {
        metal_llm_die 'METAL_LLM_NOW is not accepted; benchmark time comes from the system clock'
        return 1
    }
    local clock_executable=/bin/date
    [[ -f "$clock_executable" && -x "$clock_executable" && ! -L "$clock_executable" ]] || {
        metal_llm_die 'trusted system clock executable is unavailable: /bin/date'
        return 1
    }
    local now
    now=$("$clock_executable" -u +%Y-%m-%dT%H:%M:%SZ) || {
        metal_llm_die 'could not read the system UTC clock'
        return 1
    }
    metal_llm_validate_benchmark_timestamp "$now" || return 1
    [[ -z "${METAL_LLM_REPOSITORY_REVISION:-}" ]] || {
        metal_llm_die 'METAL_LLM_REPOSITORY_REVISION is not accepted; the checked-out revision is recorded'
        return 1
    }
    command -v git >/dev/null 2>&1 || { metal_llm_die 'git is required'; return 1; }
    git -C "$METAL_LLM_ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
        metal_llm_die 'benchmark repository is not a Git checkout'
        return 1
    }
    local repository_status repository_revision repository_tree
    repository_status=$(git -C "$METAL_LLM_ROOT" status --porcelain=v1 --untracked-files=all) || return 1
    [[ -z "$repository_status" ]] || {
        metal_llm_die 'benchmark repository checkout is not clean'
        return 1
    }
    repository_revision=$(git -C "$METAL_LLM_ROOT" rev-parse HEAD 2>/dev/null) || {
        metal_llm_die 'could not resolve repository revision'
        return 1
    }
    [[ "$repository_revision" =~ '^[0-9a-f]{40}$' ]] || {
        metal_llm_die 'repository revision must be a 40-character Git SHA'
        return 1
    }
    repository_tree=$(git -C "$METAL_LLM_ROOT" rev-parse 'HEAD^{tree}') || return 1
    local runtime_revision
    if (( dry_run == 1 )) && [[ "$mode" == endpoint ]]; then
        runtime_revision=$(jq -er '.tested_revision' "$runtime_manifest") || return 1
    else
        runtime_revision=$METAL_LLM_VERIFIED_RUNTIME_REVISION
    fi
    local measurement_kind=single_run

    local include_optional=${METAL_LLM_INCLUDE_OPTIONAL:-0}
    [[ "$include_optional" == 0 || "$include_optional" == 1 ]] || {
        metal_llm_die 'METAL_LLM_INCLUDE_OPTIONAL must be 0 or 1'
        return 1
    }
    if [[ "$mode" == endpoint && "$dry_run" == 0 ]] && jq -e --argjson include "$include_optional" '
      any(.cases[]; .mode == "endpoint" and .kind == "vision" and
        ((.optional // false) == false or $include == 1))
    ' "$suite_file" >/dev/null; then
        jq -e '.vision == true' "$managed_identity_record" >/dev/null || {
            metal_llm_die 'vision benchmark requires a vision-capable managed profile'
            return 1
        }
    fi
    local fixture_record fixture_relative fixtures_json='[]'
    while IFS= read -r fixture_record; do
        fixture_relative=$(jq -er '.fixture' <<< "$fixture_record") || return 1
        metal_llm_validate_vision_fixture "$fixture_relative" || return 1
        fixtures_json=$(jq -c --arg path "$fixture_relative" \
          --arg sha "$METAL_LLM_VERIFIED_FIXTURE_SHA256" \
          '. + [{path: $path, sha256: $sha}]' <<< "$fixtures_json") || return 1
    done < <(jq -c --arg mode "$mode" --argjson include "$include_optional" '
      .cases[] | select(.mode == $mode and .kind == "vision" and
        ((.optional // false) == false or $include == 1))
    ' "$suite_file")

    local model_manifest_sha suite_sha system_provenance provenance_json
    model_manifest_sha=$(metal_llm_sha256 "$model_manifest") || return 1
    suite_sha=$(metal_llm_sha256 "$suite_file") || return 1
    system_provenance=$(metal_llm_benchmark_system_provenance) || return 1
    if (( dry_run == 0 )); then
        provenance_json=$(jq -cn \
          --arg repository_revision "$repository_revision" --arg repository_tree "$repository_tree" \
          --arg hardware "$hardware_id" --arg chip "$METAL_LLM_DETECTED_CHIP" \
          --argjson memory "$METAL_LLM_DETECTED_MEMORY_BYTES" --argjson system "$system_provenance" \
          --arg profile "$profile_id" --arg runtime_alias "$runtime_alias" \
          --arg context "$context" --arg vision "$vision_enabled" --arg mtp_policy "$mtp_policy" \
          --arg mtp_threshold "$mtp_threshold" \
          --arg runtime "$runtime_id" --arg runtime_revision "$runtime_revision" \
          --arg runtime_tree "$METAL_LLM_VERIFIED_RUNTIME_TREE" \
          --arg runtime_manifest_sha "$METAL_LLM_VERIFIED_RUNTIME_MANIFEST_SHA256" \
          --arg receipt_sha "$METAL_LLM_VERIFIED_BUILD_RECEIPT_SHA256" \
          --arg executable_name "${METAL_LLM_VERIFIED_EXECUTABLE:t}" \
          --arg executable_sha "$METAL_LLM_VERIFIED_EXECUTABLE_SHA256" \
          --arg model_manifest_sha "$model_manifest_sha" \
          --argjson artifacts "$METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES" \
          --arg suite "$suite_id" --arg suite_sha "$suite_sha" --argjson fixtures "$fixtures_json" '
          {
            repository: {revision: $repository_revision, tree_sha: $repository_tree, clean: true},
            hardware: {id: $hardware, chip: $chip, unified_memory_bytes: $memory},
            system: $system,
            profile_id: (if $profile == "__null__" then null else $profile end),
            runtime_alias: $runtime_alias,
            context: (if $context == "__null__" then null else ($context | tonumber) end),
            vision: (if $vision == "__null__" then null else ($vision == "true") end),
            mtp_policy: (if $mtp_policy == "__null__" then null else $mtp_policy end),
            mtp_threshold: (if $mtp_threshold == "__null__" then null else ($mtp_threshold | tonumber) end),
            runtime: {
              id: $runtime, tested_revision: $runtime_revision, tested_tree_sha: $runtime_tree,
              manifest_sha256: $runtime_manifest_sha, build_receipt_sha256: $receipt_sha,
              executable: {name: $executable_name, sha256: $executable_sha}
            },
            model_manifest_sha256: $model_manifest_sha,
            artifacts: $artifacts,
            suite: {id: $suite, sha256: $suite_sha, fixtures: $fixtures}
          }
        ') || return 1
    fi
    if [[ "$mode" == local && "$dry_run" == 0 ]]; then
        local identity_json
        identity_json=$(jq -cn \
          --arg owner_kind local-bench --arg model "$model_id" --arg runtime_alias "$runtime_alias" \
          --arg runtime "$runtime_id" \
          --arg runtime_revision "$METAL_LLM_VERIFIED_RUNTIME_REVISION" \
          --arg runtime_tree "$METAL_LLM_VERIFIED_RUNTIME_TREE" \
          --arg runtime_manifest_sha "$METAL_LLM_VERIFIED_RUNTIME_MANIFEST_SHA256" \
          --arg receipt_sha "$METAL_LLM_VERIFIED_BUILD_RECEIPT_SHA256" \
          --arg executable_name llama-bench --arg executable_sha "$METAL_LLM_VERIFIED_EXECUTABLE_SHA256" \
          --arg model_manifest_sha "$model_manifest_sha" \
          --argjson artifacts "$METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES" \
          --arg host "$host" --argjson port "$port" '
          {
            owner_kind: $owner_kind, model_id: $model, profile_id: null,
            runtime_alias: $runtime_alias, context: null, vision: null,
            mtp_policy: null, mtp_threshold: null,
            runtime_id: $runtime, runtime_revision: $runtime_revision, runtime_tree_sha: $runtime_tree,
            runtime_manifest_sha256: $runtime_manifest_sha, build_receipt_sha256: $receipt_sha,
            executable_name: $executable_name, executable_sha256: $executable_sha,
            model_manifest_sha256: $model_manifest_sha, artifacts: $artifacts, host: $host, port: $port
          }
        ') || return 1
        metal_llm_acquire_managed_lease "$identity_json" || return 1
        local managed_owner_token=$METAL_LLM_MANAGED_OWNER_TOKEN
        trap "metal_llm_release_managed_lease '$managed_owner_token'" EXIT
        trap "metal_llm_release_managed_lease '$managed_owner_token'; exit 130" HUP INT TERM
    fi
    local run_buffer
    run_buffer=$(mktemp "${TMPDIR:-/tmp}/metal-llm-bench-runs.XXXXXX") || return 1
    : > "$run_buffer"

    local case_record case_id case_kind optional streaming prompt_tokens generated_tokens repetitions notes
    local max_tokens temperature seed prompt fixture bench_output throughput
    local command_json payload response content output_sha image_data image_mime expected_fixture_sha
    local flash_value=off lazy_value=off
    typeset -a bench_arguments recorded_bench_arguments curl_arguments recorded_curl_arguments
    [[ "$flash_attention" == true ]] && flash_value=on
    [[ "$lazy_mmap" == true ]] && lazy_value=on
    while IFS= read -r case_record; do
        case_id=$(jq -r '.id' <<< "$case_record")
        case_kind=$(jq -r '.kind' <<< "$case_record")
        optional=$(jq -r '.optional // false' <<< "$case_record")
        [[ "$optional" == false || "$include_optional" == 1 ]] || continue
        notes=$(jq -r '.notes' <<< "$case_record")

        if [[ "$case_kind" == llama-bench ]]; then
            prompt_tokens=$(jq -r '.prompt_tokens' <<< "$case_record")
            generated_tokens=$(jq -r '.generated_tokens' <<< "$case_record")
            repetitions=$(jq -r '.repetitions' <<< "$case_record")
            (( repetitions == 3 )) && measurement_kind=three_run_mean || measurement_kind=single_run
            bench_arguments=(
              "$bench_executable" -m "$model_path" -ngl "$gpu_layers"
              -p "$prompt_tokens" -n "$generated_tokens" -b 512 -ub 512
              -r "$repetitions" -fa "$flash_value" -lm "$load_mode" -lzm "$lazy_value" -o json
            )
            recorded_bench_arguments=(
              llama-bench -m "artifact:$model_artifact_id" -ngl "$gpu_layers"
              -p "$prompt_tokens" -n "$generated_tokens" -b 512 -ub 512
              -r "$repetitions" -fa "$flash_value" -lm "$load_mode" -lzm "$lazy_value" -o json
            )
            if (( dry_run == 1 )); then
                metal_llm_print_command "${bench_arguments[@]}"
                continue
            fi
            bench_output=$("${bench_arguments[@]}") || { rm -f -- "$run_buffer"; return 1; }
            throughput=$(jq -er 'if type == "array" then .[0].avg_ts else .avg_ts end |
              select(type == "number" and . >= 0)' <<< "$bench_output") || {
                rm -f -- "$run_buffer"
                metal_llm_die "could not parse llama-bench output for case: $case_id"
                return 1
            }
            command_json=$(metal_llm_command_json "${recorded_bench_arguments[@]}") || {
                rm -f -- "$run_buffer"
                return 1
            }
            jq -n \
              --arg id "$case_id" --arg timestamp "$now" --arg repo "$repository_revision" \
              --arg hardware "$hardware_id" --arg runtime "$runtime_id" --arg runtime_revision "$runtime_revision" \
              --arg runtime_alias "$runtime_alias" --arg notes "$notes" --arg kind "$measurement_kind" \
              --argjson prompt "$prompt_tokens" --argjson generated "$generated_tokens" --argjson throughput "$throughput" \
              --argjson repetitions "$repetitions" \
              --argjson command "$command_json" '
              {
                id: $id, experiment: "suite-run", measurement_kind: $kind,
                timestamp: $timestamp, repository_revision: $repo,
                hardware_id: $hardware, runtime_id: $runtime, runtime_revision: $runtime_revision,
                profile: null, profile_id: null, runtime_alias: $runtime_alias,
                context: null, vision: null, mtp_policy: null, mtp_selected: null,
                mtp_threshold: null, prompt_tokens: $prompt, effective_prompt_tokens: null,
                generated_tokens: $generated,
                prompt_tokens_per_second: (if $prompt > 0 then $throughput else null end),
                generation_tokens_per_second: (if $generated > 0 then $throughput else null end),
                command: $command,
                generation_settings: {temperature: 0, seed: 1234, max_tokens: $generated, reasoning: false, repetitions: $repetitions},
                notes: $notes
              }
            ' >> "$run_buffer" || { rm -f -- "$run_buffer"; return 1; }
        else
            prompt=$(jq -r '.prompt' <<< "$case_record")
            max_tokens=$(jq -r '.max_tokens' <<< "$case_record")
            temperature=$(jq -r '.temperature' <<< "$case_record")
            seed=$(jq -r '.seed' <<< "$case_record")
            fixture=$(jq -r '.fixture // empty' <<< "$case_record")
            streaming=$(jq -r '.stream // false' <<< "$case_record")
            if (( dry_run == 1 )); then
                print -- "HTTP POST http://$host:$port/v1/chat/completions case=$case_id max_tokens=$max_tokens temperature=$temperature seed=$seed stream=$streaming"
                continue
            fi
            if [[ "$case_kind" == vision && ! -f "$METAL_LLM_ROOT/$fixture" ]]; then
                rm -f -- "$run_buffer"
                metal_llm_die "vision fixture is missing: $fixture"
                return 1
            fi
            image_data=''
            image_mime=''
            if [[ "$case_kind" == vision ]]; then
                command -v base64 >/dev/null 2>&1 || {
                    rm -f -- "$run_buffer"
                    metal_llm_die 'base64 is required for vision benchmark fixtures'
                    return 1
                }
                metal_llm_validate_vision_fixture "$fixture" || { rm -f -- "$run_buffer"; return 1; }
                expected_fixture_sha=$(jq -er --arg path "$fixture" \
                  'first(.[] | select(.path == $path)).sha256' <<< "$fixtures_json") || {
                    rm -f -- "$run_buffer"
                    return 1
                }
                [[ "$METAL_LLM_VERIFIED_FIXTURE_SHA256" == "$expected_fixture_sha" ]] || {
                    rm -f -- "$run_buffer"
                    metal_llm_die "vision fixture changed after verification: $fixture"
                    return 1
                }
                image_mime=$METAL_LLM_VERIFIED_FIXTURE_MIME
                image_data=$(base64 < "$METAL_LLM_VERIFIED_FIXTURE_PATH" | tr -d '\r\n') || {
                    rm -f -- "$run_buffer"
                    return 1
                }
                payload=$(jq -cn --arg model "$model_id" --arg prompt "$prompt" \
                  --arg image_url "data:$image_mime;base64,$image_data" \
                  --argjson max_tokens "$max_tokens" --argjson temperature "$temperature" \
                  --argjson seed "$seed" --argjson stream "$streaming" '
                  {model: $model, messages: [{role: "user", content: [
                    {type: "text", text: $prompt}, {type: "image_url", image_url: {url: $image_url}}
                  ]}], max_tokens: $max_tokens, temperature: $temperature, seed: $seed} +
                  (if $stream then {stream: true, stream_options: {include_usage: true}} else {} end)
                ') || { rm -f -- "$run_buffer"; return 1; }
            else
                payload=$(jq -cn --arg model "$model_id" --arg prompt "$prompt" \
                  --argjson max_tokens "$max_tokens" --argjson temperature "$temperature" \
                  --argjson seed "$seed" --argjson stream "$streaming" '
                  {model: $model, messages: [{role: "user", content: $prompt}], max_tokens: $max_tokens,
                   temperature: $temperature, seed: $seed} +
                  (if $stream then {stream: true, stream_options: {include_usage: true}} else {} end)
                ') || { rm -f -- "$run_buffer"; return 1; }
            fi
            curl_arguments=(-fsS "http://$host:$port/v1/chat/completions" -H 'Content-Type: application/json')
            [[ -z "${METAL_LLM_API_KEY:-}" ]] || curl_arguments+=(-H "Authorization: Bearer $METAL_LLM_API_KEY")
            curl_arguments+=(-d "$payload")
            recorded_curl_arguments=(curl -fsS "http://$host:$port/v1/chat/completions" -H 'Content-Type: application/json')
            [[ -z "${METAL_LLM_API_KEY:-}" ]] || recorded_curl_arguments+=(-H 'Authorization: Bearer <redacted>')
            recorded_curl_arguments+=(-d "$payload")
            response=$(curl "${curl_arguments[@]}") || {
                rm -f -- "$run_buffer"
                metal_llm_die "API benchmark failed for case: $case_id"
                return 1
            }
            metal_llm_parse_endpoint_response "$response" "$streaming" || {
                rm -f -- "$run_buffer"
                return 1
            }
            content=$METAL_LLM_BENCH_RESPONSE_CONTENT
            output_sha=$(print -rn -- "$content" | shasum -a 256 | awk '{print $1}') || {
                rm -f -- "$run_buffer"
                return 1
            }
            prompt_tokens=$(jq -er '.prompt_tokens' <<< "$METAL_LLM_BENCH_RESPONSE_USAGE") || prompt_tokens=null
            generated_tokens=$(jq -er '.completion_tokens' <<< "$METAL_LLM_BENCH_RESPONSE_USAGE") || generated_tokens=null
            metal_llm_validate_endpoint_timing "$METAL_LLM_BENCH_RESPONSE_TIMING" \
              "$mtp_policy" "$mtp_threshold" "$case_kind" "$vision_image_min_tokens" || {
                rm -f -- "$run_buffer"
                return 1
            }
            command_json=$(metal_llm_command_json "${recorded_curl_arguments[@]}") || {
                rm -f -- "$run_buffer"
                return 1
            }
            jq -n \
              --arg id "$case_id" --arg timestamp "$now" --arg repo "$repository_revision" \
              --arg hardware "$hardware_id" --arg runtime "$runtime_id" --arg runtime_revision "$runtime_revision" \
              --arg profile_id "$profile_id" --arg runtime_alias "$runtime_alias" \
              --argjson context "$context" --argjson vision "$vision_enabled" \
              --arg mtp_policy "$mtp_policy" --argjson mtp_selected "$METAL_LLM_BENCH_MTP_SELECTED" \
              --argjson effective_prompt_tokens "$METAL_LLM_BENCH_EFFECTIVE_PROMPT_TOKENS" \
              --argjson mtp_threshold "${mtp_threshold/__null__/null}" \
              --arg notes "$notes; API response did not expose phase throughput" \
              --arg sha "$output_sha" --argjson prompt "$prompt_tokens" --argjson generated "$generated_tokens" \
              --argjson temperature "$temperature" --argjson seed "$seed" --argjson max_tokens "$max_tokens" \
              --argjson command "$command_json" '
              {
                id: $id, experiment: "suite-run", measurement_kind: "single_run",
                timestamp: $timestamp, repository_revision: $repo,
                hardware_id: $hardware, runtime_id: $runtime, runtime_revision: $runtime_revision,
                profile: null, profile_id: $profile_id, runtime_alias: $runtime_alias,
                context: $context, vision: $vision, mtp_policy: $mtp_policy,
                mtp_selected: $mtp_selected, mtp_threshold: $mtp_threshold,
                prompt_tokens: $prompt, effective_prompt_tokens: $effective_prompt_tokens,
                generated_tokens: $generated,
                prompt_tokens_per_second: null, generation_tokens_per_second: null,
                output_sha256: $sha,
                command: $command,
                generation_settings: {temperature: $temperature, seed: $seed, max_tokens: $max_tokens, reasoning: false},
                notes: $notes
              }
            ' >> "$run_buffer" || { rm -f -- "$run_buffer"; return 1; }
        fi
    done < <(jq -c --arg mode "$mode" '.cases[] | select(.mode == $mode)' "$suite_file")

    (( dry_run == 1 )) && { rm -f -- "$run_buffer"; return; }
    [[ -s "$run_buffer" ]] || {
        rm -f -- "$run_buffer"
        metal_llm_die 'benchmark suite produced no runs'
        return 1
    }
    local results_dir=${METAL_LLM_RESULTS_DIR:-$METAL_LLM_ROOT/results/raw}
    mkdir -p "$results_dir"
    local compact_timestamp=${now//[-:]/}
    local result_path="$results_dir/$compact_timestamp-$suite_id-$mode-$model_id.json"
    local result_part
    result_part=$(mktemp "$result_path.part.XXXXXX") || { rm -f -- "$run_buffer"; return 1; }
    if ! jq -s \
      --arg experiment_id "$compact_timestamp-$suite_id" --arg date "${now[1,10]}" \
      --arg model "$model_id" --arg suite "$suite_id" --arg mode "$mode" \
      --argjson provenance "$provenance_json" '
      {schema_version: 1, experiment_id: ($experiment_id | ascii_downcase), date: $date,
       model_id: $model, suite_id: $suite, benchmark_mode: $mode, provenance: $provenance, runs: .}
    ' "$run_buffer" > "$result_part"; then
        rm -f -- "$run_buffer" "$result_part"
        return 1
    fi
    rm -f -- "$run_buffer"
    if ! metal_llm_validate_result "$result_part" 'pending benchmark result'; then
        rm -f -- "$result_part"
        return 1
    fi
    metal_llm_publish_benchmark_result "$result_part" "$result_path" || return 1
    print -- "wrote benchmark result: $result_path"
}
