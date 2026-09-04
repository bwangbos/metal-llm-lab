metal_llm_performance_checkpoint_error() {
    print -u2 -- "performance checkpoint: $1"
    return 1
}

metal_llm_performance_checkpoint_validate_identity() {
    local identity=$1
    jq -e '
      def exact_keys($wanted): (keys | sort) == ($wanted | sort);
      def sha256: type == "string" and test("^[0-9a-f]{64}$");
      def git_sha: type == "string" and test("^[0-9a-f]{40}$");
      def timestamp:
        type == "string" and
        (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == .) catch false);
      type == "object" and exact_keys([
        "schema_version", "collection_started", "repository", "collector", "manifests",
        "correctness_evidence_sha256", "hardware", "system", "runtime",
        "model_manifest_sha256", "artifacts", "matrix", "generation", "comparison"
      ]) and
      .schema_version == 1 and (.collection_started | timestamp) and
      (.repository | type == "object" and exact_keys(["revision", "tree_sha"]) and
        (.revision | git_sha) and (.tree_sha | git_sha)) and
      (.collector | type == "object" and exact_keys([
        "path", "sha256", "checkpoint_library_path", "checkpoint_library_sha256"
      ]) and .path == "tests/integration/test_dynamic_mtp_performance.sh" and (.sha256 | sha256) and
        .checkpoint_library_path == "lib/performance-checkpoint.zsh" and
        (.checkpoint_library_sha256 | sha256)) and
      (.manifests | type == "object" and
        exact_keys(["hardware_sha256", "model_sha256", "runtime_sha256"]) and
        all(.[]; sha256)) and
      (.correctness_evidence_sha256 | sha256) and
      (.hardware | type == "object" and exact_keys(["id", "chip", "unified_memory_bytes"]) and
        .id == "apple-m5-max-128gb" and .chip == "Apple M5 Max" and
        .unified_memory_bytes == 137438953472) and
      (.system | type == "object" and
        exact_keys(["operating_system", "operating_system_version", "compiler", "sdk", "power_source", "low_power_mode"]) and
        .operating_system == "macOS" and
        ([.operating_system_version, .compiler, .sdk, .power_source] |
          all(. == null or (type == "string" and length > 0))) and
        (.low_power_mode == null or (.low_power_mode | type == "boolean"))) and
      (.runtime | type == "object" and exact_keys([
        "id", "tested_revision", "tested_tree_sha", "manifest_sha256",
        "build_receipt_sha256", "executable"
      ]) and .id == "llama-cpp-qwen38-hybrid" and
        (.tested_revision | git_sha) and (.tested_tree_sha | git_sha) and
        (.manifest_sha256 | sha256) and (.build_receipt_sha256 | sha256) and
        (.executable | type == "object" and exact_keys(["name", "sha256"]) and
          .name == "llama-server" and (.sha256 | sha256))) and
      .runtime.manifest_sha256 == .manifests.runtime_sha256 and
      (.model_manifest_sha256 | sha256) and
      .model_manifest_sha256 == .manifests.model_sha256 and
      (.artifacts | type == "array" and length == 35 and
        all(.[]; type == "object" and exact_keys(["id", "bytes", "sha256"]) and
          (.id | type == "string" and test("^[a-z0-9]+(?:[.-][a-z0-9]+)*$")) and
          (.bytes | type == "number" and floor == . and . > 0) and (.sha256 | sha256)) and
        ([.[].id] | unique | length) == length) and
      (.matrix | type == "object" and exact_keys([
        "policies", "effective_prompt_lengths", "warmups_per_cell", "samples_per_cell"
      ]) and .policies == ["on", "off", "dynamic"] and
        .effective_prompt_lengths == [29000, 30000, 32767, 32768, 32769, 33868, 98304] and
        .warmups_per_cell == 1 and .samples_per_cell == 5) and
      (.generation | type == "object" and exact_keys([
        "context", "vision", "generated_tokens", "temperature", "seed", "reasoning",
        "ignore_eos", "cache_prompt", "parallel", "draft_n_max"
      ]) and .context == 262144 and .vision == true and .generated_tokens == 128 and
        .temperature == 0 and .seed == 1234 and .reasoning == false and
        .ignore_eos == true and .cache_prompt == false and .parallel == 1 and
        .draft_n_max == 2) and
      (.comparison | type == "object" and
        exact_keys(["metric", "tolerance_percent", "dynamic_threshold"]) and
        .metric == "generation_tokens_per_second" and .tolerance_percent == 5 and
        .dynamic_threshold == 32768)
    ' <<< "$identity" >/dev/null 2>&1
}

metal_llm_performance_checkpoint_validate_envelope() {
    local envelope_file=$1 identity_file=$2 expected_filename=$3 checkpoint=$4
    [[ -f "$envelope_file" && ! -L "$envelope_file" ]] || return 1
    jq -e --slurpfile identity "$identity_file" --arg filename "$expected_filename" '
      def exact_keys($wanted): (keys | sort) == ($wanted | sort);
      def sha256: type == "string" and test("^[0-9a-f]{64}$");
      def git_sha: type == "string" and test("^[0-9a-f]{40}$");
      def timestamp:
        type == "string" and
        (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == .) catch false);
      . as $e | $identity[0] as $i | $e.run as $r |
      ($r.draft_acceptance | split("/") | map(tonumber)) as $draft |
      ($e | type == "object" and exact_keys(["schema_version", "server_session_id", "run"])) and
      $e.schema_version == 1 and
      ($e.server_session_id | type == "string" and test("^(on|off|dynamic)-session-[0-9]+$")) and
      ($r | type == "object" and exact_keys([
        "id", "experiment", "measurement_kind", "timestamp", "repository_revision",
        "hardware_id", "runtime_id", "runtime_revision", "profile", "profile_id",
        "runtime_alias", "context", "vision", "mtp_policy", "mtp_selected", "mtp_threshold",
        "prompt_tokens", "effective_prompt_tokens", "generated_tokens",
        "prompt_tokens_per_second", "generation_tokens_per_second", "output_sha256",
        "draft_acceptance", "command", "generation_settings", "notes"
      ])) and
      ($r.id + ".json") == $filename and
      ($r.id | test("^(on|off|dynamic)-(29000|30000|32767|32768|32769|33868|98304)-s[1-5]$")) and
      (($r.id | capture("^(?<policy>on|off|dynamic)-(?<effective>[0-9]+)-s(?<sample>[1-5])$")) as $id |
        $r.mtp_policy == $id.policy and
        $r.effective_prompt_tokens == ($id.effective | tonumber) and
        ($e.server_session_id | startswith($id.policy + "-session-")) and
        ($i.matrix.policies | index($id.policy)) != null and
        ($i.matrix.effective_prompt_lengths | index($id.effective | tonumber)) != null and
        ($id.sample | tonumber) <= $i.matrix.samples_per_cell and
        ($r.notes | test("^Measured sample " + $id.sample + " of 5 after 1 warm-up; response SHA-256 [0-9a-f]{64}\\.$"))) and
      $r.experiment == "dynamic-mtp-performance" and $r.measurement_kind == "single_run" and
      ($r.timestamp | timestamp) and $r.repository_revision == $i.repository.revision and
      $r.hardware_id == $i.hardware.id and $r.runtime_id == $i.runtime.id and
      $r.runtime_revision == $i.runtime.tested_revision and
      $r.profile == null and $r.profile_id == "custom" and $r.runtime_alias == "tuned" and
      $r.context == $i.generation.context and $r.vision == $i.generation.vision and
      ($r.mtp_selected == (if $r.mtp_policy == "on" then true elif $r.mtp_policy == "off" then false
        else $r.effective_prompt_tokens <= $i.comparison.dynamic_threshold end)) and
      ($r.mtp_threshold == (if $r.mtp_policy == "dynamic" then $i.comparison.dynamic_threshold else null end)) and
      (($r.prompt_tokens | type) == "number" and ($r.prompt_tokens | floor) == $r.prompt_tokens and
        $r.prompt_tokens > 0 and $r.prompt_tokens <= $r.effective_prompt_tokens and
        ($r.effective_prompt_tokens - $r.prompt_tokens) < 64) and
      $r.generated_tokens == $i.generation.generated_tokens and
      (($r.prompt_tokens_per_second | type) == "number" and $r.prompt_tokens_per_second > 0) and
      (($r.generation_tokens_per_second | type) == "number" and $r.generation_tokens_per_second > 0) and
      ($r.output_sha256 | sha256) and
      (($r.draft_acceptance | type) == "string" and
        ($r.draft_acceptance | test("^[0-9]+/[0-9]+$")) and
        $draft[0] <= $draft[1] and
        (if $r.mtp_selected then $draft[1] > 0 else $draft == [0, 0] end)) and
      (($r.command | type) == "array" and ($r.command | length) == 4 and
        $r.command[0:3] == ["curl", "POST", "/completion"] and
        ($r.command[3] | test("^payload-sha256:[0-9a-f]{64}$"))) and
      ($r.generation_settings | type == "object" and
        exact_keys(["temperature", "seed", "max_tokens", "reasoning", "draft_n_max"])) and
      $r.generation_settings.temperature == $i.generation.temperature and
      $r.generation_settings.seed == $i.generation.seed and
      $r.generation_settings.max_tokens == $i.generation.generated_tokens and
      $r.generation_settings.reasoning == $i.generation.reasoning and
      $r.generation_settings.draft_n_max == $i.generation.draft_n_max
    ' "$envelope_file" >/dev/null 2>&1 || return 1

    local session_id run_id response_sha expected_response_sha response_file
    session_id=$(jq -er '.server_session_id' "$envelope_file") || return 1
    [[ -f "$checkpoint/logs/$session_id.log" && ! -L "$checkpoint/logs/$session_id.log" ]] || return 1
    run_id=$(jq -er '.run.id' "$envelope_file") || return 1
    expected_response_sha=$(jq -er '
      .run.notes | capture("response SHA-256 (?<sha>[0-9a-f]{64})\\.$").sha
    ' "$envelope_file") || return 1
    response_file="$checkpoint/responses/$session_id-$run_id.response"
    [[ -f "$response_file" && ! -L "$response_file" ]] || return 1
    response_sha=$(shasum -a 256 "$response_file" | awk '{print $1}') || return 1
    [[ "$response_sha" == "$expected_response_sha" ]]
}

metal_llm_performance_checkpoint_validate_files() {
    setopt localoptions nullglob extendedglob
    local checkpoint=$1 identity_file="$checkpoint/identity.json" entry envelope_file filename
    local -a seen_ids
    seen_ids=()

    for entry in "$checkpoint"/*(DN); do
        case "${entry:t}" in
            identity.json|runs|logs|responses) ;;
            *) return 1 ;;
        esac
    done
    [[ -d "$checkpoint/runs" && ! -L "$checkpoint/runs" ]] || return 1
    [[ ! -e "$checkpoint/logs" || ( -d "$checkpoint/logs" && ! -L "$checkpoint/logs" ) ]] || return 1
    [[ ! -e "$checkpoint/responses" || ( -d "$checkpoint/responses" && ! -L "$checkpoint/responses" ) ]] || return 1

    if [[ -d "$checkpoint/logs" ]]; then
        for entry in "$checkpoint/logs"/*(DN); do
            [[ -f "$entry" && ! -L "$entry" &&
               "${entry:t}" == (on|off|dynamic)-session-<1->.log ]] || return 1
        done
    fi
    if [[ -d "$checkpoint/responses" ]]; then
        for entry in "$checkpoint/responses"/*(DN); do
            [[ -f "$entry" && ! -L "$entry" &&
               "${entry:t}" == (on|off|dynamic)-session-<1->-(calibration-(on|off|dynamic)|warmup-(on|off|dynamic)-(29000|30000|32767|32768|32769|33868|98304)|(on|off|dynamic)-(29000|30000|32767|32768|32769|33868|98304)-s[1-5]).response ]] || return 1
        done
    fi

    for envelope_file in "$checkpoint/runs"/*(DN); do
        filename=${envelope_file:t}
        [[ "$filename" == (on|off|dynamic)-(29000|30000|32767|32768|32769|33868|98304)-s[1-5].json ]] || return 1
        metal_llm_performance_checkpoint_validate_envelope \
          "$envelope_file" "$identity_file" "$filename" "$checkpoint" || return 1
        seen_ids+=("${filename%.json}")
    done
    (( ${#seen_ids[@]} <= 105 )) || return 1
}

metal_llm_performance_checkpoint_open() {
    setopt localoptions nullglob
    local checkpoint=$1 expected_identity=$2 identity_file="$checkpoint/identity.json"
    local identity_part canonical_expected canonical_existing
    local -a run_files
    [[ "$checkpoint" == /* && ! -L "$checkpoint" ]] || {
        metal_llm_performance_checkpoint_error 'path must be an absolute non-symlink'
        return 1
    }
    metal_llm_performance_checkpoint_validate_identity "$expected_identity" || {
        metal_llm_performance_checkpoint_error 'expected immutable identity is invalid'
        return 1
    }
    canonical_expected=$(jq -Sc . <<< "$expected_identity") || return 1

    if [[ ! -e "$checkpoint" ]]; then
        mkdir -- "$checkpoint" || return 1
        mkdir -- "$checkpoint/runs" || return 1
        identity_part=$(mktemp "$checkpoint/.identity.json.part.XXXXXX") || return 1
        print -r -- "$canonical_expected" > "$identity_part" || return 1
        command sync
        mv -- "$identity_part" "$identity_file" || return 1
        command sync
        typeset -g METAL_LLM_PERFORMANCE_CHECKPOINT_RESUMED=false
    else
        [[ -d "$checkpoint" && ! -L "$checkpoint" && -f "$identity_file" && ! -L "$identity_file" ]] || {
            metal_llm_performance_checkpoint_error 'existing state is not a safe checkpoint'
            return 1
        }
        canonical_existing=$(jq -Sc . "$identity_file" 2>/dev/null) || {
            metal_llm_performance_checkpoint_error 'checkpoint identity is malformed'
            return 1
        }
        [[ "$canonical_existing" == "$canonical_expected" ]] || {
            metal_llm_performance_checkpoint_error 'checkpoint identity does not match this run'
            return 1
        }
        typeset -g METAL_LLM_PERFORMANCE_CHECKPOINT_RESUMED=true
    fi

    metal_llm_performance_checkpoint_validate_files "$checkpoint" || {
        metal_llm_performance_checkpoint_error 'checkpoint contains malformed or unsafe state'
        return 1
    }
    run_files=("$checkpoint/runs"/*.json(N))
    typeset -g METAL_LLM_PERFORMANCE_CHECKPOINT_RUN_COUNT=${#run_files[@]}
}

metal_llm_performance_checkpoint_publish_run() {
    setopt localoptions nullglob
    local checkpoint=$1 envelope=$2 identity_file="$checkpoint/identity.json"
    local run_id destination part
    local -a run_files
    [[ -d "$checkpoint" && ! -L "$checkpoint" && -f "$identity_file" && ! -L "$identity_file" ]] || \
        return 1
    run_id=$(jq -er '.run.id | select(type == "string")' <<< "$envelope") || return 1
    destination="$checkpoint/runs/$run_id.json"
    [[ ! -e "$destination" && ! -L "$destination" ]] || {
        metal_llm_performance_checkpoint_error "retained sample already exists: $run_id"
        return 1
    }
    part=$(mktemp "$checkpoint/runs/.part.XXXXXX") || return 1
    print -r -- "$envelope" > "$part" || return 1
    if ! metal_llm_performance_checkpoint_validate_envelope \
      "$part" "$identity_file" "$run_id.json" "$checkpoint"; then
        metal_llm_performance_checkpoint_error "refusing invalid retained sample: $run_id"
        return 1
    fi
    command sync
    mv -- "$part" "$destination" || return 1
    command sync
    run_files=("$checkpoint/runs"/*.json(N))
    typeset -g METAL_LLM_PERFORMANCE_CHECKPOINT_RUN_COUNT=${#run_files[@]}
}

metal_llm_performance_checkpoint_runs() {
    local checkpoint=$1 policy effective sample row_file
    metal_llm_performance_checkpoint_validate_files "$checkpoint" || return 1
    for policy in on off dynamic; do
        for effective in 29000 30000 32767 32768 32769 33868 98304; do
            for sample in 1 2 3 4 5; do
                row_file="$checkpoint/runs/$policy-$effective-s$sample.json"
                [[ ! -e "$row_file" ]] || jq -c '.run' "$row_file" || return 1
            done
        done
    done
}
