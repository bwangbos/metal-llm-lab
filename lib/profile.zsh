metal_llm_resolve_profile() {
    local model_manifest=$1
    local requested_profile=${2:-}
    local requested_vision=${3:-}
    local requested_runtime=${4:-}
    local requested_mtp=${5:-}
    local requested_context=${6:-}

    unset METAL_LLM_EFFECTIVE_PROFILE
    [[ -z "${METAL_LLM_CONTEXT:-}" ]] || {
        metal_llm_die 'METAL_LLM_CONTEXT was removed; use --profile custom --runtime RUNTIME --mtp POLICY --context TOKENS'
        return 1
    }
    command -v jq >/dev/null 2>&1 || {
        metal_llm_die 'jq is required'
        return 1
    }
    [[ -f "$model_manifest" ]] || {
        metal_llm_die "model manifest not found: $model_manifest"
        return 1
    }

    local profile_id=$requested_profile
    if [[ -z "$profile_id" ]]; then
        profile_id=$(jq -er '.default_profile | select(type == "string" and length > 0)' \
          "$model_manifest" 2>/dev/null) || {
            metal_llm_die 'model manifest has no valid default profile'
            return 1
        }
    fi
    if [[ "$profile_id" == vision ]]; then
        metal_llm_die 'profile vision was removed; select a preset and use --vision on'
        return 1
    fi

    local vision=$requested_vision
    if [[ -z "$vision" ]]; then
        vision=$(jq -er '
          .capabilities.vision.default_enabled |
          if . == true then "on" elif . == false then "off" else error("invalid vision default") end
        ' "$model_manifest" 2>/dev/null) || {
            metal_llm_die 'model manifest has no valid vision default'
            return 1
        }
    fi
    [[ "$vision" == on || "$vision" == off ]] || {
        metal_llm_die 'vision must be on or off'
        return 1
    }

    local runtime_alias mtp_policy context
    if [[ "$profile_id" == custom ]]; then
        [[ -n "$requested_runtime" && -n "$requested_mtp" && -n "$requested_context" ]] || {
            metal_llm_die 'custom requires --runtime tuned|upstream --mtp on|off|dynamic --context TOKENS'
            return 1
        }
        runtime_alias=$requested_runtime
        mtp_policy=$requested_mtp
        context=$requested_context
    else
        [[ -z "$requested_runtime" && -z "$requested_mtp" && -z "$requested_context" ]] || {
            metal_llm_die 'named profiles reject --runtime, --mtp, and --context; use --profile custom'
            return 1
        }
        local profile_record
        profile_record=$(jq -er --arg profile "$profile_id" '
          [.profiles[] | select(.id == $profile)] |
          select(length == 1) | .[0] |
          [.runtime, .mtp_policy, (.context | tostring)] | @tsv
        ' "$model_manifest" 2>/dev/null) || {
            metal_llm_die "profile not found or duplicated: $profile_id"
            return 1
        }
        IFS=$'\t' read -r runtime_alias mtp_policy context <<< "$profile_record"
    fi

    [[ "$runtime_alias" == tuned || "$runtime_alias" == upstream ]] || {
        metal_llm_die 'runtime must be tuned or upstream'
        return 1
    }
    [[ "$mtp_policy" == on || "$mtp_policy" == off || "$mtp_policy" == dynamic ]] || {
        metal_llm_die 'MTP policy must be on, off, or dynamic'
        return 1
    }
    if [[ "$runtime_alias" == upstream && "$mtp_policy" != off ]]; then
        metal_llm_die 'runtime upstream supports only MTP policy off'
        return 1
    fi
    [[ "$context" == <-> ]] || {
        metal_llm_die 'context must be a positive integer no larger than the model maximum'
        return 1
    }
    local context_number
    context_number=$(jq -enr --arg context "$context" '$context | tonumber') || return 1
    jq -e --argjson context "$context_number" '
      (.max_context | type == "number" and floor == . and . > 0) and
      ($context > 0 and $context <= .max_context)
    ' "$model_manifest" >/dev/null 2>&1 || {
        metal_llm_die 'context must be a positive integer no larger than the model maximum'
        return 1
    }

    local normalized
    normalized=$(jq -cer \
      --arg profile_id "$profile_id" \
      --arg runtime_alias "$runtime_alias" \
      --arg mtp_policy "$mtp_policy" \
      --arg vision "$vision" \
      --argjson context "$context_number" '
      . as $manifest |
      [.artifacts[].id] as $artifact_ids |
      select(
        .schema_version == 2 and
        ([.artifacts[].id] | length == (unique | length)) and
        (.runtime_aliases | type == "object") and
        (.runtime_aliases[$runtime_alias] | type == "string" and
          test("^[a-z0-9]+([.-][a-z0-9]+)*$")) and
        (.text_model.entry_artifact_id as $id |
          any(.artifacts[]; .id == $id and .kind == "model")) and
        (.capabilities.vision.projector_artifact_id as $id |
          any(.artifacts[]; .id == $id and .kind == "projector")) and
        (.capabilities.mtp.artifact_id as $id |
          any(.artifacts[]; .id == $id and .kind == "mtp")) and
        (.metal == {
          gpu_layers: "all", fit: false, flash_attention: true,
          load_mode: "mmap", lazy_mmap: true
        })
      ) |
      {
        profile_id: $profile_id,
        runtime_alias: $runtime_alias,
        runtime_id: .runtime_aliases[$runtime_alias],
        context: $context,
        vision: (if $vision == "on" then {
          enabled: true,
          projector_artifact_id: .capabilities.vision.projector_artifact_id,
          image_min_tokens: .capabilities.vision.image_min_tokens
        } else {
          enabled: false,
          projector_artifact_id: null,
          image_min_tokens: null
        } end),
        mtp: (if $mtp_policy == "off" then {
          policy: "off", artifact_id: null, spec_type: null,
          draft_n_max: null, gpu_layers: null, threshold: null
        } else {
          policy: $mtp_policy,
          artifact_id: .capabilities.mtp.artifact_id,
          spec_type: .capabilities.mtp.spec_type,
          draft_n_max: .capabilities.mtp.draft_n_max,
          gpu_layers: .capabilities.mtp.gpu_layers,
          threshold: (if $mtp_policy == "dynamic" then
            .capabilities.mtp.dynamic_threshold else null end)
        } end),
        model_artifact_id: .text_model.entry_artifact_id,
        metal: .metal
      } |
      select(
        (.vision.enabled == false or
          (.vision.image_min_tokens | type == "number" and floor == . and . > 0)) and
        (.mtp.policy == "off" or (
          (.mtp.spec_type | type == "string" and length > 0) and
          (.mtp.draft_n_max | type == "number" and floor == . and . > 0) and
          .mtp.gpu_layers == "all"
        )) and
        (.mtp.policy != "dynamic" or
          (.mtp.threshold | type == "number" and floor == . and . > 0))
      )
    ' "$model_manifest" 2>/dev/null) || {
        metal_llm_die "model manifest cannot resolve profile: $profile_id"
        return 1
    }
    typeset -gx METAL_LLM_EFFECTIVE_PROFILE="$normalized"
}
