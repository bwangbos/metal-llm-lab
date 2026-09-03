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
    [[ -e "$artifact_path" ]] || {
        metal_llm_die "artifact is missing: $artifact_id ($artifact_path)"
        return 1
    }
    [[ -f "$artifact_path" && ! -L "$artifact_path" ]] || {
        metal_llm_die "artifact is not a regular file: $artifact_id ($artifact_path)"
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

metal_llm_detect_hardware_manifest() {
    command -v system_profiler >/dev/null 2>&1 || {
        metal_llm_die 'system_profiler is required to identify supported hardware'
        return 1
    }
    local system_details chip='' memory='' line memory_gib memory_bytes architecture
    system_details=$(system_profiler SPHardwareDataType 2>/dev/null) || {
        metal_llm_die 'could not detect hardware'
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
        metal_llm_die 'could not identify chip and unified memory'
        return 1
    }
    memory_gib=$match[1]
    memory_bytes=$(( memory_gib * 1024 * 1024 * 1024 ))
    architecture=$(uname -m 2>/dev/null || print -- unknown)

    local hardware_manifest
    typeset -a matching_manifests
    matching_manifests=()
    for hardware_manifest in "$METAL_LLM_ROOT"/manifests/hardware/*.json(N); do
        if jq -e --arg chip "$chip" --arg architecture "$architecture" --argjson memory "$memory_bytes" '
          .chip == $chip and .architecture == $architecture and .unified_memory_bytes == $memory
        ' "$hardware_manifest" >/dev/null 2>&1; then
            matching_manifests+=("$hardware_manifest")
        fi
    done
    (( ${#matching_manifests} == 1 )) || {
        metal_llm_die "no unique hardware manifest matches $chip with $memory"
        return 1
    }
    typeset -g METAL_LLM_DETECTED_HARDWARE_MANIFEST=$matching_manifests[1]
    typeset -g METAL_LLM_DETECTED_HARDWARE_ID
    METAL_LLM_DETECTED_HARDWARE_ID=$(jq -er '.id' "$METAL_LLM_DETECTED_HARDWARE_MANIFEST") || return 1
    typeset -g METAL_LLM_DETECTED_CHIP="$chip"
    typeset -g METAL_LLM_DETECTED_MEMORY_BYTES="$memory_bytes"
}

metal_llm_profile_artifact_identities() {
    local manifest=$1
    local artifact_dir=$2
    local profile_id=$3
    local artifact_id identities
    typeset -a artifact_ids

    artifact_ids=("${(@f)$(jq -er --arg profile "$profile_id" '
      first(.profiles[] | select(.id == $profile)) as $profile |
      reduce (
        .text_model.artifact_ids[] ,
        (if $profile.vision.enabled then $profile.vision.projector_artifact_id else empty end),
        (if $profile.mtp.enabled then $profile.mtp.artifact_id else empty end)
      ) as $id ([]; if index($id) then . else . + [$id] end)[]
    ' "$manifest")}") || return 1
    (( ${#artifact_ids} > 0 )) || {
        metal_llm_die "profile has no model artifacts: $profile_id"
        return 1
    }
    for artifact_id in "${artifact_ids[@]}"; do
        metal_llm_artifact_path "$manifest" "$artifact_dir" "$artifact_id" >/dev/null || return 1
    done
    identities=$(jq -c --argjson ids "$(jq -cn --args '$ARGS.positional' -- "${artifact_ids[@]}")" '
      [.artifacts[] | select(.id as $id | $ids | index($id)) |
        {id: .id, bytes: .bytes, sha256: .sha256}]
    ' "$manifest") || return 1
    typeset -g METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES="$identities"
}

metal_llm_verify_runtime_build() {
    local runtime_id=$1
    local runtime_manifest=$2
    local executable_name=$3
    local runtime_dir="$METAL_LLM_ROOT/.lab/runtimes/$runtime_id"
    local source_dir="$runtime_dir/source"
    local build_dir="$runtime_dir/build-metal"
    local receipt_path="$build_dir/build-receipt.json"
    local executable="$build_dir/bin/$executable_name"

    [[ "$executable_name" == llama-server || "$executable_name" == llama-bench ]] || {
        metal_llm_die "unsupported runtime executable: $executable_name"
        return 1
    }
    [[ -e "$receipt_path" ]] || {
        metal_llm_die "build receipt is missing: $runtime_id ($receipt_path)"
        return 1
    }
    [[ -f "$receipt_path" && ! -L "$receipt_path" ]] || {
        metal_llm_die "build receipt is not a regular file: $runtime_id ($receipt_path)"
        return 1
    }
    jq -e --arg runtime_id "$runtime_id" '
      (keys | sort) == (["binaries", "runtime_id", "runtime_manifest_sha256", "schema_version",
        "source_tree_sha", "tested_revision", "tested_tree_sha"] | sort) and
      .schema_version == 1 and .runtime_id == $runtime_id and
      (.runtime_manifest_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.tested_revision | type == "string" and test("^[0-9a-f]{40}$")) and
      (.source_tree_sha | type == "string" and test("^[0-9a-f]{40}$")) and
      (.tested_tree_sha | type == "string" and test("^[0-9a-f]{40}$")) and
      (.binaries | type == "object" and (keys | sort) == (["llama-bench", "llama-server"] | sort)) and
      all(.binaries[];
        type == "object" and keys == ["sha256"] and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
    ' "$receipt_path" >/dev/null 2>&1 || {
        metal_llm_die "invalid build receipt: $receipt_path"
        return 1
    }

    local expected_tree expected_revision manifest_sha receipt_sha receipt_record
    local receipt_manifest_sha receipt_revision receipt_source_tree receipt_tested_tree receipt_executable_sha
    expected_tree=$(jq -er '.tested_tree_sha' "$runtime_manifest") || return 1
    expected_revision=$(jq -er '.tested_revision' "$runtime_manifest") || return 1
    manifest_sha=$(metal_llm_sha256 "$runtime_manifest") || return 1
    receipt_sha=$(metal_llm_sha256 "$receipt_path") || return 1
    receipt_record=$(jq -er --arg executable "$executable_name" '[
      .runtime_manifest_sha256, .tested_revision, .source_tree_sha, .tested_tree_sha,
      .binaries[$executable].sha256
    ] | @tsv' "$receipt_path") || return 1
    IFS=$'\t' read -r receipt_manifest_sha receipt_revision receipt_source_tree \
        receipt_tested_tree receipt_executable_sha <<< "$receipt_record"
    [[ "$receipt_manifest_sha" == "$manifest_sha" ]] || {
        metal_llm_die "build receipt does not match runtime manifest: $runtime_id"
        return 1
    }
    [[ "$receipt_revision" == "$expected_revision" ]] || {
        metal_llm_die "build receipt has stale tested revision: $runtime_id"
        return 1
    }
    [[ "$receipt_source_tree" == "$expected_tree" && "$receipt_tested_tree" == "$expected_tree" ]] || {
        metal_llm_die "build receipt has stale source tree: $runtime_id"
        return 1
    }

    command -v git >/dev/null 2>&1 || { metal_llm_die 'git is required'; return 1; }
    [[ -d "$source_dir" ]] || { metal_llm_die "runtime source is missing: $source_dir"; return 1; }
    git -C "$source_dir" rev-parse --git-dir >/dev/null 2>&1 || {
        metal_llm_die "runtime source is not a Git checkout: $source_dir"
        return 1
    }
    local source_status ignored_files actual_tree
    source_status=$(git -C "$source_dir" status --porcelain=v1 --untracked-files=all) || return 1
    ignored_files=$(git -C "$source_dir" ls-files --others --ignored --exclude-standard) || return 1
    [[ -z "$source_status" && -z "$ignored_files" ]] || {
        metal_llm_die "runtime source is not clean: $runtime_id"
        return 1
    }
    actual_tree=$(git -C "$source_dir" rev-parse 'HEAD^{tree}') || return 1
    [[ "$actual_tree" == "$expected_tree" && "$actual_tree" == "$receipt_source_tree" ]] || {
        metal_llm_die "runtime source tree mismatch for $runtime_id: expected $expected_tree, got $actual_tree"
        return 1
    }

    [[ -e "$executable" ]] || {
        metal_llm_die "${executable_name#llama-} executable is missing: $executable"
        return 1
    }
    [[ -f "$executable" && -x "$executable" && ! -L "$executable" ]] || {
        metal_llm_die "runtime executable is not a regular executable: $executable"
        return 1
    }
    local executable_sha
    executable_sha=$(metal_llm_sha256 "$executable") || return 1
    [[ "$executable_sha" == "$receipt_executable_sha" ]] || {
        metal_llm_die "${executable_name#llama-} binary checksum mismatch for $runtime_id"
        return 1
    }

    typeset -g METAL_LLM_VERIFIED_EXECUTABLE="$executable"
    typeset -g METAL_LLM_VERIFIED_RUNTIME_REVISION="$expected_revision"
    typeset -g METAL_LLM_VERIFIED_RUNTIME_TREE="$actual_tree"
    typeset -g METAL_LLM_VERIFIED_RUNTIME_MANIFEST_SHA256="$manifest_sha"
    typeset -g METAL_LLM_VERIFIED_BUILD_RECEIPT_SHA256="$receipt_sha"
    typeset -g METAL_LLM_VERIFIED_EXECUTABLE_SHA256="$executable_sha"
}
