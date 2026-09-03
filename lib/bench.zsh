metal_llm_bench_usage() {
    metal_llm_error 'usage: metal-llm bench MODEL --suite SUITE [--mode MODE] [--dry-run]'
    return 2
}

metal_llm_validate_benchmark_suite() {
    local suite_file=$1
    local expected_id=$2
    jq -e --arg expected_id "$expected_id" '
      .schema_version == 1 and .id == $expected_id and
      (.default_mode == "local" or .default_mode == "endpoint") and
      (.default_profile | type == "string" and test("^[a-z0-9]+([.-][a-z0-9]+)*$")) and
      (.cases | type == "array" and length > 0 and all(.[];
        (.id | type == "string" and test("^[a-z0-9]+([.-][a-z0-9]+)*$")) and
        (.mode == "local" or .mode == "endpoint") and
        (.kind == "llama-bench" or .kind == "api" or .kind == "vision") and
        (if .mode == "local" then .kind == "llama-bench" else (.kind == "api" or .kind == "vision") end) and
        (.notes | type == "string" and length > 0) and
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

metal_llm_verified_bench_path() {
    local runtime_id=$1
    local runtime_manifest=$2
    local build_dir="$METAL_LLM_ROOT/.lab/runtimes/$runtime_id/build-metal"
    local receipt_path="$build_dir/build-receipt.json"
    local bench_executable="$build_dir/bin/llama-bench"

    [[ -f "$receipt_path" ]] || {
        metal_llm_die "build receipt is missing: $runtime_id ($receipt_path)"
        return 1
    }
    local expected_tree expected_revision receipt_runtime receipt_tree receipt_bench_sha
    expected_tree=$(jq -er '.tested_tree_sha' "$runtime_manifest") || return 1
    expected_revision=$(jq -er '.tested_revision' "$runtime_manifest") || return 1
    IFS=$'\t' read -r receipt_runtime receipt_tree receipt_bench_sha <<< "$(jq -er '[
      .runtime_id, .tested_tree_sha, .binaries["llama-bench"].sha256
    ] | @tsv' "$receipt_path")" || return 1
    [[ "$receipt_runtime" == "$runtime_id" && "$receipt_tree" == "$expected_tree" ]] || {
        metal_llm_die "build receipt does not match runtime manifest: $runtime_id"
        return 1
    }
    [[ -x "$bench_executable" ]] || {
        metal_llm_die "benchmark executable is missing: $bench_executable"
        return 1
    }
    local actual_sha
    actual_sha=$(metal_llm_sha256 "$bench_executable") || return 1
    [[ "$actual_sha" == "$receipt_bench_sha" ]] || {
        metal_llm_die "benchmark binary checksum mismatch for $runtime_id"
        return 1
    }
    print -- "$bench_executable"
}

metal_llm_bench_port_is_owned() {
    local host=$1
    local port=$2
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsS --connect-timeout 1 --max-time 1 "http://$host:$port/health" >/dev/null 2>&1
}

metal_llm_bench() {
    local model_id='' suite_id='' mode='' dry_run=0 argument
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

    local profile_id=${METAL_LLM_PROFILE:-}
    [[ -n "$profile_id" ]] || profile_id=$(jq -er '.default_profile' "$suite_file") || return 1
    local profile_record
    profile_record=$(jq -er --arg id "$profile_id" '
      first(.profiles[] | select(.id == $id)) |
      [
        .runtime_id, .model_artifact_id, (.metal.gpu_layers | tostring),
        (.metal.flash_attention | tostring), (.metal.load_mode | tostring),
        (.metal.lazy_mmap | tostring), (.mtp.enabled | tostring),
        (.mtp.artifact_id // "__null__"), (.mtp.spec_type // "__null__"),
        (if .mtp.draft_n_max == null then "__null__" else (.mtp.draft_n_max | tostring) end),
        (.mtp.gpu_layers // "__null__")
      ] | @tsv
    ' "$model_manifest" 2>/dev/null) || {
        metal_llm_die "profile not found: $profile_id"
        return 1
    }
    local runtime_id model_artifact_id gpu_layers flash_attention load_mode lazy_mmap
    local mtp_enabled mtp_artifact_id spec_type draft_n_max draft_gpu_layers
    IFS=$'\t' read -r runtime_id model_artifact_id gpu_layers flash_attention load_mode lazy_mmap \
      mtp_enabled mtp_artifact_id spec_type draft_n_max draft_gpu_layers <<< "$profile_record"

    local runtime_manifest="$METAL_LLM_ROOT/manifests/runtimes/$runtime_id.json"
    [[ -f "$runtime_manifest" ]] || { metal_llm_die "runtime manifest not found: $runtime_id"; return 1; }
    metal_llm_validate_runtime_manifest "$runtime_manifest" "$runtime_id" || {
        metal_llm_die "invalid runtime manifest: $runtime_manifest"
        return 1
    }
    local bench_executable='' model_path='' mtp_path=''
    if [[ "$mode" == local ]]; then
        bench_executable=$(metal_llm_verified_bench_path "$runtime_id" "$runtime_manifest") || return 1
        local artifact_dir="$METAL_LLM_ROOT/.lab/artifacts/$model_id"
        model_path=$(metal_llm_artifact_path "$model_manifest" "$artifact_dir" "$model_artifact_id") || return 1
        if [[ "$mtp_enabled" == true ]]; then
            mtp_path=$(metal_llm_artifact_path "$model_manifest" "$artifact_dir" "$mtp_artifact_id") || return 1
        fi
    fi

    local hardware_id=${METAL_LLM_HARDWARE_ID:-}
    if [[ -z "$hardware_id" ]]; then
        typeset -a hardware_manifests
        hardware_manifests=("$METAL_LLM_ROOT"/manifests/hardware/*.json(N))
        (( ${#hardware_manifests} == 1 )) || {
            metal_llm_die 'METAL_LLM_HARDWARE_ID is required when more than one hardware manifest exists'
            return 1
        }
        hardware_id=$(jq -er '.id' "$hardware_manifests[1]") || return 1
    fi
    metal_llm_valid_id "$hardware_id" || { metal_llm_die "invalid hardware id: $hardware_id"; return 1; }
    [[ -f "$METAL_LLM_ROOT/manifests/hardware/$hardware_id.json" ]] || {
        metal_llm_die "unknown hardware id: $hardware_id"
        return 1
    }

    local host=${METAL_LLM_HOST:-127.0.0.1}
    local port=${METAL_LLM_PORT:-8080}
    [[ "$port" == <-> && "$port" -ge 1 && "$port" -le 65535 ]] || {
        metal_llm_die 'METAL_LLM_PORT must be an integer from 1 to 65535'
        return 1
    }
    if (( dry_run == 0 )); then
        if [[ "$mode" == local ]] && metal_llm_bench_port_is_owned "$host" "$port"; then
            metal_llm_die "configured port is owned by a running lab server: $host:$port"
            return 1
        elif [[ "$mode" == endpoint ]] && ! metal_llm_bench_port_is_owned "$host" "$port"; then
            metal_llm_die "endpoint mode requires a running endpoint: $host:$port"
            return 1
        fi
    fi

    local now=${METAL_LLM_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
    [[ "$now" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' ]] || {
        metal_llm_die 'METAL_LLM_NOW must be an RFC 3339 UTC timestamp'
        return 1
    }
    local repository_revision=${METAL_LLM_REPOSITORY_REVISION:-}
    [[ -n "$repository_revision" ]] || repository_revision=$(git -C "$METAL_LLM_ROOT" rev-parse HEAD 2>/dev/null) || {
        metal_llm_die 'could not resolve repository revision'
        return 1
    }
    [[ "$repository_revision" =~ '^[0-9a-f]{40}$' ]] || {
        metal_llm_die 'repository revision must be a 40-character Git SHA'
        return 1
    }
    local runtime_revision
    runtime_revision=$(jq -er '.tested_revision' "$runtime_manifest") || return 1
    local measurement_kind=single_run

    local include_optional=${METAL_LLM_INCLUDE_OPTIONAL:-0}
    [[ "$include_optional" == 0 || "$include_optional" == 1 ]] || {
        metal_llm_die 'METAL_LLM_INCLUDE_OPTIONAL must be 0 or 1'
        return 1
    }
    local run_buffer
    run_buffer=$(mktemp "${TMPDIR:-/tmp}/metal-llm-bench-runs.XXXXXX") || return 1
    : > "$run_buffer"

    local case_record case_id case_kind optional prompt_tokens generated_tokens repetitions notes
    local max_tokens temperature seed prompt fixture bench_output throughput
    local flash_value=off lazy_value=off
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
            typeset -a bench_arguments
            bench_arguments=(
              "$bench_executable" -m "$model_path" -ngl "$gpu_layers"
              -p "$prompt_tokens" -n "$generated_tokens" -b 512 -ub 512
              -r "$repetitions" -fa "$flash_value" -lm "$load_mode" -lzm "$lazy_value" -o json
            )
            if [[ "$mtp_enabled" == true ]]; then
                bench_arguments+=(
                  -md "$mtp_path" --spec-type "$spec_type"
                  --spec-draft-n-max "$draft_n_max" -ngld "$draft_gpu_layers"
                )
            fi
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
            jq -n \
              --arg id "$case_id" --arg timestamp "$now" --arg repo "$repository_revision" \
              --arg hardware "$hardware_id" --arg runtime "$runtime_id" --arg runtime_revision "$runtime_revision" \
              --arg profile "$profile_id" --arg notes "$notes" --arg kind "$measurement_kind" \
              --argjson prompt "$prompt_tokens" --argjson generated "$generated_tokens" --argjson throughput "$throughput" \
              --argjson repetitions "$repetitions" --argjson mtp "$mtp_enabled" '
              {
                id: $id, experiment: "suite-run", measurement_kind: $kind,
                timestamp: $timestamp, repository_revision: $repo,
                hardware_id: $hardware, runtime_id: $runtime, runtime_revision: $runtime_revision,
                profile: $profile, effective_prompt_tokens: $prompt, generated_tokens: $generated,
                prompt_tokens_per_second: (if $prompt > 0 then $throughput else null end),
                generation_tokens_per_second: (if $generated > 0 then $throughput else null end),
                mtp: $mtp,
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
            if (( dry_run == 1 )); then
                print -- "HTTP POST http://$host:$port/v1/chat/completions case=$case_id max_tokens=$max_tokens temperature=$temperature seed=$seed"
                continue
            fi
            if [[ "$case_kind" == vision && ! -f "$METAL_LLM_ROOT/$fixture" ]]; then
                rm -f -- "$run_buffer"
                metal_llm_die "vision fixture is missing: $fixture"
                return 1
            fi
            local payload response content output_sha image_data='' image_mime=''
            if [[ "$case_kind" == vision ]]; then
                command -v base64 >/dev/null 2>&1 || {
                    rm -f -- "$run_buffer"
                    metal_llm_die 'base64 is required for vision benchmark fixtures'
                    return 1
                }
                case "$fixture" in
                    *.png) image_mime='image/png' ;;
                    *.jpg|*.jpeg) image_mime='image/jpeg' ;;
                    *)
                        rm -f -- "$run_buffer"
                        metal_llm_die "unsupported vision fixture type: $fixture"
                        return 1
                        ;;
                esac
                image_data=$(base64 < "$METAL_LLM_ROOT/$fixture" | tr -d '\r\n') || {
                    rm -f -- "$run_buffer"
                    return 1
                }
                payload=$(jq -cn --arg model "$model_id" --arg prompt "$prompt" \
                  --arg image_url "data:$image_mime;base64,$image_data" \
                  --argjson max_tokens "$max_tokens" --argjson temperature "$temperature" --argjson seed "$seed" '
                  {model: $model, messages: [{role: "user", content: [
                    {type: "text", text: $prompt}, {type: "image_url", image_url: {url: $image_url}}
                  ]}], max_tokens: $max_tokens, temperature: $temperature, seed: $seed}
                ') || { rm -f -- "$run_buffer"; return 1; }
            else
                payload=$(jq -cn --arg model "$model_id" --arg prompt "$prompt" \
                  --argjson max_tokens "$max_tokens" --argjson temperature "$temperature" --argjson seed "$seed" '
                  {model: $model, messages: [{role: "user", content: $prompt}], max_tokens: $max_tokens,
                   temperature: $temperature, seed: $seed}
                ') || { rm -f -- "$run_buffer"; return 1; }
            fi
            response=$(curl -fsS "http://$host:$port/v1/chat/completions" -H 'Content-Type: application/json' -d "$payload") || {
                rm -f -- "$run_buffer"
                metal_llm_die "API benchmark failed for case: $case_id"
                return 1
            }
            content=$(jq -er '.choices[0].message.content' <<< "$response") || {
                rm -f -- "$run_buffer"
                metal_llm_die "invalid API response for case: $case_id"
                return 1
            }
            output_sha=$(print -rn -- "$content" | shasum -a 256 | awk '{print $1}') || {
                rm -f -- "$run_buffer"
                return 1
            }
            prompt_tokens=$(jq -er '.usage.prompt_tokens' <<< "$response") || prompt_tokens=null
            generated_tokens=$(jq -er '.usage.completion_tokens' <<< "$response") || generated_tokens=null
            jq -n \
              --arg id "$case_id" --arg timestamp "$now" --arg repo "$repository_revision" \
              --arg hardware "$hardware_id" --arg runtime "$runtime_id" --arg runtime_revision "$runtime_revision" \
              --arg profile "$profile_id" --arg notes "$notes; API response did not expose phase throughput" \
              --arg sha "$output_sha" --argjson prompt "$prompt_tokens" --argjson generated "$generated_tokens" \
              --argjson temperature "$temperature" --argjson seed "$seed" --argjson max_tokens "$max_tokens" \
              --argjson mtp "$mtp_enabled" '
              {
                id: $id, experiment: "suite-run", measurement_kind: "single_run",
                timestamp: $timestamp, repository_revision: $repo,
                hardware_id: $hardware, runtime_id: $runtime, runtime_revision: $runtime_revision,
                profile: $profile, effective_prompt_tokens: $prompt, generated_tokens: $generated,
                prompt_tokens_per_second: null, generation_tokens_per_second: null,
                mtp: $mtp, output_sha256: $sha,
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
      --arg model "$model_id" --arg suite "$suite_id" --arg mode "$mode" '
      {schema_version: 1, experiment_id: ($experiment_id | ascii_downcase), date: $date,
       model_id: $model, suite_id: $suite, benchmark_mode: $mode, runs: .}
    ' "$run_buffer" > "$result_part"; then
        rm -f -- "$run_buffer" "$result_part"
        return 1
    fi
    rm -f -- "$run_buffer"
    mv -f -- "$result_part" "$result_path" || return 1
    print -- "wrote benchmark result: $result_path"
}
