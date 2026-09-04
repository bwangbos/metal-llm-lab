#!/bin/zsh
set -euo pipefail
setopt no_bg_nice

root=${0:A:h:h}
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-artifact-verification.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT

source "$root/lib/common.zsh"
source "$root/lib/artifact-verification.zsh"

fail() {
    print -u2 -- "$1"
    exit 1
}

fixture_root="$temporary_root/repository"
artifact_dir="$fixture_root/artifacts/fixture-model"
manifest="$fixture_root/manifests/models/fixture-model.json"
mkdir -p "$artifact_dir" "${manifest:h}"
print -n -- 'alpha' > "$artifact_dir/model-a.gguf"
print -n -- 'bravo!' > "$artifact_dir/model-b.gguf"

model_a_sha=$(metal_llm_sha256 "$artifact_dir/model-a.gguf")
model_b_sha=$(metal_llm_sha256 "$artifact_dir/model-b.gguf")
jq -n \
  --arg model_a_sha "$model_a_sha" \
  --arg model_b_sha "$model_b_sha" '
  {
    schema_version: 1,
    id: "fixture-model",
    artifacts: [
      {id: "model-a", filename: "model-a.gguf", bytes: 5, sha256: $model_a_sha},
      {id: "model-b", filename: "model-b.gguf", bytes: 6, sha256: $model_b_sha}
    ],
    text_model: {artifact_ids: ["model-a", "model-b"], total_bytes: 11}
  }
' > "$manifest"

METAL_LLM_ROOT=$fixture_root
export METAL_LLM_ROOT

artifact_hash_log="$temporary_root/artifact-hashes.log"
: > "$artifact_hash_log"
metal_llm_artifact_compute_sha256() {
    print -r -- "$1" >> "$artifact_hash_log"
    metal_llm_sha256 "$1"
}
artifact_hash_count() {
    wc -l < "$artifact_hash_log" | tr -d ' '
}

metal_llm_artifact_verification_begin cached 0
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
metal_llm_artifact_verification_finalize 1
(( $(artifact_hash_count) == 1 )) || fail 'cold cached verification did not hash once'
jq -e '.requested_mode == "cached" and .effective_mode == "full" and
  .cache_hits == 0 and .cache_misses == 1 and .full_hashes == 1' \
  <<< "$METAL_LLM_ARTIFACT_VERIFICATION_JSON" >/dev/null || fail 'bad cold summary'

: > "$artifact_hash_log"
metal_llm_artifact_verification_begin cached 0
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
metal_llm_artifact_verification_finalize 1
(( $(artifact_hash_count) == 0 )) || fail 'warm cached verification read artifact body'
jq -e '.effective_mode == "cached" and .cache_hits == 1 and
  .cache_misses == 0 and .full_hashes == 0' \
  <<< "$METAL_LLM_ARTIFACT_VERIFICATION_JSON" >/dev/null || fail 'bad warm summary'
cached_summary=$METAL_LLM_ARTIFACT_VERIFICATION_JSON
receipt_path="$fixture_root/.lab/verification/artifacts/fixture-model/model-a.json"
verification_root="$fixture_root/.lab/verification/artifacts"
model_receipt_root="$verification_root/fixture-model"
before_verified_at=$(jq -r '.full_verified_at' "$receipt_path")

: > "$artifact_hash_log"
/bin/sleep 1
metal_llm_artifact_verification_begin full 0
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
metal_llm_artifact_verification_finalize 1
(( $(artifact_hash_count) == 1 )) || fail 'forced full verification reused receipt'
full_summary=$METAL_LLM_ARTIFACT_VERIFICATION_JSON
after_verified_at=$(jq -r '.full_verified_at' "$receipt_path")
[[ "$before_verified_at" != "$after_verified_at" ]] || fail 'full refresh did not update verification time'
before_set=$(jq -r '.receipt_set_sha256' <<< "$cached_summary")
after_set=$(jq -r '.receipt_set_sha256' <<< "$full_summary")
[[ "$before_set" == "$after_set" ]] || fail 'verification time changed stable set digest'

expected_binding_json=$(jq -cS 'del(.binding_sha256, .full_verified_at)' "$receipt_path")
expected_binding=$(print -rn -- "$expected_binding_json" | /usr/bin/shasum -a 256)
expected_binding=${expected_binding%% *}
jq -e --arg binding "$expected_binding" '
  (keys | sort) == (["schema_version", "model_id", "model_manifest_sha256", "artifact_id",
    "artifact_bytes", "artifact_sha256", "canonical_path", "file", "binding_sha256",
    "full_verified_at"] | sort) and
  (.file | keys | sort) == (["device_id", "inode", "size_bytes", "birth_time",
    "change_time", "modify_time"] | sort) and
  .binding_sha256 == $binding
' "$receipt_path" >/dev/null || fail 'cold verification wrote an inexact receipt'
receipt_metadata=$(/usr/bin/stat -f $'%u\t%Lp\t%HT\t%l' "$receipt_path")
[[ "$receipt_metadata" == "$EUID"$'\t600\tRegular File\t1' ]] || fail 'receipt safety metadata is wrong'

refresh_alpha_receipt() {
    print -n -- 'alpha' > "$artifact_dir/model-a.gguf"
    metal_llm_artifact_verification_begin full 0
    metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
    metal_llm_artifact_verification_finalize 1
    : > "$artifact_hash_log"
}

rewrite_receipt() {
    local filter=$1 temporary_receipt="$receipt_path.rewrite" binding_json binding
    jq "$filter" "$receipt_path" > "$temporary_receipt" || return 1
    binding_json=$(jq -cS 'del(.binding_sha256, .full_verified_at)' "$temporary_receipt") || return 1
    binding=$(print -rn -- "$binding_json" | /usr/bin/shasum -a 256) || return 1
    binding=${binding%% *}
    jq --arg binding "$binding" '.binding_sha256 = $binding' "$temporary_receipt" > "$receipt_path" || return 1
    /bin/rm -f -- "$temporary_receipt"
    /bin/chmod 600 "$receipt_path"
}

inventory_tree() {
    local tree_root=$1 item digest relative
    while IFS= read -r item; do
        relative=${item#$tree_root/}
        if [[ -f "$item" && ! -L "$item" ]]; then
            digest=$(metal_llm_sha256 "$item") || return 1
            print -r -- "file\t$relative\t$digest"
        elif [[ -d "$item" && ! -L "$item" ]]; then
            print -r -- "directory\t$relative"
        elif [[ -L "$item" ]]; then
            print -r -- "symlink\t$relative\t$(/bin/readlink "$item")"
        fi
    done < <(/usr/bin/find "$tree_root" -print | /usr/bin/sort)
}

# Same-size content changes must miss and hash rather than trusting the receipt.
receipt_before_failure=$(metal_llm_sha256 "$receipt_path")
print -n -- 'omega' > "$artifact_dir/model-a.gguf"
: > "$artifact_hash_log"
metal_llm_artifact_verification_begin cached 0
if metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a >/dev/null 2>&1; then
    fail 'same-size checksum mutation was accepted'
fi
(( $(artifact_hash_count) == 1 )) || fail 'same-size mutation used cached receipt'
[[ "$(metal_llm_sha256 "$receipt_path")" == "$receipt_before_failure" ]] ||
  fail 'checksum failure replaced the prior receipt'
refresh_alpha_receipt

# Replacing the inode while preserving size and mtime must still invalidate.
old_inode=$(jq -r '.file.inode' "$receipt_path")
old_inode_set=$(jq -r '.receipt_set_sha256' <<< "$METAL_LLM_ARTIFACT_VERIFICATION_JSON")
/bin/cp "$artifact_dir/model-a.gguf" "$artifact_dir/model-a.gguf.replacement"
/usr/bin/touch -r "$artifact_dir/model-a.gguf" "$artifact_dir/model-a.gguf.replacement"
/bin/mv -f "$artifact_dir/model-a.gguf.replacement" "$artifact_dir/model-a.gguf"
: > "$artifact_hash_log"
metal_llm_artifact_verification_begin cached 0
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
metal_llm_artifact_verification_finalize 1
(( $(artifact_hash_count) == 1 )) || fail 'inode replacement used cached receipt'
[[ "$(jq -r '.file.inode' "$receipt_path")" != "$old_inode" ]] || fail 'inode replacement kept stale binding'
[[ "$(jq -r '.receipt_set_sha256' <<< "$METAL_LLM_ARTIFACT_VERIFICATION_JSON")" != "$old_inode_set" ]] ||
  fail 'stable inode binding change did not change receipt-set digest'

# Every fingerprint field participates in the cache decision, even with a valid binding digest.
for fingerprint_field in device_id inode size_bytes birth_time change_time modify_time; do
    rewrite_receipt ".file.${fingerprint_field} += \"1\""
    : > "$artifact_hash_log"
    metal_llm_artifact_verification_begin cached 0
    metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
    metal_llm_artifact_verification_finalize 1
    (( $(artifact_hash_count) == 1 )) || fail "mutated $fingerprint_field fingerprint used cache"
done

# Manifest SHA, byte-count, and final-path changes invalidate the old receipt.
wrong_sha_manifest="$temporary_root/wrong-sha.json"
jq '(.artifacts[] | select(.id == "model-a")).sha256 = ("0" * 64)' "$manifest" > "$wrong_sha_manifest"
: > "$artifact_hash_log"
metal_llm_artifact_verification_begin cached 0
if metal_llm_verify_model_artifact "$wrong_sha_manifest" fixture-model "$artifact_dir" model-a >/dev/null 2>&1; then
    fail 'manifest checksum mutation was accepted'
fi
(( $(artifact_hash_count) == 1 )) || fail 'manifest checksum mutation did not force a hash'

wrong_bytes_manifest="$temporary_root/wrong-bytes.json"
jq '(.artifacts[] | select(.id == "model-a")).bytes = 6' "$manifest" > "$wrong_bytes_manifest"
: > "$artifact_hash_log"
metal_llm_artifact_verification_begin cached 0
if metal_llm_verify_model_artifact "$wrong_bytes_manifest" fixture-model "$artifact_dir" model-a >/dev/null 2>&1; then
    fail 'manifest byte-count mutation was accepted'
fi
(( $(artifact_hash_count) == 0 )) || fail 'known byte-count mismatch read artifact body'

print -n -- 'alpha' > "$artifact_dir/model-a-alias.gguf"
wrong_path_manifest="$temporary_root/wrong-path.json"
jq '(.artifacts[] | select(.id == "model-a")).filename = "model-a-alias.gguf"' \
  "$manifest" > "$wrong_path_manifest"
: > "$artifact_hash_log"
metal_llm_artifact_verification_begin cached 0
metal_llm_verify_model_artifact "$wrong_path_manifest" fixture-model "$artifact_dir" model-a
metal_llm_artifact_verification_finalize 1
(( $(artifact_hash_count) == 1 )) || fail 'manifest path mutation used old-path receipt'
[[ "$(jq -r '.canonical_path' "$receipt_path")" == "${artifact_dir:A}/model-a-alias.gguf" ]] ||
  fail 'manifest path mutation did not bind the new path'
refresh_alpha_receipt

# Safe malformed, unknown-version, wrong-schema, and invalid-binding receipts are misses.
for malformed_filter in 'empty' '.schema_version = 99' '.unexpected = true' '.binding_sha256 = ("f" * 64)'; do
    if [[ "$malformed_filter" == empty ]]; then
        print -rn -- '{' > "$receipt_path"
        /bin/chmod 600 "$receipt_path"
    else
        jq "$malformed_filter" "$receipt_path" > "$receipt_path.malformed"
        /bin/mv -f "$receipt_path.malformed" "$receipt_path"
        /bin/chmod 600 "$receipt_path"
    fi
    : > "$artifact_hash_log"
    metal_llm_artifact_verification_begin cached 0
    metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
    metal_llm_artifact_verification_finalize 1
    (( $(artifact_hash_count) == 1 )) || fail "safe malformed receipt used cache: $malformed_filter"
done

# Unsafe receipt objects and parent directories fail closed before body hashing.
/bin/cp "$receipt_path" "$temporary_root/safe-receipt.json"
/bin/rm -f -- "$receipt_path"
/bin/ln -s "$temporary_root/safe-receipt.json" "$receipt_path"
: > "$artifact_hash_log"
metal_llm_artifact_verification_begin cached 0
if metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a >/dev/null 2>&1; then
    fail 'symlink receipt was accepted'
fi
(( $(artifact_hash_count) == 0 )) || fail 'symlink receipt hashed before failing closed'
/bin/rm -f -- "$receipt_path"
/bin/cp "$temporary_root/safe-receipt.json" "$receipt_path"
/bin/chmod 600 "$receipt_path"

/bin/mv "$receipt_path" "$temporary_root/hardlinked-receipt.json"
/bin/ln "$temporary_root/hardlinked-receipt.json" "$receipt_path"
: > "$artifact_hash_log"
metal_llm_artifact_verification_begin cached 0
if metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a >/dev/null 2>&1; then
    fail 'hard-linked receipt was accepted'
fi
(( $(artifact_hash_count) == 0 )) || fail 'hard-linked receipt hashed before failing closed'
/bin/rm -f -- "$receipt_path"
/bin/mv "$temporary_root/hardlinked-receipt.json" "$receipt_path"

/bin/chmod 644 "$receipt_path"
metal_llm_artifact_verification_begin cached 0
if metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a >/dev/null 2>&1; then
    fail 'wrong-mode receipt was accepted'
fi
/bin/chmod 600 "$receipt_path"

original_lstat=${functions[metal_llm_artifact_lstat]}
metal_llm_artifact_lstat() {
    local target_path=$1 format=$2
    if [[ "$target_path" == "$receipt_path" && "$format" == $'%u\t%Lp\t%HT\t%l' ]]; then
        print -r -- $'0\t600\tRegular File\t1'
    else
        /usr/bin/stat -f "$format" -- "$target_path"
    fi
}
metal_llm_artifact_verification_begin cached 0
if metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a >/dev/null 2>&1; then
    fail 'wrong-owner receipt was accepted'
fi
functions[metal_llm_artifact_lstat]=$original_lstat

metal_llm_artifact_lstat() {
    local target_path=$1 format=$2
    if [[ "$target_path" == "$model_receipt_root" && "$format" == $'%u\t%Lp\t%HT\t%l' ]]; then
        print -r -- $'0\t700\tDirectory\t3'
    else
        /usr/bin/stat -f "$format" -- "$target_path"
    fi
}
metal_llm_artifact_verification_begin cached 0
if metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a >/dev/null 2>&1; then
    fail 'wrong-owner receipt parent was accepted'
fi
functions[metal_llm_artifact_lstat]=$original_lstat

/bin/chmod 755 "$verification_root"
metal_llm_artifact_verification_begin cached 0
if metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a >/dev/null 2>&1; then
    fail 'wrong-mode verification root was accepted'
fi
/bin/chmod 700 "$verification_root"

/bin/mv "$model_receipt_root" "$model_receipt_root.real"
/bin/ln -s "$model_receipt_root.real" "$model_receipt_root"
metal_llm_artifact_verification_begin cached 0
if metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a >/dev/null 2>&1; then
    fail 'symlink receipt parent was accepted'
fi
/bin/rm -f -- "$model_receipt_root"
/bin/mv "$model_receipt_root.real" "$model_receipt_root"

# A checksum failure never replaces the last safe receipt.
receipt_before_failure=$(metal_llm_sha256 "$receipt_path")
print -n -- 'omega' > "$artifact_dir/model-a.gguf"
metal_llm_artifact_verification_begin cached 0
if metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a >/dev/null 2>&1; then
    fail 'checksum failure was accepted before publication test'
fi
[[ "$(metal_llm_sha256 "$receipt_path")" == "$receipt_before_failure" ]] ||
  fail 'checksum failure published a replacement receipt'
refresh_alpha_receipt

# A dry-run miss against an absent verification tree must not create it.
saved_metal_llm_root=$METAL_LLM_ROOT
empty_receipt_root="$temporary_root/empty-receipt-root"
/bin/mkdir "$empty_receipt_root"
METAL_LLM_ROOT=$empty_receipt_root
: > "$artifact_hash_log"
metal_llm_artifact_verification_begin cached 1
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
metal_llm_artifact_verification_finalize 1
[[ ! -e "$empty_receipt_root/.lab" ]] || fail 'dry-run cache miss created receipt tree'
(( $(artifact_hash_count) == 1 )) || fail 'dry-run cache miss without tree did not hash'
METAL_LLM_ROOT=$saved_metal_llm_root

# Equivalent concurrent full refreshes leave one complete receipt and no temporary names.
: > "$artifact_hash_log"
(
    metal_llm_artifact_verification_begin full 0
    metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
) &
first_refresh_pid=$!
(
    metal_llm_artifact_verification_begin full 0
    metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
) &
second_refresh_pid=$!
wait "$first_refresh_pid"
wait "$second_refresh_pid"
jq empty "$receipt_path" || fail 'concurrent refresh left partial JSON'
[[ ! -e "$receipt_path.part" ]] || fail 'concurrent refresh left fixed .part receipt'
leftover_receipt_temps=("$model_receipt_root"/.model-a.json.*(N))
(( ${#leftover_receipt_temps} == 0 )) || fail 'concurrent refresh left unique temporary receipt'

# Two mutations during hashing consume the single retry and fail as unstable.
original_compute_sha256=${functions[metal_llm_artifact_compute_sha256]}
: > "$artifact_hash_log"
metal_llm_artifact_compute_sha256() {
    local target_path=$1 computed_sha
    print -r -- "$target_path" >> "$artifact_hash_log"
    computed_sha=$(metal_llm_sha256 "$target_path") || return 1
    if [[ "$(<"$target_path")" == alpha ]]; then
        print -n -- 'omega' > "$target_path"
    else
        print -n -- 'alpha' > "$target_path"
    fi
    print -- "$computed_sha"
}
metal_llm_artifact_verification_begin full 0
if metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a >/dev/null 2>&1; then
    fail 'repeated mutation during hashing was accepted'
fi
(( $(artifact_hash_count) == 2 )) || fail 'unstable hash did not perform exactly one retry'
functions[metal_llm_artifact_compute_sha256]=$original_compute_sha256
refresh_alpha_receipt

# Dry-run cache hits and misses leave the recursive receipt inventory unchanged.
before_inventory=$(inventory_tree "$fixture_root/.lab")
: > "$artifact_hash_log"
metal_llm_artifact_verification_begin cached 1
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
metal_llm_artifact_verification_finalize 1
after_inventory=$(inventory_tree "$fixture_root/.lab")
[[ "$before_inventory" == "$after_inventory" ]] || fail 'dry-run cache hit mutated receipt storage'
(( $(artifact_hash_count) == 0 )) || fail 'dry-run cache hit read artifact body'

rewrite_receipt '.artifact_sha256 = ("0" * 64)'
before_inventory=$(inventory_tree "$fixture_root/.lab")
: > "$artifact_hash_log"
metal_llm_artifact_verification_begin cached 1
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
metal_llm_artifact_verification_finalize 1
after_inventory=$(inventory_tree "$fixture_root/.lab")
[[ "$before_inventory" == "$after_inventory" ]] || fail 'dry-run cache miss mutated receipt storage'
(( $(artifact_hash_count) == 1 )) || fail 'dry-run cache miss did not hash artifact'
refresh_alpha_receipt

# Repeated references reuse an unchanged decision, but a changed fingerprint re-enters verification.
: > "$artifact_hash_log"
metal_llm_artifact_verification_begin full 0
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
(( $(artifact_hash_count) == 1 && METAL_LLM_ARTIFACT_FULL_HASHES == 1 )) ||
  fail 'unchanged repeated artifact duplicated work or counters'
/bin/cp "$artifact_dir/model-a.gguf" "$artifact_dir/model-a.gguf.replacement"
/bin/mv -f "$artifact_dir/model-a.gguf.replacement" "$artifact_dir/model-a.gguf"
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
(( $(artifact_hash_count) == 2 && METAL_LLM_ARTIFACT_FULL_HASHES == 2 )) ||
  fail 'changed repeated artifact reused stale memoized decision'

# Receipt-set construction is order-independent and identities retain caller order.
: > "$artifact_hash_log"
metal_llm_artifact_verification_begin full 0
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-b
metal_llm_artifact_verification_finalize 1
forward_set=$(jq -r '.receipt_set_sha256' <<< "$METAL_LLM_ARTIFACT_VERIFICATION_JSON")
jq -e 'map(.id) == ["model-a", "model-b"]' <<< "$METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES" >/dev/null ||
  fail 'verified artifact identities lost verification order'

metal_llm_artifact_verification_begin full 0
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-b
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
metal_llm_artifact_verification_finalize 1
reverse_set=$(jq -r '.receipt_set_sha256' <<< "$METAL_LLM_ARTIFACT_VERIFICATION_JSON")
[[ "$forward_set" == "$reverse_set" ]] || fail 'reversed traversal changed receipt-set digest'

# A single cached invocation reports mixed when one exact receipt hits and one stale receipt hashes.
model_b_receipt="$fixture_root/.lab/verification/artifacts/fixture-model/model-b.json"
rewrite_model_a_receipt_path=$receipt_path
receipt_path=$model_b_receipt
rewrite_receipt '.file.inode += "1"'
receipt_path=$rewrite_model_a_receipt_path
: > "$artifact_hash_log"
metal_llm_artifact_verification_begin cached 0
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-b
metal_llm_artifact_verification_finalize 1
jq -e '.effective_mode == "mixed" and .cache_hits == 1 and .cache_misses == 1 and
  .full_hashes == 1' <<< "$METAL_LLM_ARTIFACT_VERIFICATION_JSON" >/dev/null ||
  fail 'mixed cache/full decisions produced a bad summary'

# Both legacy and current model manifests drive configuration verification.
legacy_configuration='{"vision":{"enabled":false},"mtp":{"enabled":false}}'
metal_llm_artifact_verification_begin full 1
metal_llm_verify_configuration_artifacts "$manifest" fixture-model "$artifact_dir" "$legacy_configuration"
jq -e 'map(.id) == ["model-a", "model-b"]' <<< "$METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES" >/dev/null ||
  fail 'schema-v1 configuration selected wrong artifacts'
v2_manifest="$temporary_root/fixture-v2.json"
jq '.schema_version = 2' "$manifest" > "$v2_manifest"
v2_configuration='{"vision":{"enabled":false},"mtp":{"policy":"off"}}'
metal_llm_artifact_verification_begin full 1
metal_llm_verify_configuration_artifacts "$v2_manifest" fixture-model "$artifact_dir" "$v2_configuration"
jq -e 'map(.id) == ["model-a", "model-b"]' <<< "$METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES" >/dev/null ||
  fail 'schema-v2 configuration selected wrong artifacts'

# A completed partial is fully hashed, moved without overwrite, and bound to its final path.
/bin/rm -f -- "$artifact_dir/model-b.gguf"
print -n -- 'bravo!' > "$artifact_dir/model-b.gguf.part"
: > "$artifact_hash_log"
metal_llm_artifact_verification_begin full 0
metal_llm_install_verified_artifact "$manifest" fixture-model "$artifact_dir" model-b \
  "$artifact_dir/model-b.gguf.part"
(( $(artifact_hash_count) == 1 )) || fail 'installed partial was not fully hashed once'
[[ ! -e "$artifact_dir/model-b.gguf.part" && -f "$artifact_dir/model-b.gguf" ]] ||
  fail 'verified partial was not moved to the final path'
[[ "$(metal_llm_verified_artifact_path model-b)" == "${artifact_dir:A}/model-b.gguf" ]] ||
  fail 'installed artifact path is not the canonical final path'
jq -e --arg final "${artifact_dir:A}/model-b.gguf" '.canonical_path == $final' \
  "$fixture_root/.lab/verification/artifacts/fixture-model/model-b.json" >/dev/null ||
  fail 'installed artifact receipt names a partial path'

# Mode validation happens before any filesystem access; malformed fingerprints fail closed.
lstat_log="$temporary_root/lstat.log"
: > "$lstat_log"
metal_llm_artifact_lstat() {
    print -r -- "$1" >> "$lstat_log"
    /usr/bin/stat -f "$2" -- "$1"
}
if metal_llm_artifact_verification_begin off 0 >/dev/null 2>&1; then
    fail 'invalid artifact mode was accepted'
fi
if metal_llm_artifact_verification_begin cached maybe >/dev/null 2>&1; then
    fail 'invalid dry-run state was accepted'
fi
[[ ! -s "$lstat_log" ]] || fail 'session validation touched the filesystem'
functions[metal_llm_artifact_lstat]=$original_lstat

metal_llm_artifact_lstat() {
    local target_path=$1 format=$2
    if [[ "$format" == $'%d\t%i\t%z\t%FB\t%Fc\t%Fm' ]]; then
        print -r -- $'1\t2\t5\t3.1\t4.000000000\t5.000000000'
    else
        /usr/bin/stat -f "$format" -- "$target_path"
    fi
}
metal_llm_artifact_verification_begin full 1
if metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a >/dev/null 2>&1; then
    fail 'unsupported fingerprint precision was accepted'
fi
functions[metal_llm_artifact_lstat]=$original_lstat

/bin/ln -s "$artifact_dir/model-a.gguf" "$artifact_dir/model-a-link.gguf"
symlink_manifest="$temporary_root/symlink-manifest.json"
jq '(.artifacts[] | select(.id == "model-a")).filename = "model-a-link.gguf"' \
  "$manifest" > "$symlink_manifest"
metal_llm_artifact_verification_begin full 1
if metal_llm_verify_model_artifact "$symlink_manifest" fixture-model "$artifact_dir" model-a >/dev/null 2>&1; then
    fail 'symlink artifact was accepted'
fi

# Incomplete sets are dry-run-only, omit persistence JSON/digest, and report not-run when empty.
metal_llm_artifact_verification_begin cached 1
metal_llm_artifact_verification_finalize 0
[[ -z "${METAL_LLM_ARTIFACT_VERIFICATION_JSON:-}" &&
   -z "${METAL_LLM_ARTIFACT_RECEIPT_SET_SHA256:-}" ]] ||
  fail 'incomplete dry-run exported persistence provenance'
incomplete_summary=$(metal_llm_print_artifact_verification_summary)
[[ "$incomplete_summary" == 'artifact verification: requested=cached effective=not-run cache_hits=0 cache_misses=0 full_hashes=0' ]] ||
  fail 'bad incomplete dry-run summary'

metal_llm_artifact_verification_begin cached 0
if metal_llm_artifact_verification_finalize 0 >/dev/null 2>&1; then
    fail 'non-dry-run incomplete verification set was accepted'
fi

metal_llm_artifact_verification_begin cached 0
metal_llm_verify_model_artifact "$manifest" fixture-model "$artifact_dir" model-a
metal_llm_artifact_verification_finalize 1
summary_output=$(metal_llm_print_artifact_verification_summary)
[[ "$summary_output" == "artifact verification: requested=cached effective=cached cache_hits=1 cache_misses=0 full_hashes=0 receipt_set_sha256=$(jq -r '.receipt_set_sha256' <<< "$METAL_LLM_ARTIFACT_VERIFICATION_JSON")" ]] ||
  fail 'complete verifier summary did not match the public format'

print -- 'artifact verification checks: PASS'
