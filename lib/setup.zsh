metal_llm_validate_model_manifest() {
    local manifest=$1
    local expected_id=$2

    jq -er --arg expected_id "$expected_id" '
        (.schema_version == 1) and
        (.id == $expected_id) and
        (.name | type == "string" and length > 0) and
        (.artifacts | type == "array" and length > 0 and all(.[ ];
            (.id | type == "string" and test("^[a-z0-9]+([.-][a-z0-9]+)*$")) and
            (.kind == "model" or .kind == "projector" or .kind == "mtp") and
            (.filename | type == "string" and length > 0 and . != "." and . != ".." and
                (contains("/") | not) and (contains("\t") | not) and (contains("\n") | not)) and
            (.url | type == "string" and length > 0 and
                (contains("\t") | not) and (contains("\n") | not)) and
            (.bytes | type == "number" and . > 0 and floor == .) and
            (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
            (.license_url | type == "string" and length > 0 and
                (contains("\t") | not) and (contains("\n") | not))
        )) and
        (.text_model.artifact_ids | type == "array" and length > 0) and
        (.text_model.total_bytes | type == "number" and . > 0 and floor == .) and
        (.profiles | type == "array" and length > 0 and all(.[ ];
            (.id | type == "string") and
            (.runtime_id | type == "string" and test("^[a-z0-9]+([.-][a-z0-9]+)*$")) and
            (.model_artifact_id | type == "string") and
            (.context | type == "number" and . > 0) and
            (.vision | type == "object") and
            (.mtp | type == "object") and
            (.metal | type == "object")
        )) and
        ([.artifacts[].id] | length == (unique | length)) and
        ([.text_model.artifact_ids[] as $id | any(.artifacts[]; .id == $id)] | all) and
        ([.profiles[].model_artifact_id as $id | any(.artifacts[]; .id == $id)] | all)
    ' "$manifest" >/dev/null
}

metal_llm_validate_runtime_manifest() {
    local manifest=$1
    local expected_id=$2

    jq -er --arg expected_id "$expected_id" '
        (.schema_version == 1) and
        (.id == $expected_id) and
        (.repository | type == "string" and length > 0) and
        (.base_revision | type == "string" and test("^[0-9a-f]{40}$")) and
        (.build.generator | type == "string" and length > 0) and
        (.build.cmake_options | type == "object" and all(keys[]; test("^[A-Z][A-Z0-9_]*$"))) and
        (.build.targets | type == "array" and length > 0 and all(.[ ];
            type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$")))
    ' "$manifest" >/dev/null
}

metal_llm_setup_usage() {
    metal_llm_error 'usage: metal-llm setup MODEL [--dry-run] [--yes]'
    return 2
}

metal_llm_remaining_artifact_bytes() {
    local model_manifest=$1
    local artifact_dir=$2
    local remaining_bytes=0
    local artifact_id artifact_filename artifact_bytes artifact_sha
    local final_path part_path present_bytes present_sha

    while IFS=$'\t' read -r artifact_id artifact_filename artifact_bytes artifact_sha; do
        final_path="$artifact_dir/$artifact_filename"
        part_path="$final_path.part"

        if [[ -e "$final_path" ]]; then
            [[ -f "$final_path" ]] || {
                metal_llm_die "artifact path is not a regular file: $final_path"
                return 1
            }
            present_bytes=$(metal_llm_file_size "$final_path") || return 1
            present_sha=$(metal_llm_sha256 "$final_path") || return 1
            if [[ "$present_bytes" != "$artifact_bytes" || "$present_sha" != "$artifact_sha" ]]; then
                metal_llm_die "refusing to overwrite unverified artifact: $final_path"
                return 1
            fi
            continue
        fi

        if [[ -e "$part_path" ]]; then
            [[ -f "$part_path" ]] || {
                metal_llm_die "partial artifact is not a regular file: $part_path"
                return 1
            }
            present_bytes=$(metal_llm_file_size "$part_path") || return 1
            if (( present_bytes > artifact_bytes )); then
                metal_llm_die "byte count mismatch for $artifact_id: expected $artifact_bytes, got $present_bytes"
                return 1
            fi
            remaining_bytes=$(( remaining_bytes + artifact_bytes - present_bytes ))
        else
            remaining_bytes=$(( remaining_bytes + artifact_bytes ))
        fi
    done < <(jq -er '.artifacts[] | [.id, .filename, (.bytes | tostring), .sha256] | @tsv' "$model_manifest")

    print -- "$remaining_bytes"
}

metal_llm_setup() {
    local model_id=''
    local dry_run=0
    local assume_yes=0
    local argument

    for argument in "$@"; do
        case "$argument" in
            --dry-run)
                (( dry_run == 0 )) || { metal_llm_setup_usage; return $?; }
                dry_run=1
                ;;
            --yes)
                (( assume_yes == 0 )) || { metal_llm_setup_usage; return $?; }
                assume_yes=1
                ;;
            -*) metal_llm_setup_usage; return $? ;;
            *)
                [[ -z "$model_id" ]] || { metal_llm_setup_usage; return $?; }
                model_id=$argument
                ;;
        esac
    done

    [[ -n "$model_id" ]] || { metal_llm_setup_usage; return $?; }
    metal_llm_valid_id "$model_id" || { metal_llm_die "invalid model id: $model_id"; return 1; }
    metal_llm_require_supported_host || return 1
    command -v jq >/dev/null 2>&1 || { metal_llm_die 'jq is required'; return 1; }

    local model_manifest="$METAL_LLM_ROOT/manifests/models/$model_id.json"
    [[ -f "$model_manifest" ]] || { metal_llm_die "model manifest not found: $model_id"; return 1; }
    metal_llm_validate_model_manifest "$model_manifest" "$model_id" || {
        metal_llm_die "invalid model manifest: $model_manifest"
        return 1
    }

    local runtime_id runtime_manifest
    runtime_id=$(jq -er '.profiles[0].runtime_id' "$model_manifest") || return 1
    runtime_manifest="$METAL_LLM_ROOT/manifests/runtimes/$runtime_id.json"
    [[ -f "$runtime_manifest" ]] || { metal_llm_die "runtime manifest not found: $runtime_id"; return 1; }
    metal_llm_validate_runtime_manifest "$runtime_manifest" "$runtime_id" || {
        metal_llm_die "invalid runtime manifest: $runtime_manifest"
        return 1
    }

    local artifact_dir="$METAL_LLM_ROOT/.lab/artifacts/$model_id"
    local remaining_bytes build_reserve_bytes required_bytes available_bytes
    remaining_bytes=$(metal_llm_remaining_artifact_bytes "$model_manifest" "$artifact_dir") || return 1
    build_reserve_bytes=${METAL_LLM_BUILD_RESERVE_BYTES:-5368709120}
    [[ "$build_reserve_bytes" == <-> ]] || {
        metal_llm_die 'METAL_LLM_BUILD_RESERVE_BYTES must be a non-negative integer'
        return 1
    }
    required_bytes=$(( remaining_bytes + build_reserve_bytes ))
    available_bytes=$(metal_llm_disk_bytes "$METAL_LLM_ROOT") || {
        metal_llm_die 'could not determine free disk space'
        return 1
    }
    print -- "remaining artifact bytes: $remaining_bytes"
    print -- "build reserve bytes: $build_reserve_bytes"
    print -- "total required disk bytes: $required_bytes"
    print -- "available disk bytes: $available_bytes"
    if (( available_bytes < required_bytes )); then
        metal_llm_die "insufficient disk space: $available_bytes bytes available, $required_bytes bytes required"
        return 1
    fi

    if (( dry_run == 0 && assume_yes == 0 )) && [[ -t 0 ]]; then
        print -n -- "Set up $model_id with $remaining_bytes artifact bytes remaining? [y/N] "
        local confirmation=''
        read -r confirmation
        [[ "$confirmation" == [yY] || "$confirmation" == [yY][eE][sS] ]] || {
            metal_llm_die 'setup cancelled'
            return 1
        }
    fi

    local sync_script="$METAL_LLM_ROOT/scripts/runtime-sync.zsh"
    [[ -x "$sync_script" ]] || { metal_llm_die "missing executable runtime sync: $sync_script"; return 1; }
    if (( dry_run == 1 )); then
        "$sync_script" "$runtime_id" --dry-run || return 1
    else
        "$sync_script" "$runtime_id" || return 1
    fi

    local source_dir="$METAL_LLM_ROOT/.lab/runtimes/$runtime_id/source"
    local build_dir="$METAL_LLM_ROOT/.lab/runtimes/$runtime_id/build-metal"
    local generator
    generator=$(jq -er '.build.generator' "$runtime_manifest") || return 1
    typeset -a cmake_arguments build_targets
    cmake_arguments=(-S "$source_dir" -B "$build_dir" -G "$generator")

    local option_key option_value
    while IFS=$'\t' read -r option_key option_value; do
        cmake_arguments+=("-D${option_key}=${option_value}")
    done < <(jq -er '.build.cmake_options | to_entries[] | [.key, (.value | tostring)] | @tsv' "$runtime_manifest")
    build_targets=("${(@f)$(jq -er '.build.targets[]' "$runtime_manifest")}")

    print -- "configure runtime: $runtime_id"
    if (( dry_run == 1 )); then
        metal_llm_print_command cmake "${cmake_arguments[@]}"
    else
        command -v cmake >/dev/null 2>&1 || { metal_llm_die 'cmake is required'; return 1; }
        mkdir -p "$build_dir"
        cmake "${cmake_arguments[@]}" || return 1
    fi

    print -- "build targets: ${build_targets[*]}"
    if (( dry_run == 1 )); then
        metal_llm_print_command cmake --build "$build_dir" --target "${build_targets[@]}"
    else
        cmake --build "$build_dir" --target "${build_targets[@]}" || return 1
    fi

    local smoke_name smoke_executable
    for smoke_name in llama-server llama-bench; do
        smoke_executable="$build_dir/bin/$smoke_name"
        print -- "smoke test executable: $smoke_name --help"
        if (( dry_run == 1 )); then
            metal_llm_print_command "$smoke_executable" --help
        else
            [[ -x "$smoke_executable" ]] || {
                metal_llm_die "smoke test executable is missing: $smoke_executable"
                return 1
            }
            if ! "$smoke_executable" --help >/dev/null 2>&1; then
                metal_llm_die "smoke test failed: $smoke_name"
                return 1
            fi
        fi
    done

    local artifact_id artifact_filename artifact_url artifact_bytes artifact_sha artifact_license
    local final_path part_path existing_bytes existing_sha download_required partial_bytes
    local actual_bytes actual_sha
    typeset -a curl_arguments
    while IFS=$'\t' read -r artifact_id artifact_filename artifact_url artifact_bytes artifact_sha artifact_license; do
        final_path="$artifact_dir/$artifact_filename"
        part_path="$final_path.part"

        if (( dry_run == 1 )); then
            print -- "download artifact: $artifact_id"
        else
            print -- "artifact: $artifact_id"
        fi
        print -- "source: $artifact_url"
        print -- "license: $artifact_license"
        print -- "expected bytes: $artifact_bytes"

        if (( dry_run == 1 )); then
            [[ -n "${HF_TOKEN:-}" ]] && print -- 'authorization: Bearer <redacted>'
            print -- "verify bytes: $part_path"
            print -- "verify sha256: $part_path"
            print -- "publish artifact atomically: $part_path -> $final_path"
            continue
        fi

        if [[ -e "$final_path" ]]; then
            [[ -f "$final_path" ]] || { metal_llm_die "artifact path is not a regular file: $final_path"; return 1; }
            existing_bytes=$(metal_llm_file_size "$final_path") || return 1
            existing_sha=$(metal_llm_sha256 "$final_path") || return 1
            if [[ "$existing_bytes" == "$artifact_bytes" && "$existing_sha" == "$artifact_sha" ]]; then
                print -- "using verified artifact: $artifact_id"
                continue
            fi
            metal_llm_die "refusing to overwrite unverified artifact: $final_path"
            return 1
        fi

        mkdir -p "$artifact_dir"
        download_required=1
        if [[ -e "$part_path" ]]; then
            [[ -f "$part_path" ]] || { metal_llm_die "partial artifact is not a regular file: $part_path"; return 1; }
            partial_bytes=$(metal_llm_file_size "$part_path") || return 1
            if (( partial_bytes > artifact_bytes )); then
                metal_llm_die "byte count mismatch for $artifact_id: expected $artifact_bytes, got $partial_bytes"
                return 1
            elif (( partial_bytes == artifact_bytes )); then
                download_required=0
                print -- "verifying completed partial artifact: $artifact_id"
            else
                print -- "resuming artifact: $artifact_id"
            fi
        else
            print -- "downloading artifact: $artifact_id"
        fi

        if (( download_required == 1 )); then
            command -v curl >/dev/null 2>&1 || { metal_llm_die 'curl is required'; return 1; }
            curl_arguments=(--fail --location --continue-at - --silent --show-error --output "$part_path")
            [[ -n "${HF_TOKEN:-}" ]] && curl_arguments+=(--header "Authorization: Bearer $HF_TOKEN")
            curl_arguments+=(-- "$artifact_url")
            curl "${curl_arguments[@]}" || return 1
        fi

        actual_bytes=$(metal_llm_file_size "$part_path") || return 1
        if [[ "$actual_bytes" != "$artifact_bytes" ]]; then
            metal_llm_die "byte count mismatch for $artifact_id: expected $artifact_bytes, got $actual_bytes"
            return 1
        fi
        actual_sha=$(metal_llm_sha256 "$part_path") || return 1
        if [[ "$actual_sha" != "$artifact_sha" ]]; then
            metal_llm_die "checksum mismatch for $artifact_id: expected $artifact_sha, got $actual_sha"
            return 1
        fi

        [[ ! -e "$final_path" ]] || { metal_llm_die "refusing to overwrite artifact: $final_path"; return 1; }
        mv "$part_path" "$final_path" || return 1
        print -- "verified artifact: $artifact_id"
    done < <(jq -er '.artifacts[] | [.id, .filename, .url, (.bytes | tostring), .sha256, .license_url] | @tsv' "$model_manifest")

    print -- 'next command:'
    print -- "./bin/metal-llm serve $model_id --profile auto"
}
