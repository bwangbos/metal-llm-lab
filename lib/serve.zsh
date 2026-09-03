metal_llm_serve_usage() {
    metal_llm_error 'usage: metal-llm serve MODEL --profile PROFILE [--dry-run] [-- EXTRA_LLAMA_ARGS]'
    return 2
}

metal_llm_detect_recommended_profile() {
    command -v system_profiler >/dev/null 2>&1 || {
        metal_llm_die 'system_profiler is required to resolve profile auto'
        return 1
    }

    local system_details chip='' memory='' line memory_gib memory_bytes
    system_details=$(system_profiler SPHardwareDataType 2>/dev/null) || {
        metal_llm_die 'could not detect hardware for profile auto'
        return 1
    }
    for line in "${(@f)system_details}"; do
        if [[ -z "$chip" && "$line" =~ '^[[:space:]]*Chip: (.+)$' ]]; then
            chip=$match[1]
        elif [[ -z "$memory" && "$line" =~ '^[[:space:]]*Memory: (.+)$' ]]; then
            memory=$match[1]
        fi
    done
    [[ -n "$chip" && "$memory" =~ '^([0-9]+) GB$' ]] || {
        metal_llm_die 'could not match detected hardware for profile auto'
        return 1
    }
    memory_gib=$match[1]
    memory_bytes=$(( memory_gib * 1024 * 1024 * 1024 ))

    local architecture hardware_manifest recommended_profile=''
    architecture=$(uname -m 2>/dev/null || print -- unknown)
    for hardware_manifest in "$METAL_LLM_ROOT"/manifests/hardware/*.json(N); do
        if jq -e --arg chip "$chip" --arg architecture "$architecture" --argjson memory "$memory_bytes" '
            .chip == $chip and .architecture == $architecture and .unified_memory_bytes == $memory and
            (.recommended_profile | type == "string" and length > 0)
        ' "$hardware_manifest" >/dev/null 2>&1; then
            recommended_profile=$(jq -er '.recommended_profile' "$hardware_manifest") || return 1
            break
        fi
    done
    [[ -n "$recommended_profile" ]] || {
        metal_llm_die "no hardware manifest matches $chip with $memory"
        return 1
    }
    print -- "$recommended_profile"
}

metal_llm_artifact_path() {
    local manifest=$1
    local artifact_dir=$2
    local artifact_id=$3
    local artifact_record artifact_filename expected_bytes expected_sha artifact_path actual_bytes actual_sha

    artifact_record=$(jq -er --arg id "$artifact_id" '
        first(.artifacts[] | select(.id == $id)) |
        [.filename, (.bytes | tostring), .sha256] | @tsv
    ' "$manifest" 2>/dev/null) || {
        metal_llm_die "artifact not found in manifest: $artifact_id"
        return 1
    }
    IFS=$'\t' read -r artifact_filename expected_bytes expected_sha <<< "$artifact_record"
    artifact_path="$artifact_dir/$artifact_filename"
    [[ -f "$artifact_path" ]] || {
        metal_llm_die "artifact is missing: $artifact_id ($artifact_path)"
        return 1
    }
    actual_bytes=$(metal_llm_file_size "$artifact_path") || return 1
    [[ "$actual_bytes" == "$expected_bytes" ]] || {
        metal_llm_die "byte count mismatch for $artifact_id: expected $expected_bytes, got $actual_bytes"
        return 1
    }
    actual_sha=$(metal_llm_sha256 "$artifact_path") || return 1
    [[ "$actual_sha" == "$expected_sha" ]] || {
        metal_llm_die "checksum mismatch for $artifact_id: expected $expected_sha, got $actual_sha"
        return 1
    }
    print -- "$artifact_path"
}

metal_llm_print_serve_command() {
    typeset -a command_arguments display_arguments
    command_arguments=("$@")
    display_arguments=()
    local index=1
    while (( index <= ${#command_arguments} )); do
        if [[ "${command_arguments[$index]}" == '--api-key' ]]; then
            display_arguments+=(--api-key '<redacted>')
            (( index += 2 ))
        elif [[ "${command_arguments[$index]}" == --api-key=* ]]; then
            display_arguments+=('--api-key=<redacted>')
            (( ++index ))
        else
            display_arguments+=("${command_arguments[$index]}")
            (( ++index ))
        fi
    done
    metal_llm_print_command "${display_arguments[@]}"
}

metal_llm_serve() {
    local model_id='' profile_id='' dry_run=0 passthrough=0 argument
    typeset -a extra_arguments
    extra_arguments=()

    while (( $# > 0 )); do
        argument=$1
        shift
        if (( passthrough == 1 )); then
            extra_arguments+=("$argument")
            continue
        fi
        case "$argument" in
            --)
                passthrough=1
                ;;
            --dry-run)
                (( dry_run == 0 )) || { metal_llm_serve_usage; return $?; }
                dry_run=1
                ;;
            --profile)
                (( $# > 0 )) || { metal_llm_serve_usage; return $?; }
                [[ -z "$profile_id" ]] || { metal_llm_serve_usage; return $?; }
                profile_id=$1
                shift
                ;;
            -*) metal_llm_serve_usage; return $? ;;
            *)
                [[ -z "$model_id" ]] || { metal_llm_serve_usage; return $?; }
                model_id=$argument
                ;;
        esac
    done

    [[ -n "$model_id" && -n "$profile_id" ]] || { metal_llm_serve_usage; return $?; }
    metal_llm_valid_id "$model_id" || { metal_llm_die "invalid model id: $model_id"; return 1; }
    metal_llm_require_supported_host || return 1
    command -v jq >/dev/null 2>&1 || { metal_llm_die 'jq is required'; return 1; }

    local model_manifest="$METAL_LLM_ROOT/manifests/models/$model_id.json"
    [[ -f "$model_manifest" ]] || { metal_llm_die "model manifest not found: $model_id"; return 1; }
    metal_llm_validate_model_manifest "$model_manifest" "$model_id" || {
        metal_llm_die "invalid model manifest: $model_manifest"
        return 1
    }

    if [[ "$profile_id" == auto ]]; then
        profile_id=$(metal_llm_detect_recommended_profile) || return 1
    fi

    local profile_record
    profile_record=$(jq -er --arg id "$profile_id" '
        first(.profiles[] | select(.id == $id)) |
        [
          .runtime_id, .model_artifact_id, (.context | tostring),
          (.vision.enabled | tostring), (.vision.projector_artifact_id // "__null__"),
          (if .vision.image_min_tokens == null then "__null__" else (.vision.image_min_tokens | tostring) end),
          (.mtp.enabled | tostring), (.mtp.artifact_id // "__null__"), (.mtp.spec_type // "__null__"),
          (if .mtp.draft_n_max == null then "__null__" else (.mtp.draft_n_max | tostring) end),
          (if .mtp.gpu_layers == null then "__null__" else (.mtp.gpu_layers | tostring) end),
          (.metal.gpu_layers | tostring), (.metal.fit | tostring),
          (.metal.flash_attention | tostring), (.metal.load_mode | tostring),
          (.metal.lazy_mmap | tostring)
        ] | @tsv
    ' "$model_manifest" 2>/dev/null) || {
        metal_llm_die "profile not found: $profile_id"
        return 1
    }

    local runtime_id model_artifact_id profile_context vision_enabled projector_artifact_id image_min_tokens
    local mtp_enabled mtp_artifact_id spec_type draft_n_max draft_gpu_layers
    local gpu_layers fit flash_attention load_mode lazy_mmap
    IFS=$'\t' read -r runtime_id model_artifact_id profile_context \
        vision_enabled projector_artifact_id image_min_tokens \
        mtp_enabled mtp_artifact_id spec_type draft_n_max draft_gpu_layers \
        gpu_layers fit flash_attention load_mode lazy_mmap <<< "$profile_record"

    local runtime_manifest="$METAL_LLM_ROOT/manifests/runtimes/$runtime_id.json"
    [[ -f "$runtime_manifest" ]] || { metal_llm_die "runtime manifest not found: $runtime_id"; return 1; }
    metal_llm_validate_runtime_manifest "$runtime_manifest" "$runtime_id" || {
        metal_llm_die "invalid runtime manifest: $runtime_manifest"
        return 1
    }
    local server_executable="$METAL_LLM_ROOT/.lab/runtimes/$runtime_id/build-metal/bin/llama-server"
    [[ -x "$server_executable" ]] || {
        metal_llm_die "server executable is missing: $server_executable"
        return 1
    }

    local artifact_dir="$METAL_LLM_ROOT/.lab/artifacts/$model_id"
    local text_artifact_id
    while IFS= read -r text_artifact_id; do
        metal_llm_artifact_path "$model_manifest" "$artifact_dir" "$text_artifact_id" >/dev/null || return 1
    done < <(jq -er '.text_model.artifact_ids[]' "$model_manifest")

    local model_path projector_path='' mtp_path=''
    model_path=$(metal_llm_artifact_path "$model_manifest" "$artifact_dir" "$model_artifact_id") || return 1
    if [[ "$vision_enabled" == true ]]; then
        projector_path=$(metal_llm_artifact_path "$model_manifest" "$artifact_dir" "$projector_artifact_id") || return 1
    fi
    if [[ "$mtp_enabled" == true ]]; then
        mtp_path=$(metal_llm_artifact_path "$model_manifest" "$artifact_dir" "$mtp_artifact_id") || return 1
    fi

    local context=${METAL_LLM_CONTEXT:-$profile_context}
    local host=${METAL_LLM_HOST:-127.0.0.1}
    local port=${METAL_LLM_PORT:-8080}
    local parallel=${METAL_LLM_PARALLEL:-1}
    [[ "$context" == <-> && "$context" -gt 0 ]] || { metal_llm_die 'METAL_LLM_CONTEXT must be a positive integer'; return 1; }
    [[ -n "$host" ]] || { metal_llm_die 'METAL_LLM_HOST must not be empty'; return 1; }
    [[ "$port" == <-> && "$port" -ge 1 && "$port" -le 65535 ]] || { metal_llm_die 'METAL_LLM_PORT must be an integer from 1 to 65535'; return 1; }
    [[ "$parallel" == <-> && "$parallel" -gt 0 ]] || { metal_llm_die 'METAL_LLM_PARALLEL must be a positive integer'; return 1; }

    local fit_value=off flash_attention_value=off lazy_mmap_value=off
    [[ "$fit" == true ]] && fit_value=on
    [[ "$flash_attention" == true ]] && flash_attention_value=on
    [[ "$lazy_mmap" == true ]] && lazy_mmap_value=on

    typeset -a command_arguments
    command_arguments=(
        "$server_executable" -m "$model_path"
        -ngl "$gpu_layers" -fit "$fit_value" -fa "$flash_attention_value"
        -lm "$load_mode" -lzm "$lazy_mmap_value"
        -c "$context" -np "$parallel" --host "$host" --port "$port"
    )
    if [[ "$vision_enabled" == true ]]; then
        command_arguments+=(-mm "$projector_path" --image-min-tokens "$image_min_tokens")
    fi
    if [[ "$mtp_enabled" == true ]]; then
        command_arguments+=(
            --spec-draft-model "$mtp_path" --spec-type "$spec_type"
            --spec-draft-n-max "$draft_n_max" --spec-draft-ngl "$draft_gpu_layers"
        )
    fi
    local api_key=${METAL_LLM_API_KEY:-}
    [[ -z "$api_key" ]] || command_arguments+=(--api-key "$api_key")
    command_arguments+=("${extra_arguments[@]}")

    if (( dry_run == 1 )); then
        metal_llm_print_serve_command "${command_arguments[@]}"
        return
    fi
    exec "${command_arguments[@]}"
}
