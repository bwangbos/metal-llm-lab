metal_llm_artifact_verification_begin() {
    local requested_mode=$1 dry_run=$2
    [[ "$requested_mode" == cached || "$requested_mode" == full ]] || {
        metal_llm_die "artifact check must be cached or full"
        return 1
    }
    [[ "$dry_run" == 0 || "$dry_run" == 1 ]] || {
        metal_llm_die 'artifact verification dry-run state must be 0 or 1'
        return 1
    }
    typeset -g METAL_LLM_ARTIFACT_CHECK_REQUESTED="$requested_mode"
    typeset -gi METAL_LLM_ARTIFACT_CHECK_DRY_RUN=$dry_run
    typeset -gi METAL_LLM_ARTIFACT_CACHE_HITS=0
    typeset -gi METAL_LLM_ARTIFACT_CACHE_MISSES=0
    typeset -gi METAL_LLM_ARTIFACT_FULL_HASHES=0
    typeset -gA METAL_LLM_ARTIFACT_PATHS=()
    typeset -gA METAL_LLM_ARTIFACT_FINGERPRINTS=()
    typeset -gA METAL_LLM_ARTIFACT_BINDINGS=()
    typeset -gA METAL_LLM_ARTIFACT_MEMO_KEYS=()
    typeset -gA METAL_LLM_ARTIFACT_IDENTITIES=()
    typeset -ga METAL_LLM_ARTIFACT_ORDER=()
    typeset -g METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES='[]'
    unset METAL_LLM_ARTIFACT_VERIFICATION_JSON
    unset METAL_LLM_ARTIFACT_EFFECTIVE_MODE
    unset METAL_LLM_ARTIFACT_RECEIPT_SET_SHA256
}

metal_llm_artifact_require_session() {
    [[ -n "${METAL_LLM_ARTIFACT_CHECK_REQUESTED:-}" ]] || {
        metal_llm_die 'artifact verification session has not begun'
        return 1
    }
}

# Keep Darwin lstat behind one replaceable helper. Tests can inject metadata
# states that an unprivileged local test process cannot create.
metal_llm_artifact_lstat() {
    local target_path=$1 format=$2
    /usr/bin/stat -f "$format" -- "$target_path"
}

metal_llm_artifact_parse_metadata() {
    local metadata=$1
    local owner mode type links extra
    IFS=$'\t' read -r owner mode type links extra <<< "$metadata"
    [[ -z "$extra" && "$metadata" == "$owner"$'\t'"$mode"$'\t'"$type"$'\t'"$links" ]] || return 1
    [[ "$owner" == <-> && "$mode" == <-> && "$links" == <-> ]] || return 1
    print -r -- "$owner"$'\t'"$mode"$'\t'"$type"$'\t'"$links"
}

metal_llm_artifact_fingerprint() {
    local target_path=$1 stat_output
    local device_id inode size_bytes birth_time change_time modify_time extra
    stat_output=$(metal_llm_artifact_lstat "$target_path" $'%d\t%i\t%z\t%FB\t%Fc\t%Fm') || {
        metal_llm_die "could not read artifact filesystem fingerprint: $target_path"
        return 1
    }
    IFS=$'\t' read -r device_id inode size_bytes birth_time change_time modify_time extra <<< "$stat_output"
    [[ -z "$extra" && "$stat_output" == "$device_id"$'\t'"$inode"$'\t'"$size_bytes"$'\t'"$birth_time"$'\t'"$change_time"$'\t'"$modify_time" ]] || {
        metal_llm_die "unsupported artifact filesystem fingerprint: $target_path"
        return 1
    }
    [[ "$device_id" == <-> && "$inode" == <-> && "$size_bytes" == <-> ]] || {
        metal_llm_die "unsupported artifact filesystem fingerprint: $target_path"
        return 1
    }
    [[ "$birth_time" =~ '^[0-9]+\.[0-9]{9}$' &&
       "$change_time" =~ '^[0-9]+\.[0-9]{9}$' &&
       "$modify_time" =~ '^[0-9]+\.[0-9]{9}$' ]] || {
        metal_llm_die "unsupported artifact filesystem timestamp precision: $target_path"
        return 1
    }
    jq -cnS \
      --arg device_id "$device_id" \
      --arg inode "$inode" \
      --arg size_bytes "$size_bytes" \
      --arg birth_time "$birth_time" \
      --arg change_time "$change_time" \
      --arg modify_time "$modify_time" \
      '{device_id: $device_id, inode: $inode, size_bytes: $size_bytes,
        birth_time: $birth_time, change_time: $change_time, modify_time: $modify_time}'
}

metal_llm_artifact_sha256_text() {
    local value=$1 checksum_output
    typeset -a checksum_fields
    checksum_output=$(print -rn -- "$value" | /usr/bin/shasum -a 256) || return 1
    checksum_fields=(${=checksum_output})
    (( ${#checksum_fields} >= 1 )) && [[ "$checksum_fields[1]" =~ '^[0-9a-f]{64}$' ]] || return 1
    print -- "$checksum_fields[1]"
}

metal_llm_artifact_compute_sha256() {
    metal_llm_sha256 "$1"
}

metal_llm_artifact_manifest_record() {
    local manifest=$1 model_id=$2 artifact_id=$3
    metal_llm_valid_id "$model_id" && metal_llm_valid_id "$artifact_id" || {
        metal_llm_die 'model and artifact IDs must use the strict ID grammar'
        return 1
    }
    jq -er --arg model_id "$model_id" --arg artifact_id "$artifact_id" '
      select((.schema_version == 1 or .schema_version == 2) and .id == $model_id) |
      [.artifacts[] | select(.id == $artifact_id)] |
      select(length == 1) | .[0] |
      select(
        (.filename | type == "string" and length > 0 and . != "." and . != ".." and
          (contains("/") | not) and (contains("\t") | not) and (contains("\n") | not)) and
        (.bytes | type == "number" and . > 0 and floor == .) and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
      ) |
      [.filename, (.bytes | tostring), .sha256] | @tsv
    ' "$manifest" 2>/dev/null || {
        metal_llm_die "artifact not found or invalid in manifest: $artifact_id"
        return 1
    }
}

metal_llm_artifact_validate_directory_components() {
    local artifact_dir=$1
    local repository_root=${METAL_LLM_ROOT:a}
    local absolute_dir=${artifact_dir:a}
    local relative_dir component current_path component_type
    typeset -a components

    while [[ "$repository_root" == *'//'* ]]; do
        repository_root=${repository_root//\/\//\/}
    done
    while [[ "$absolute_dir" == *'//'* ]]; do
        absolute_dir=${absolute_dir//\/\//\/}
    done
    [[ "$absolute_dir" == "$repository_root"/* ]] || {
        metal_llm_die "artifact directory escapes the repository: $artifact_dir"
        return 1
    }
    relative_dir=${absolute_dir#$repository_root/}
    components=("${(@s:/:)relative_dir}")
    current_path=$repository_root
    for component in "${components[@]}"; do
        current_path="$current_path/$component"
        [[ ! -L "$current_path" ]] || {
            metal_llm_die "unsafe artifact directory path component is a symlink: $current_path"
            return 1
        }
        [[ -e "$current_path" ]] || return 0
        component_type=$(metal_llm_artifact_lstat "$current_path" '%HT') || {
            metal_llm_die "could not inspect artifact directory path component: $current_path"
            return 1
        }
        [[ "$component_type" == 'Directory' ]] || {
            metal_llm_die "unsafe artifact directory path component is not a directory: $current_path"
            return 1
        }
    done
}

metal_llm_artifact_validate_download_paths() {
    local artifact_dir=$1 filename=$2 artifact_id=$3 supplied_part_path=$4
    local absolute_dir=${artifact_dir:a}
    local final_path="$absolute_dir/$filename"
    local expected_part_path="$final_path.part"
    local absolute_part_path=${supplied_part_path:a}
    local metadata parsed owner mode type links

    while [[ "$absolute_dir" == *'//'* ]]; do
        absolute_dir=${absolute_dir//\/\//\/}
    done
    while [[ "$absolute_part_path" == *'//'* ]]; do
        absolute_part_path=${absolute_part_path//\/\//\/}
    done
    final_path="$absolute_dir/$filename"
    expected_part_path="$final_path.part"
    metal_llm_artifact_validate_directory_components "$artifact_dir" || return 1
    [[ "$absolute_part_path" == "$expected_part_path" ]] || {
        metal_llm_die "partial artifact path escapes its artifact directory: $artifact_id ($supplied_part_path)"
        return 1
    }
    [[ ! -L "$final_path" ]] || {
        metal_llm_die "artifact destination is a symlink: $artifact_id ($final_path)"
        return 1
    }
    [[ ! -L "$expected_part_path" ]] || {
        metal_llm_die "partial artifact is a symlink: $artifact_id ($expected_part_path)"
        return 1
    }
    [[ -e "$expected_part_path" ]] || return 0
    metadata=$(metal_llm_artifact_lstat "$expected_part_path" $'%u\t%Lp\t%HT\t%l') || {
        metal_llm_die "could not inspect partial artifact: $expected_part_path"
        return 1
    }
    parsed=$(metal_llm_artifact_parse_metadata "$metadata") || {
        metal_llm_die "unsupported partial artifact metadata: $expected_part_path"
        return 1
    }
    IFS=$'\t' read -r owner mode type links <<< "$parsed"
    [[ "$owner" == "$EUID" && "$type" == 'Regular File' && "$links" == 1 ]] || {
        metal_llm_die "partial artifact must be an owned regular single-link file: $expected_part_path"
        return 1
    }
}

metal_llm_artifact_resolve_path() {
    local artifact_dir=$1 filename=$2 artifact_id=$3
    local canonical_dir canonical_path candidate="$artifact_dir/$filename"
    metal_llm_artifact_validate_directory_components "$artifact_dir" || return 1
    [[ -d "$artifact_dir" && ! -L "$artifact_dir" ]] || {
        metal_llm_die "artifact directory is not a regular directory: $artifact_dir"
        return 1
    }
    [[ -e "$candidate" ]] || {
        metal_llm_die "artifact is missing: $artifact_id ($candidate)"
        return 1
    }
    [[ -f "$candidate" && ! -L "$candidate" ]] || {
        metal_llm_die "artifact is not a regular non-symlink file: $artifact_id ($candidate)"
        return 1
    }
    canonical_dir=${artifact_dir:A}
    canonical_path=${candidate:A}
    [[ "$canonical_path" == "$canonical_dir"/* ]] || {
        metal_llm_die "artifact path escapes its artifact directory: $artifact_id ($candidate)"
        return 1
    }
    print -r -- "$canonical_path"
}

metal_llm_artifact_binding_json() {
    local model_id=$1 manifest_sha=$2 artifact_id=$3 artifact_bytes=$4
    local artifact_sha=$5 canonical_path=$6 fingerprint=$7
    jq -cnS \
      --arg model_id "$model_id" \
      --arg manifest_sha "$manifest_sha" \
      --arg artifact_id "$artifact_id" \
      --argjson artifact_bytes "$artifact_bytes" \
      --arg artifact_sha "$artifact_sha" \
      --arg canonical_path "$canonical_path" \
      --argjson fingerprint "$fingerprint" '
      {
        schema_version: 1,
        model_id: $model_id,
        model_manifest_sha256: $manifest_sha,
        artifact_id: $artifact_id,
        artifact_bytes: $artifact_bytes,
        artifact_sha256: $artifact_sha,
        canonical_path: $canonical_path,
        file: $fingerprint
      }
    '
}

metal_llm_artifact_storage_paths() {
    local model_id=$1 artifact_id=$2
    local verification_root="$METAL_LLM_ROOT/.lab/verification/artifacts"
    local model_root="$verification_root/$model_id"
    print -r -- "$verification_root"$'\t'"$model_root"$'\t'"$model_root/$artifact_id.json"
}

metal_llm_artifact_directory_status() {
    local target_path=$1 required_mode=${2:-} metadata parsed owner mode type links
    [[ ! -L "$target_path" ]] || {
        metal_llm_die "unsafe artifact receipt directory is a symlink: $target_path"
        return 2
    }
    [[ -e "$target_path" ]] || return 1
    metadata=$(metal_llm_artifact_lstat "$target_path" $'%u\t%Lp\t%HT\t%l') || {
        metal_llm_die "could not inspect artifact receipt directory: $target_path"
        return 2
    }
    parsed=$(metal_llm_artifact_parse_metadata "$metadata") || {
        metal_llm_die "unsupported artifact receipt directory metadata: $target_path"
        return 2
    }
    IFS=$'\t' read -r owner mode type links <<< "$parsed"
    [[ "$type" == 'Directory' && "$owner" == "$EUID" ]] || {
        metal_llm_die "unsafe artifact receipt directory type or owner: $target_path"
        return 2
    }
    if [[ -n "$required_mode" && "$mode" != "$required_mode" ]]; then
        metal_llm_die "unsafe artifact receipt directory mode: $target_path (expected $required_mode)"
        return 2
    fi
}

metal_llm_artifact_intermediate_directory_status() {
    local target_path=$1 metadata parsed owner mode type links
    [[ ! -L "$target_path" ]] || {
        metal_llm_die "unsafe artifact receipt path component is a symlink: $target_path"
        return 2
    }
    [[ -e "$target_path" ]] || return 1
    metadata=$(metal_llm_artifact_lstat "$target_path" $'%u\t%Lp\t%HT\t%l') || {
        metal_llm_die "could not inspect artifact receipt path component: $target_path"
        return 2
    }
    parsed=$(metal_llm_artifact_parse_metadata "$metadata") || {
        metal_llm_die "unsupported artifact receipt path component metadata: $target_path"
        return 2
    }
    IFS=$'\t' read -r owner mode type links <<< "$parsed"
    [[ "$type" == 'Directory' ]] || {
        metal_llm_die "unsafe artifact receipt path component is not a directory: $target_path"
        return 2
    }
}

metal_llm_artifact_receipt_path_status() {
    local model_id=$1 artifact_id=$2 storage_paths verification_root model_root receipt_path
    local component result_code metadata parsed owner mode type links
    storage_paths=$(metal_llm_artifact_storage_paths "$model_id" "$artifact_id") || return 2
    IFS=$'\t' read -r verification_root model_root receipt_path <<< "$storage_paths"

    for component in "$METAL_LLM_ROOT/.lab" "$METAL_LLM_ROOT/.lab/verification"; do
        result_code=0
        metal_llm_artifact_intermediate_directory_status "$component" || result_code=$?
        (( result_code == 0 )) || return "$result_code"
    done
    result_code=0
    metal_llm_artifact_directory_status "$verification_root" 700 || result_code=$?
    (( result_code == 0 )) || return "$result_code"
    result_code=0
    metal_llm_artifact_directory_status "$model_root" 700 || result_code=$?
    (( result_code == 0 )) || return "$result_code"

    [[ ! -L "$receipt_path" ]] || {
        metal_llm_die "unsafe artifact receipt is a symlink: $receipt_path"
        return 2
    }
    [[ -e "$receipt_path" ]] || return 1
    metadata=$(metal_llm_artifact_lstat "$receipt_path" $'%u\t%Lp\t%HT\t%l') || {
        metal_llm_die "could not inspect artifact receipt: $receipt_path"
        return 2
    }
    parsed=$(metal_llm_artifact_parse_metadata "$metadata") || {
        metal_llm_die "unsupported artifact receipt metadata: $receipt_path"
        return 2
    }
    IFS=$'\t' read -r owner mode type links <<< "$parsed"
    [[ "$owner" == "$EUID" && "$mode" == 600 && "$type" == 'Regular File' && "$links" == 1 ]] || {
        metal_llm_die "unsafe artifact receipt type, owner, mode, or link count: $receipt_path"
        return 2
    }
    print -r -- "$receipt_path"
}

metal_llm_artifact_receipt_content_valid() {
    local receipt_path=$1 model_id=$2 manifest_sha=$3 artifact_id=$4 artifact_bytes=$5
    local artifact_sha=$6 canonical_path=$7 fingerprint=$8
    local receipt_snapshot recorded_binding recomputed_json recomputed_binding
    receipt_snapshot=$(<"$receipt_path") || return 1
    jq -e \
      --arg model_id "$model_id" \
      --arg manifest_sha "$manifest_sha" \
      --arg artifact_id "$artifact_id" \
      --argjson artifact_bytes "$artifact_bytes" \
      --arg artifact_sha "$artifact_sha" \
      --arg canonical_path "$canonical_path" \
      --argjson fingerprint "$fingerprint" '
      def exact_keys($expected): (keys | sort) == ($expected | sort);
      type == "object" and
      exact_keys(["schema_version", "model_id", "model_manifest_sha256", "artifact_id",
        "artifact_bytes", "artifact_sha256", "canonical_path", "file", "binding_sha256",
        "full_verified_at"]) and
      .schema_version == 1 and .model_id == $model_id and
      .model_manifest_sha256 == $manifest_sha and .artifact_id == $artifact_id and
      .artifact_bytes == $artifact_bytes and .artifact_sha256 == $artifact_sha and
      .canonical_path == $canonical_path and .file == $fingerprint and
      (.file | exact_keys(["device_id", "inode", "size_bytes", "birth_time", "change_time",
        "modify_time"])) and
      (.binding_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.full_verified_at | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ' <<< "$receipt_snapshot" >/dev/null 2>&1 || return 1
    recorded_binding=$(jq -er '.binding_sha256' <<< "$receipt_snapshot") || return 1
    recomputed_json=$(jq -cS 'del(.binding_sha256, .full_verified_at)' \
      <<< "$receipt_snapshot") || return 1
    recomputed_binding=$(metal_llm_artifact_sha256_text "$recomputed_json") || return 1
    [[ "$recorded_binding" == "$recomputed_binding" ]] || return 1
    print -r -- "$recorded_binding"
}

metal_llm_artifact_receipt_lookup() {
    local model_id=$1 manifest_sha=$2 artifact_id=$3 artifact_bytes=$4
    local artifact_sha=$5 canonical_path=$6 fingerprint=$7
    local receipt_path result_code binding
    result_code=0
    receipt_path=$(metal_llm_artifact_receipt_path_status "$model_id" "$artifact_id") || result_code=$?
    (( result_code == 0 )) || return "$result_code"
    binding=$(metal_llm_artifact_receipt_content_valid "$receipt_path" "$model_id" "$manifest_sha" \
      "$artifact_id" "$artifact_bytes" "$artifact_sha" "$canonical_path" "$fingerprint") || return 1
    print -r -- "$binding"
}

metal_llm_artifact_create_directory() {
    local target_path=$1 strict_mode=$2 result_code
    result_code=0
    if (( strict_mode )); then
        metal_llm_artifact_directory_status "$target_path" 700 || result_code=$?
    else
        metal_llm_artifact_intermediate_directory_status "$target_path" || result_code=$?
    fi
    if (( result_code == 0 )); then
        return 0
    elif (( result_code == 2 )); then
        return 1
    fi
    ( umask 077; /bin/mkdir -- "$target_path" ) 2>/dev/null || true
    if (( strict_mode )); then
        metal_llm_artifact_directory_status "$target_path" 700
    else
        metal_llm_artifact_intermediate_directory_status "$target_path"
    fi
}

metal_llm_artifact_prepare_receipt_directory() {
    local model_id=$1 storage_paths verification_root model_root receipt_path
    local repository_root=${METAL_LLM_ROOT:A}
    storage_paths=$(metal_llm_artifact_storage_paths "$model_id" placeholder) || return 1
    IFS=$'\t' read -r verification_root model_root receipt_path <<< "$storage_paths"
    metal_llm_artifact_create_directory "$repository_root/.lab" 0 || return 1
    metal_llm_artifact_create_directory "$repository_root/.lab/verification" 0 || return 1
    metal_llm_artifact_create_directory "$verification_root" 1 || return 1
    metal_llm_artifact_create_directory "$model_root" 1 || return 1
}

metal_llm_artifact_publish_receipt() {
    local model_id=$1 manifest_sha=$2 artifact_id=$3 artifact_bytes=$4
    local artifact_sha=$5 canonical_path=$6 fingerprint=$7 binding=$8
    local storage_paths verification_root model_root receipt_path receipt_temp='' verified_binding
    local verified_at receipt_json result_code

    metal_llm_artifact_prepare_receipt_directory "$model_id" || return 1
    storage_paths=$(metal_llm_artifact_storage_paths "$model_id" "$artifact_id") || return 1
    IFS=$'\t' read -r verification_root model_root receipt_path <<< "$storage_paths"
    if [[ -e "$receipt_path" || -L "$receipt_path" ]]; then
        result_code=0
        metal_llm_artifact_receipt_path_status "$model_id" "$artifact_id" >/dev/null || result_code=$?
        (( result_code == 0 )) || return 1
    fi

    {
        receipt_temp=$(umask 077; /usr/bin/mktemp "$model_root/.${artifact_id}.json.XXXXXX") || return 1
        verified_at=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
        receipt_json=$(jq -cnS \
          --arg model_id "$model_id" \
          --arg manifest_sha "$manifest_sha" \
          --arg artifact_id "$artifact_id" \
          --argjson artifact_bytes "$artifact_bytes" \
          --arg artifact_sha "$artifact_sha" \
          --arg canonical_path "$canonical_path" \
          --argjson fingerprint "$fingerprint" \
          --arg binding "$binding" \
          --arg verified_at "$verified_at" '
          {
            schema_version: 1,
            model_id: $model_id,
            model_manifest_sha256: $manifest_sha,
            artifact_id: $artifact_id,
            artifact_bytes: $artifact_bytes,
            artifact_sha256: $artifact_sha,
            canonical_path: $canonical_path,
            file: $fingerprint,
            binding_sha256: $binding,
            full_verified_at: $verified_at
          }
        ') || return 1
        print -rn -- "$receipt_json" > "$receipt_temp" || return 1
        /bin/chmod 600 "$receipt_temp" || return 1
        verified_binding=$(metal_llm_artifact_receipt_content_valid "$receipt_temp" "$model_id" \
          "$manifest_sha" "$artifact_id" "$artifact_bytes" "$artifact_sha" "$canonical_path" \
          "$fingerprint") || return 1
        [[ "$verified_binding" == "$binding" ]] || return 1
        /bin/mv -f -- "$receipt_temp" "$receipt_path" || return 1
        receipt_temp=''
    } always {
        [[ -z "$receipt_temp" ]] || /bin/rm -f -- "$receipt_temp"
    }
}

metal_llm_artifact_refresh_identities() {
    local artifact_id identities='[]'
    for artifact_id in "${METAL_LLM_ARTIFACT_ORDER[@]}"; do
        identities=$(jq -cn --argjson identities "$identities" \
          --argjson identity "$METAL_LLM_ARTIFACT_IDENTITIES[$artifact_id]" \
          '$identities + [$identity]') || return 1
    done
    typeset -g METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES="$identities"
}

metal_llm_artifact_register() {
    local artifact_id=$1 canonical_path=$2 fingerprint=$3 binding=$4 memo_key=$5
    local artifact_bytes=$6 artifact_sha=$7 existing
    existing=${METAL_LLM_ARTIFACT_IDENTITIES[$artifact_id]:-}
    METAL_LLM_ARTIFACT_PATHS[$artifact_id]="$canonical_path"
    METAL_LLM_ARTIFACT_FINGERPRINTS[$artifact_id]="$fingerprint"
    METAL_LLM_ARTIFACT_BINDINGS[$artifact_id]="$binding"
    METAL_LLM_ARTIFACT_MEMO_KEYS[$artifact_id]="$memo_key"
    METAL_LLM_ARTIFACT_IDENTITIES[$artifact_id]=$(jq -cn --arg id "$artifact_id" \
      --argjson bytes "$artifact_bytes" --arg sha "$artifact_sha" \
      '{id: $id, bytes: $bytes, sha256: $sha}') || return 1
    [[ -n "$existing" ]] || METAL_LLM_ARTIFACT_ORDER+=("$artifact_id")
    metal_llm_artifact_refresh_identities
}

metal_llm_verify_model_artifact() {
    local manifest=$1 model_id=$2 artifact_dir=$3 artifact_id=$4
    local artifact_record filename expected_bytes expected_sha canonical_path manifest_sha
    local fingerprint memo_key binding lookup_status attempt post_fingerprint actual_sha binding_json actual_bytes

    metal_llm_artifact_require_session || return 1
    artifact_record=$(metal_llm_artifact_manifest_record "$manifest" "$model_id" "$artifact_id") || return 1
    IFS=$'\t' read -r filename expected_bytes expected_sha <<< "$artifact_record"
    canonical_path=$(metal_llm_artifact_resolve_path "$artifact_dir" "$filename" "$artifact_id") || return 1
    manifest_sha=$(metal_llm_sha256 "$manifest") || return 1
    [[ "$manifest_sha" =~ '^[0-9a-f]{64}$' ]] || return 1
    actual_bytes=$(metal_llm_file_size "$canonical_path") || return 1
    [[ "$actual_bytes" == "$expected_bytes" ]] || {
        metal_llm_die "byte count mismatch for $artifact_id: expected $expected_bytes, got $actual_bytes"
        return 1
    }
    fingerprint=$(metal_llm_artifact_fingerprint "$canonical_path") || return 1
    [[ "$(jq -r '.size_bytes' <<< "$fingerprint")" == "$expected_bytes" ]] || {
        metal_llm_die "byte count mismatch for $artifact_id: expected $expected_bytes, got $(jq -r '.size_bytes' <<< "$fingerprint")"
        return 1
    }
    memo_key="$model_id:$manifest_sha:$artifact_id:$canonical_path:$fingerprint"
    if [[ "${METAL_LLM_ARTIFACT_MEMO_KEYS[$artifact_id]:-}" == "$memo_key" ]]; then
        return 0
    fi

    binding=''
    if [[ "$METAL_LLM_ARTIFACT_CHECK_REQUESTED" == cached ]]; then
        lookup_status=0
        binding=$(metal_llm_artifact_receipt_lookup "$model_id" "$manifest_sha" "$artifact_id" \
          "$expected_bytes" "$expected_sha" "$canonical_path" "$fingerprint") || lookup_status=$?
        if (( lookup_status == 0 )); then
            (( METAL_LLM_ARTIFACT_CACHE_HITS += 1 ))
            metal_llm_artifact_register "$artifact_id" "$canonical_path" "$fingerprint" "$binding" \
              "$memo_key" "$expected_bytes" "$expected_sha"
            return $?
        elif (( lookup_status == 2 )); then
            return 1
        fi
        (( METAL_LLM_ARTIFACT_CACHE_MISSES += 1 ))
    fi

    for attempt in 1 2; do
        if (( attempt == 2 )); then
            fingerprint=$(metal_llm_artifact_fingerprint "$canonical_path") || return 1
            [[ "$(jq -r '.size_bytes' <<< "$fingerprint")" == "$expected_bytes" ]] || {
                metal_llm_die "byte count mismatch for $artifact_id after artifact change"
                return 1
            }
        fi
        (( METAL_LLM_ARTIFACT_FULL_HASHES += 1 ))
        actual_sha=$(metal_llm_artifact_compute_sha256 "$canonical_path") || return 1
        post_fingerprint=$(metal_llm_artifact_fingerprint "$canonical_path") || return 1
        if [[ "$fingerprint" != "$post_fingerprint" ]]; then
            if (( attempt == 1 )); then
                continue
            fi
            metal_llm_die "artifact changed repeatedly during hashing: $artifact_id"
            return 1
        fi
        [[ "$actual_sha" == "$expected_sha" ]] || {
            metal_llm_die "checksum mismatch for $artifact_id: expected $expected_sha, got $actual_sha"
            return 1
        }
        break
    done

    binding_json=$(metal_llm_artifact_binding_json "$model_id" "$manifest_sha" "$artifact_id" \
      "$expected_bytes" "$expected_sha" "$canonical_path" "$fingerprint") || return 1
    binding=$(metal_llm_artifact_sha256_text "$binding_json") || return 1
    if (( ! METAL_LLM_ARTIFACT_CHECK_DRY_RUN )); then
        metal_llm_artifact_publish_receipt "$model_id" "$manifest_sha" "$artifact_id" \
          "$expected_bytes" "$expected_sha" "$canonical_path" "$fingerprint" "$binding" || return 1
    fi
    memo_key="$model_id:$manifest_sha:$artifact_id:$canonical_path:$fingerprint"
    metal_llm_artifact_register "$artifact_id" "$canonical_path" "$fingerprint" "$binding" \
      "$memo_key" "$expected_bytes" "$expected_sha"
}

metal_llm_verify_configuration_artifacts() {
    local manifest=$1 model_id=$2 artifact_dir=$3 configuration=$4 schema_version artifact_id
    typeset -a artifact_ids
    metal_llm_artifact_require_session || return 1
    jq -e 'type == "object"' <<< "$configuration" >/dev/null 2>&1 || {
        metal_llm_die 'artifact verification requires normalized configuration JSON'
        return 1
    }
    schema_version=$(jq -er '.schema_version' "$manifest" 2>/dev/null) || return 1
    if [[ "$schema_version" == 1 ]]; then
        artifact_ids=("${(@f)$(jq -er --argjson configuration "$configuration" '
          reduce (
            .text_model.artifact_ids[],
            (if $configuration.vision.enabled then $configuration.vision.projector_artifact_id else empty end),
            (if $configuration.mtp.enabled then $configuration.mtp.artifact_id else empty end)
          ) as $id ([]; if index($id) then . else . + [$id] end)[]
        ' "$manifest")}") || return 1
    elif [[ "$schema_version" == 2 ]]; then
        artifact_ids=("${(@f)$(jq -er --argjson configuration "$configuration" '
          reduce (
            .text_model.artifact_ids[],
            (if $configuration.vision.enabled then $configuration.vision.projector_artifact_id else empty end),
            (if $configuration.mtp.policy != "off" then $configuration.mtp.artifact_id else empty end)
          ) as $id ([]; if index($id) then . else . + [$id] end)[]
        ' "$manifest")}") || return 1
    else
        metal_llm_die 'artifact verification requires a schema-v1 or schema-v2 model manifest'
        return 1
    fi
    (( ${#artifact_ids} > 0 )) || {
        metal_llm_die 'effective configuration has no model artifacts'
        return 1
    }
    for artifact_id in "${artifact_ids[@]}"; do
        metal_llm_verify_model_artifact "$manifest" "$model_id" "$artifact_dir" "$artifact_id" || return 1
    done
}

metal_llm_verified_artifact_path() {
    local artifact_id=$1 verified_path
    metal_llm_artifact_require_session || return 1
    metal_llm_valid_id "$artifact_id" || {
        metal_llm_die "invalid artifact ID: $artifact_id"
        return 1
    }
    verified_path=${METAL_LLM_ARTIFACT_PATHS[$artifact_id]:-}
    [[ -n "$verified_path" ]] || {
        metal_llm_die "artifact has not been verified in this invocation: $artifact_id"
        return 1
    }
    print -r -- "$verified_path"
}

metal_llm_install_verified_artifact() {
    local manifest=$1 model_id=$2 artifact_dir=$3 artifact_id=$4 part_path=$5
    local artifact_record filename expected_bytes expected_sha final_path manifest_sha
    local pre_fingerprint post_fingerprint actual_sha actual_bytes attempt final_fingerprint binding_json binding memo_key
    metal_llm_artifact_require_session || return 1
    (( ! METAL_LLM_ARTIFACT_CHECK_DRY_RUN )) || {
        metal_llm_die 'cannot install a verified artifact during dry-run'
        return 1
    }
    artifact_record=$(metal_llm_artifact_manifest_record "$manifest" "$model_id" "$artifact_id") || return 1
    IFS=$'\t' read -r filename expected_bytes expected_sha <<< "$artifact_record"
    final_path="$artifact_dir/$filename"
    metal_llm_artifact_validate_download_paths "$artifact_dir" "$filename" "$artifact_id" \
      "$part_path" || return 1
    [[ -f "$part_path" && ! -L "$part_path" ]] || {
        metal_llm_die "partial artifact is not a regular non-symlink file: $part_path"
        return 1
    }
    [[ ! -e "$final_path" && ! -L "$final_path" ]] || {
        metal_llm_die "refusing to overwrite artifact: $final_path"
        return 1
    }
    for attempt in 1 2; do
        actual_bytes=$(metal_llm_file_size "$part_path") || return 1
        [[ "$actual_bytes" == "$expected_bytes" ]] || {
            metal_llm_die "byte count mismatch for $artifact_id: expected $expected_bytes, got $actual_bytes"
            return 1
        }
        pre_fingerprint=$(metal_llm_artifact_fingerprint "$part_path") || return 1
        [[ "$(jq -r '.size_bytes' <<< "$pre_fingerprint")" == "$expected_bytes" ]] || {
            metal_llm_die "byte count mismatch for $artifact_id: expected $expected_bytes, got $(jq -r '.size_bytes' <<< "$pre_fingerprint")"
            return 1
        }
        (( METAL_LLM_ARTIFACT_FULL_HASHES += 1 ))
        actual_sha=$(metal_llm_artifact_compute_sha256 "$part_path") || return 1
        post_fingerprint=$(metal_llm_artifact_fingerprint "$part_path") || return 1
        if [[ "$pre_fingerprint" != "$post_fingerprint" ]]; then
            if (( attempt == 1 )); then
                continue
            fi
            metal_llm_die "artifact changed repeatedly during hashing: $artifact_id"
            return 1
        fi
        [[ "$actual_sha" == "$expected_sha" ]] || {
            metal_llm_die "checksum mismatch for $artifact_id: expected $expected_sha, got $actual_sha"
            return 1
        }
        break
    done
    metal_llm_artifact_validate_download_paths "$artifact_dir" "$filename" "$artifact_id" \
      "$part_path" || return 1
    /bin/mv -n -- "$part_path" "$final_path" || return 1
    [[ -f "$final_path" && ! -L "$final_path" && ! -e "$part_path" ]] || {
        metal_llm_die "could not install verified artifact without overwrite: $final_path"
        return 1
    }
    metal_llm_artifact_validate_directory_components "$artifact_dir" || return 1
    final_path=${final_path:A}
    final_fingerprint=$(metal_llm_artifact_fingerprint "$final_path") || return 1
    [[ "$(jq -r '.size_bytes' <<< "$final_fingerprint")" == "$expected_bytes" ]] || return 1
    jq -ne --argjson verified "$post_fingerprint" --argjson installed "$final_fingerprint" '
      ["device_id", "inode", "size_bytes", "birth_time", "modify_time"] |
      all(.[]; $verified[.] == $installed[.])
    ' >/dev/null || {
        metal_llm_die "installed artifact differs from verified partial: $artifact_id"
        return 1
    }
    manifest_sha=$(metal_llm_sha256 "$manifest") || return 1
    binding_json=$(metal_llm_artifact_binding_json "$model_id" "$manifest_sha" "$artifact_id" \
      "$expected_bytes" "$expected_sha" "$final_path" "$final_fingerprint") || return 1
    binding=$(metal_llm_artifact_sha256_text "$binding_json") || return 1
    metal_llm_artifact_publish_receipt "$model_id" "$manifest_sha" "$artifact_id" \
      "$expected_bytes" "$expected_sha" "$final_path" "$final_fingerprint" "$binding" || return 1
    memo_key="$model_id:$manifest_sha:$artifact_id:$final_path:$final_fingerprint"
    metal_llm_artifact_register "$artifact_id" "$final_path" "$final_fingerprint" "$binding" \
      "$memo_key" "$expected_bytes" "$expected_sha"
}

metal_llm_artifact_effective_mode() {
    if (( METAL_LLM_ARTIFACT_CACHE_HITS > 0 && METAL_LLM_ARTIFACT_FULL_HASHES > 0 )); then
        print -- mixed
    elif (( METAL_LLM_ARTIFACT_CACHE_HITS > 0 )); then
        print -- cached
    elif (( METAL_LLM_ARTIFACT_FULL_HASHES > 0 )); then
        print -- full
    else
        print -- not-run
    fi
}

metal_llm_artifact_verification_finalize() {
    local complete_set=$1 effective_mode artifact_id receipt_set='[]' receipt_set_sha
    typeset -a sorted_ids
    metal_llm_artifact_require_session || return 1
    [[ "$complete_set" == 0 || "$complete_set" == 1 ]] || {
        metal_llm_die 'artifact verification complete-set state must be 0 or 1'
        return 1
    }
    effective_mode=$(metal_llm_artifact_effective_mode) || return 1
    typeset -g METAL_LLM_ARTIFACT_EFFECTIVE_MODE="$effective_mode"
    if (( ! complete_set )); then
        (( METAL_LLM_ARTIFACT_CHECK_DRY_RUN )) || {
            metal_llm_die 'an incomplete artifact verification set is valid only during dry-run'
            return 1
        }
        unset METAL_LLM_ARTIFACT_VERIFICATION_JSON
        unset METAL_LLM_ARTIFACT_RECEIPT_SET_SHA256
        return 0
    fi
    [[ "$effective_mode" != not-run ]] || {
        metal_llm_die 'a complete artifact verification set cannot be empty'
        return 1
    }
    sorted_ids=("${(@f)$(print -rl -- "${METAL_LLM_ARTIFACT_ORDER[@]}" | LC_ALL=C /usr/bin/sort)}")
    for artifact_id in "${sorted_ids[@]}"; do
        receipt_set=$(jq -cn --argjson receipt_set "$receipt_set" \
          --arg artifact_id "$artifact_id" \
          --arg binding "$METAL_LLM_ARTIFACT_BINDINGS[$artifact_id]" \
          '$receipt_set + [{artifact_id: $artifact_id, binding_sha256: $binding}]') || return 1
    done
    receipt_set=$(jq -cS . <<< "$receipt_set") || return 1
    receipt_set_sha=$(metal_llm_artifact_sha256_text "$receipt_set") || return 1
    typeset -g METAL_LLM_ARTIFACT_RECEIPT_SET_SHA256="$receipt_set_sha"
    typeset -g METAL_LLM_ARTIFACT_VERIFICATION_JSON
    METAL_LLM_ARTIFACT_VERIFICATION_JSON=$(jq -cn \
      --arg requested "$METAL_LLM_ARTIFACT_CHECK_REQUESTED" \
      --arg effective "$effective_mode" \
      --argjson hits "$METAL_LLM_ARTIFACT_CACHE_HITS" \
      --argjson misses "$METAL_LLM_ARTIFACT_CACHE_MISSES" \
      --argjson hashes "$METAL_LLM_ARTIFACT_FULL_HASHES" \
      --arg receipt_set_sha "$receipt_set_sha" '
      {requested_mode: $requested, effective_mode: $effective, cache_hits: $hits,
       cache_misses: $misses, full_hashes: $hashes, receipt_set_sha256: $receipt_set_sha}
    ') || return 1
}

metal_llm_print_artifact_verification_summary() {
    metal_llm_artifact_require_session || return 1
    [[ -n "${METAL_LLM_ARTIFACT_EFFECTIVE_MODE:-}" ]] || {
        metal_llm_die 'artifact verification has not been finalized'
        return 1
    }
    print -n -- "artifact verification: requested=$METAL_LLM_ARTIFACT_CHECK_REQUESTED effective=$METAL_LLM_ARTIFACT_EFFECTIVE_MODE cache_hits=$METAL_LLM_ARTIFACT_CACHE_HITS cache_misses=$METAL_LLM_ARTIFACT_CACHE_MISSES full_hashes=$METAL_LLM_ARTIFACT_FULL_HASHES"
    if [[ -n "${METAL_LLM_ARTIFACT_RECEIPT_SET_SHA256:-}" ]]; then
        print -- " receipt_set_sha256=$METAL_LLM_ARTIFACT_RECEIPT_SET_SHA256"
    else
        print
    fi
}
