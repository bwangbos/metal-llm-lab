metal_llm_managed_state_root() {
    print -- "${TMPDIR:-/tmp}/metal-llm-lab"
}

metal_llm_managed_lease_dir() {
    print -- "$(metal_llm_managed_state_root)/full-model.lease"
}

metal_llm_trim_space() {
    local value=$1
    value=${value##[[:space:]]#}
    value=${value%%[[:space:]]#}
    print -r -- "$value"
}

metal_llm_validate_managed_identity() {
    local record=$1
    jq -e '
      (keys | sort) == ([
        "artifacts", "build_receipt_sha256", "executable_name", "executable_sha256", "host",
        "context", "model_id", "model_manifest_sha256", "mtp_policy", "mtp_threshold",
        "owner_kind", "owner_token", "pid", "port", "process_started_at", "profile_id",
        "runtime_alias", "runtime_id", "runtime_manifest_sha256", "runtime_revision",
        "runtime_tree_sha", "schema_version", "vision"
      ] | sort) and
      .schema_version == 2 and (.owner_kind == "serve" or .owner_kind == "local-bench") and
      (.owner_token | type == "string" and test("^[0-9a-f]{64}$")) and
      (.pid | type == "number" and . > 1 and floor == .) and
      (.process_started_at | type == "string" and length > 0) and
      ([.model_id, .profile_id, .runtime_id] | all(type == "string" and test("^[a-z0-9]+([.-][a-z0-9]+)*$"))) and
      (.runtime_alias == "tuned" or .runtime_alias == "upstream") and
      (.context | type == "number" and . > 0 and floor == .) and
      (.vision | type == "boolean") and
      (.mtp_policy == "on" or .mtp_policy == "off" or .mtp_policy == "dynamic") and
      (if .mtp_policy == "dynamic" then
        (.mtp_threshold | type == "number" and . > 0 and floor == .)
      else .mtp_threshold == null end) and
      (if .runtime_alias == "upstream" then .mtp_policy == "off" else true end) and
      ([.runtime_revision, .runtime_tree_sha] | all(type == "string" and test("^[0-9a-f]{40}$"))) and
      ([.runtime_manifest_sha256, .build_receipt_sha256, .executable_sha256, .model_manifest_sha256] |
        all(type == "string" and test("^[0-9a-f]{64}$"))) and
      (.executable_name == "llama-server" or .executable_name == "llama-bench") and
      (.artifacts | type == "array" and length > 0 and all(.[ ];
        type == "object" and (keys | sort) == (["bytes", "id", "sha256"] | sort) and
        (.id | type == "string" and test("^[a-z0-9]+([.-][a-z0-9]+)*$")) and
        (.bytes | type == "number" and . > 0 and floor == .) and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))) and
      (.host | type == "string" and length > 0) and
      (.port | type == "number" and . >= 1 and . <= 65535 and floor == .)
    ' "$record" >/dev/null 2>&1
}

metal_llm_validate_legacy_benchmark_identity() {
    local record=$1
    jq -e '
      (keys | sort) == ([
        "artifacts", "build_receipt_sha256", "executable_name", "executable_sha256", "host",
        "model_id", "model_manifest_sha256", "owner_kind", "owner_token", "pid", "port",
        "process_started_at", "profile_id", "runtime_id", "runtime_manifest_sha256",
        "runtime_revision", "runtime_tree_sha", "schema_version", "vision"
      ] | sort) and
      .schema_version == 1 and (.owner_kind == "serve" or .owner_kind == "local-bench") and
      (.owner_token | type == "string" and test("^[0-9a-f]{64}$")) and
      (.pid | type == "number" and . > 1 and floor == .) and
      (.process_started_at | type == "string" and length > 0) and
      ([.model_id, .profile_id, .runtime_id] |
        all(type == "string" and test("^[a-z0-9]+([.-][a-z0-9]+)*$"))) and
      (.vision | type == "boolean") and
      ([.runtime_revision, .runtime_tree_sha] |
        all(type == "string" and test("^[0-9a-f]{40}$"))) and
      ([.runtime_manifest_sha256, .build_receipt_sha256, .executable_sha256,
        .model_manifest_sha256] |
        all(type == "string" and test("^[0-9a-f]{64}$"))) and
      (.executable_name == "llama-server" or .executable_name == "llama-bench") and
      (.artifacts | type == "array" and length > 0 and all(.[ ];
        type == "object" and (keys | sort) == (["bytes", "id", "sha256"] | sort) and
        (.id | type == "string" and test("^[a-z0-9]+([.-][a-z0-9]+)*$")) and
        (.bytes | type == "number" and . > 0 and floor == .) and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))) and
      (.host | type == "string" and length > 0) and
      (.port | type == "number" and . >= 1 and . <= 65535 and floor == .)
    ' "$record" >/dev/null 2>&1
}

metal_llm_managed_identity_is_live() {
    local record=$1
    local allow_legacy_benchmark=${2:-0}
    local pid recorded_start current_start
    if ! metal_llm_validate_managed_identity "$record"; then
        [[ "$allow_legacy_benchmark" == 1 ]] && \
            metal_llm_validate_legacy_benchmark_identity "$record" || return 2
    fi
    pid=$(jq -er '.pid' "$record") || return 2
    recorded_start=$(jq -er '.process_started_at' "$record") || return 2
    kill -0 "$pid" 2>/dev/null || return 1
    current_start=$(ps -p "$pid" -o lstart= 2>/dev/null) || return 1
    current_start=$(metal_llm_trim_space "$current_start") || return 1
    [[ -n "$current_start" && "$current_start" == "$recorded_start" ]]
}

metal_llm_recover_stale_managed_lease() {
    local lease_dir=$1
    local record="$lease_dir/identity.json"
    [[ ! -L "$lease_dir" && -d "$lease_dir" ]] || {
        metal_llm_die "managed lease path is unsafe: $lease_dir"
        return 1
    }
    if [[ -e "$record" ]]; then
        [[ -f "$record" && ! -L "$record" ]] || {
            metal_llm_die "managed identity path is unsafe: $record"
            return 1
        }
        rm -- "$record" || return 1
    fi
    rmdir -- "$lease_dir" 2>/dev/null || {
        metal_llm_die "managed lease contains unexpected state: $lease_dir"
        return 1
    }
}

metal_llm_read_live_managed_identity() {
    local lease_dir record lease_status
    lease_dir=$(metal_llm_managed_lease_dir) || return 1
    record="$lease_dir/identity.json"
    [[ -f "$record" && ! -L "$record" ]] || {
        metal_llm_die 'no managed full-model identity is available'
        return 1
    }
    if metal_llm_managed_identity_is_live "$record" 1; then
        typeset -g METAL_LLM_MANAGED_IDENTITY_RECORD="$record"
        return 0
    else
        lease_status=$?
    fi
    if (( lease_status == 2 )); then
        metal_llm_die "managed full-model identity is invalid: $record"
    else
        metal_llm_die 'managed full-model identity is stale'
    fi
    return 1
}

metal_llm_acquire_managed_lease() {
    local identity_json=$1
    local state_root lease_dir record record_part process_started owner_token lease_status attempt=0
    local allow_legacy_benchmark=0 identity_schema=2
    if jq -e '.owner_kind == "local-bench"' <<< "$identity_json" >/dev/null 2>&1; then
        allow_legacy_benchmark=1
        identity_schema=1
    fi
    state_root=$(metal_llm_managed_state_root) || return 1
    lease_dir="$state_root/full-model.lease"
    record="$lease_dir/identity.json"
    [[ ! -L "$state_root" ]] || { metal_llm_die "managed state path is unsafe: $state_root"; return 1; }
    mkdir -p -- "$state_root" || return 1
    chmod 700 "$state_root" || return 1

    while (( attempt < 3 )); do
        (( ++attempt ))
        if mkdir -- "$lease_dir" 2>/dev/null; then
            break
        fi
        [[ ! -L "$lease_dir" && -d "$lease_dir" ]] || {
            metal_llm_die "managed lease path is unsafe: $lease_dir"
            return 1
        }
        if [[ ! -e "$record" ]]; then
            metal_llm_die 'managed full-model lease acquisition is already in progress'
            return 1
        fi
        if metal_llm_managed_identity_is_live "$record" "$allow_legacy_benchmark"; then
            metal_llm_die "managed full-model process is already active: $(jq -r '.owner_kind + " " + .model_id + " profile=" + .profile_id + " pid=" + (.pid | tostring)' "$record")"
            return 1
        else
            lease_status=$?
        fi
        if (( lease_status == 2 )); then
            local recorded_pid
            recorded_pid=$(jq -er '.pid | select(type == "number" and . > 1 and floor == .)' "$record" 2>/dev/null || true)
            if [[ -n "$recorded_pid" ]] && kill -0 "$recorded_pid" 2>/dev/null; then
                metal_llm_die "refusing to replace an invalid lease that names a live PID: $recorded_pid"
                return 1
            fi
        fi
        metal_llm_recover_stale_managed_lease "$lease_dir" || return 1
    done
    [[ -d "$lease_dir" ]] || { metal_llm_die 'could not acquire managed full-model lease'; return 1; }

    process_started=$(ps -p $$ -o lstart= 2>/dev/null) || {
        rmdir -- "$lease_dir" 2>/dev/null || true
        metal_llm_die 'could not identify managed process start time'
        return 1
    }
    process_started=$(metal_llm_trim_space "$process_started") || return 1
    [[ -n "$process_started" ]] || { metal_llm_die 'could not identify managed process start time'; return 1; }
    owner_token=$(print -rn -- "$$:$process_started:$identity_json" | shasum -a 256 | awk '{print $1}') || return 1
    record_part="$lease_dir/identity.json.part"
    umask 077
    if ! jq -cn --argjson identity "$identity_json" --arg token "$owner_token" \
        --argjson pid "$$" --arg started "$process_started" --argjson schema "$identity_schema" '
        $identity + {
          schema_version: $schema,
          owner_token: $token,
          pid: $pid,
          process_started_at: $started
        }
    ' > "$record_part"; then
        rm -f -- "$record_part"
        rmdir -- "$lease_dir" 2>/dev/null || true
        return 1
    fi
    if ! metal_llm_validate_managed_identity "$record_part" && \
        ! { [[ "$allow_legacy_benchmark" == 1 ]] && \
            metal_llm_validate_legacy_benchmark_identity "$record_part"; }; then
        rm -f -- "$record_part"
        rmdir -- "$lease_dir" 2>/dev/null || true
        metal_llm_die 'refusing to publish an invalid managed identity'
        return 1
    fi
    mv -- "$record_part" "$record" || return 1
    typeset -g METAL_LLM_MANAGED_OWNER_TOKEN="$owner_token"
    typeset -g METAL_LLM_MANAGED_IDENTITY_RECORD="$record"
}

metal_llm_release_managed_lease() {
    local owner_token=$1
    local lease_dir record recorded_token
    lease_dir=$(metal_llm_managed_lease_dir) || return 1
    record="$lease_dir/identity.json"
    [[ -f "$record" && ! -L "$record" ]] || return 0
    recorded_token=$(jq -r '.owner_token // empty' "$record" 2>/dev/null) || return 1
    [[ -n "$recorded_token" && "$recorded_token" == "$owner_token" ]] || return 0
    rm -- "$record" || return 1
    rmdir -- "$lease_dir" 2>/dev/null || return 1
}
