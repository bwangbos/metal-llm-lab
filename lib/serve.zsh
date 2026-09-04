metal_llm_serve_usage() {
    metal_llm_error 'usage: metal-llm serve MODEL [--profile auto|fast|long|stable] [--vision on|off] [--dry-run] [-- EXTRA_LLAMA_ARGS]'
    metal_llm_error '       metal-llm serve MODEL --profile custom --runtime tuned|upstream --mtp on|off|dynamic --context TOKENS [--vision on|off] [--dry-run] [-- EXTRA_LLAMA_ARGS]'
    return 2
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

metal_llm_validate_serve_extra_arguments() {
    local argument value
    while (( $# > 0 )); do
        argument=$1
        shift
        case "$argument" in
            -t|--threads|-tb|--threads-batch|--threads-http)
                (( $# > 0 )) || {
                    metal_llm_die 'unsupported serve passthrough option or value'
                    return 1
                }
                value=$1
                shift
                [[ "$value" == <-> && "$value" -gt 0 ]] || {
                    metal_llm_die 'unsupported serve passthrough option or value'
                    return 1
                }
                ;;
            --threads=*|--threads-batch=*|--threads-http=*)
                value=${argument#*=}
                [[ "$value" == <-> && "$value" -gt 0 ]] || {
                    metal_llm_die 'unsupported serve passthrough option or value'
                    return 1
                }
                ;;
            --verbose|--log-colors)
                ;;
            *)
                metal_llm_die 'unsupported serve passthrough option or value'
                return 1
                ;;
        esac
    done
}

metal_llm_serve() {
    local model_id='' requested_profile='' requested_vision='' requested_runtime=''
    local requested_mtp='' requested_context='' dry_run=0 passthrough=0 argument
    local profile_seen=0 vision_seen=0 runtime_seen=0 mtp_seen=0 context_seen=0
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
                (( profile_seen == 0 )) || { metal_llm_serve_usage; return $?; }
                [[ -n "$1" ]] || { metal_llm_serve_usage; return $?; }
                profile_seen=1
                requested_profile=$1
                shift
                ;;
            --vision)
                (( $# > 0 )) || { metal_llm_serve_usage; return $?; }
                (( vision_seen == 0 )) || { metal_llm_serve_usage; return $?; }
                [[ -n "$1" ]] || { metal_llm_serve_usage; return $?; }
                vision_seen=1
                requested_vision=$1
                shift
                ;;
            --runtime)
                (( $# > 0 )) || { metal_llm_serve_usage; return $?; }
                (( runtime_seen == 0 )) || { metal_llm_serve_usage; return $?; }
                [[ -n "$1" ]] || { metal_llm_serve_usage; return $?; }
                runtime_seen=1
                requested_runtime=$1
                shift
                ;;
            --mtp)
                (( $# > 0 )) || { metal_llm_serve_usage; return $?; }
                (( mtp_seen == 0 )) || { metal_llm_serve_usage; return $?; }
                [[ -n "$1" ]] || { metal_llm_serve_usage; return $?; }
                mtp_seen=1
                requested_mtp=$1
                shift
                ;;
            --context)
                (( $# > 0 )) || { metal_llm_serve_usage; return $?; }
                (( context_seen == 0 )) || { metal_llm_serve_usage; return $?; }
                [[ -n "$1" ]] || { metal_llm_serve_usage; return $?; }
                context_seen=1
                requested_context=$1
                shift
                ;;
            -*) metal_llm_serve_usage; return $? ;;
            *)
                [[ -z "$model_id" ]] || { metal_llm_serve_usage; return $?; }
                model_id=$argument
                ;;
        esac
    done

    [[ -n "$model_id" ]] || { metal_llm_serve_usage; return $?; }
    metal_llm_validate_serve_extra_arguments "${extra_arguments[@]}" || return 1
    metal_llm_valid_id "$model_id" || { metal_llm_die "invalid model id: $model_id"; return 1; }
    metal_llm_require_supported_host || return 1
    command -v jq >/dev/null 2>&1 || { metal_llm_die 'jq is required'; return 1; }

    local model_manifest="$METAL_LLM_ROOT/manifests/models/$model_id.json"
    [[ -f "$model_manifest" ]] || { metal_llm_die "model manifest not found: $model_id"; return 1; }
    metal_llm_validate_model_manifest "$model_manifest" "$model_id" || {
        metal_llm_die "invalid model manifest: $model_manifest"
        return 1
    }

    metal_llm_resolve_profile "$model_manifest" "$requested_profile" "$requested_vision" \
        "$requested_runtime" "$requested_mtp" "$requested_context" || return 1
    local effective_profile=$METAL_LLM_EFFECTIVE_PROFILE

    local profile_record
    profile_record=$(jq -er '
        [
          .profile_id, .runtime_alias, .runtime_id, .model_artifact_id, (.context | tostring),
          (.vision.enabled | tostring), (.vision.projector_artifact_id // "__null__"),
          (if .vision.image_min_tokens == null then "__null__" else (.vision.image_min_tokens | tostring) end),
          .mtp.policy, (.mtp.artifact_id // "__null__"), (.mtp.spec_type // "__null__"),
          (if .mtp.draft_n_max == null then "__null__" else (.mtp.draft_n_max | tostring) end),
          (if .mtp.gpu_layers == null then "__null__" else (.mtp.gpu_layers | tostring) end),
          (if .mtp.threshold == null then "__null__" else (.mtp.threshold | tostring) end),
          (.metal.gpu_layers | tostring), (.metal.fit | tostring),
          (.metal.flash_attention | tostring), (.metal.load_mode | tostring),
          (.metal.lazy_mmap | tostring)
        ] | @tsv
    ' <<< "$effective_profile") || return 1

    local profile_id runtime_alias runtime_id model_artifact_id context
    local vision_enabled projector_artifact_id image_min_tokens
    local mtp_policy mtp_artifact_id spec_type draft_n_max draft_gpu_layers mtp_threshold
    local gpu_layers fit flash_attention load_mode lazy_mmap
    IFS=$'\t' read -r profile_id runtime_alias runtime_id model_artifact_id context \
        vision_enabled projector_artifact_id image_min_tokens \
        mtp_policy mtp_artifact_id spec_type draft_n_max draft_gpu_layers mtp_threshold \
        gpu_layers fit flash_attention load_mode lazy_mmap <<< "$profile_record"

    local runtime_manifest="$METAL_LLM_ROOT/manifests/runtimes/$runtime_id.json"
    [[ -f "$runtime_manifest" ]] || { metal_llm_die "runtime manifest not found: $runtime_id"; return 1; }
    metal_llm_validate_runtime_manifest "$runtime_manifest" "$runtime_id" || {
        metal_llm_die "invalid runtime manifest: $runtime_manifest"
        return 1
    }
    metal_llm_verify_runtime_build "$runtime_id" "$runtime_manifest" llama-server || return 1
    local server_executable=$METAL_LLM_VERIFIED_EXECUTABLE

    local artifact_dir="$METAL_LLM_ROOT/.lab/artifacts/$model_id"
    metal_llm_profile_artifact_identities "$model_manifest" "$artifact_dir" \
        "$effective_profile" || return 1

    local model_path projector_path='' mtp_path=''
    model_path=$(metal_llm_artifact_path "$model_manifest" "$artifact_dir" "$model_artifact_id") || return 1
    if [[ "$vision_enabled" == true ]]; then
        projector_path=$(metal_llm_artifact_path "$model_manifest" "$artifact_dir" "$projector_artifact_id") || return 1
    fi
    if [[ "$mtp_policy" == on || "$mtp_policy" == dynamic ]]; then
        mtp_path=$(metal_llm_artifact_path "$model_manifest" "$artifact_dir" "$mtp_artifact_id") || return 1
    fi

    local host=${METAL_LLM_HOST:-127.0.0.1}
    local port=${METAL_LLM_PORT:-8080}
    local parallel=${METAL_LLM_PARALLEL:-1}
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
    if [[ "$mtp_policy" == on || "$mtp_policy" == dynamic ]]; then
        command_arguments+=(
            --spec-draft-model "$mtp_path" --spec-type "$spec_type"
            --spec-draft-n-max "$draft_n_max" --spec-draft-ngl "$draft_gpu_layers"
        )
        if [[ "$mtp_policy" == dynamic ]]; then
            command_arguments+=(--spec-draft-max-prompt-tokens "$mtp_threshold")
        fi
    fi
    local api_key=${METAL_LLM_API_KEY:-}
    [[ -z "$api_key" ]] || command_arguments+=(--api-key "$api_key")
    command_arguments+=("${extra_arguments[@]}")

    if (( dry_run == 1 )); then
        metal_llm_print_serve_command "${command_arguments[@]}"
        return
    fi
    local model_manifest_sha identity_json
    model_manifest_sha=$(metal_llm_sha256 "$model_manifest") || return 1
    identity_json=$(jq -cn \
        --arg owner_kind serve --arg model "$model_id" --arg profile "$profile_id" \
        --arg runtime_alias "$runtime_alias" --argjson context "$context" \
        --argjson vision "$vision_enabled" --arg mtp_policy "$mtp_policy" \
        --argjson mtp_threshold "${mtp_threshold/__null__/null}" --arg runtime "$runtime_id" \
        --arg runtime_revision "$METAL_LLM_VERIFIED_RUNTIME_REVISION" \
        --arg runtime_tree "$METAL_LLM_VERIFIED_RUNTIME_TREE" \
        --arg runtime_manifest_sha "$METAL_LLM_VERIFIED_RUNTIME_MANIFEST_SHA256" \
        --arg receipt_sha "$METAL_LLM_VERIFIED_BUILD_RECEIPT_SHA256" \
        --arg executable_name llama-server --arg executable_sha "$METAL_LLM_VERIFIED_EXECUTABLE_SHA256" \
        --arg model_manifest_sha "$model_manifest_sha" \
        --argjson artifacts "$METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES" \
        --arg host "$host" --argjson port "$port" '
      {
        owner_kind: $owner_kind, model_id: $model, profile_id: $profile,
        runtime_alias: $runtime_alias, context: $context, vision: $vision,
        mtp_policy: $mtp_policy, mtp_threshold: $mtp_threshold,
        runtime_id: $runtime, runtime_revision: $runtime_revision, runtime_tree_sha: $runtime_tree,
        runtime_manifest_sha256: $runtime_manifest_sha, build_receipt_sha256: $receipt_sha,
        executable_name: $executable_name, executable_sha256: $executable_sha,
        model_manifest_sha256: $model_manifest_sha, artifacts: $artifacts, host: $host, port: $port
      }
    ') || return 1
    metal_llm_acquire_managed_lease "$identity_json" || return 1
    exec "${command_arguments[@]}"
}
