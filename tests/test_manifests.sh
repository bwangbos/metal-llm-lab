#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
METAL_LLM_ROOT=$root
export METAL_LLM_ROOT
runtime_schema="$root/schemas/runtime.schema.json"
model_schema="$root/schemas/model.schema.json"
hardware_schema="$root/schemas/hardware.schema.json"

source "$root/lib/common.zsh"
source "$root/lib/setup.zsh"

fail() {
    print -u2 -- "$1"
    exit 1
}

for manifest_file in "$runtime_schema" "$model_schema" "$hardware_schema"; do
    [[ -f "$manifest_file" ]] || fail "missing ${manifest_file#$root/}"
    jq empty "$manifest_file"
done

jq -e '
    .required as $required |
    (.["$defs"].build.required) as $build_required |
    all(["id", "repository", "base_revision", "patches", "build"][]; $required | index(.) != null) and
    (.properties.build["$ref"] == "#/$defs/build") and
    ($build_required | index("generator") != null) and
    ($build_required | index("targets") != null)
' "$runtime_schema" >/dev/null

jq -e '
    . as $schema |
    $schema.required as $required |
    $schema["$defs"].artifact.required as $artifact_required |
    ($schema.properties.schema_version.const == 2) and
    all([
      "schema_version", "id", "name", "artifacts", "default_profile", "max_context",
      "runtime_aliases", "text_model", "capabilities", "metal", "profiles"
    ][]; $required | index(.) != null) and
    ($schema.properties.runtime_aliases.additionalProperties == false) and
    ($schema.properties.runtime_aliases.required | sort) == (["tuned", "upstream"] | sort) and
    all($artifact_required[]; . as $field |
      ["id", "kind", "filename", "url", "bytes", "sha256", "license_url"] | index($field)) and
    ($schema["$defs"].profile.required | sort) ==
      (["id", "runtime", "context", "mtp_policy", "status"] | sort) and
    ($schema["$defs"].profile.properties.runtime.enum | sort) == (["tuned", "upstream"] | sort) and
    ($schema["$defs"].profile.properties.mtp_policy.enum | sort) == (["dynamic", "off", "on"] | sort) and
    ($schema["$defs"].profile.properties.status.enum | sort) ==
      (["pending-acceptance", "recommended", "reference", "supported"] | sort)
' "$model_schema" >/dev/null

jq -e '
    . as $schema |
    $schema.required as $required |
    ($schema.properties.schema_version.const == 2) and
    all(["id", "chip", "architecture", "gpu_cores", "unified_memory_bytes", "tested"][];
      $required | index(.) != null) and
    ($required | index("recommended_profile")) == null and
    ($schema.properties | has("recommended_profile") | not)
' "$hardware_schema" >/dev/null

runtime_files=("$root"/manifests/runtimes/*.json(N))
model_files=("$root"/manifests/models/*.json(N))
hardware_files=("$root"/manifests/hardware/*.json(N))
(( ${#runtime_files} > 0 )) || fail 'missing runtime manifests'
(( ${#model_files} > 0 )) || fail 'missing model manifests'
(( ${#hardware_files} > 0 )) || fail 'missing hardware manifests'

for manifest_file in "${runtime_files[@]}"; do
    if [[ "$(jq -r '.runtime_type // empty' "$manifest_file")" == mtplx ]]; then
        metal_llm_validate_runtime_manifest "$manifest_file" mtplx-2.11.2 || fail 'invalid MTPLX runtime'
        continue
    fi
    jq -e '
        .schema_version == 1 and
        ([.id, .repository, .base_revision, .tested_revision, .tested_tree_sha] |
          all(type == "string" and length > 0)) and
        (.base_revision | test("^[0-9a-f]{40}$")) and
        (.tested_revision | test("^[0-9a-f]{40}$")) and
        (.tested_tree_sha | test("^[0-9a-f]{40}$")) and
        (.patches | type == "array") and
        (.tested_revision == (if (.patches | length) == 0 then .base_revision else .patches[-1].revision end)) and
        (.build.generator | type == "string" and length > 0) and
        (.build.targets | type == "array" and length > 0 and all(type == "string" and length > 0))
    ' "$manifest_file" >/dev/null
done

sha_pattern=$(jq -er '.["$defs"].artifact.properties.sha256.pattern' "$model_schema")
if jq -en --arg re "$sha_pattern" --arg sha "$(printf 'a%.0s' {1..63})" '$sha | test($re)' >/dev/null; then
    fail 'model schema accepted a 63-character checksum fixture'
fi

expected_text_artifacts=$(jq -cn '[range(1; 34) | "qwen38-text-" + (tostring | if length < 5 then "0" * (5 - length) + . else . end)]')

for manifest_file in "${model_files[@]}"; do
    manifest_id=$(jq -er '.id' "$manifest_file")
    metal_llm_validate_model_manifest "$manifest_file" "$manifest_id" ||
      fail "invalid model manifest: $manifest_file"

    [[ "$manifest_id" != qwen3.8-flash-next-mtplx ]] || continue

    jq -e --arg sha_pattern "$sha_pattern" --argjson expected_text_artifacts "$expected_text_artifacts" '
        .schema_version == 2 and
        .default_profile == "auto" and
        .max_context == 262144 and
        .runtime_aliases == {
          tuned: "llama-cpp-qwen38-hybrid",
          upstream: "llama-cpp-upstream-stable"
        } and
        (.artifacts | type == "array" and length == 35 and all(
          ([.id, .url, .license_url] | all(type == "string" and length > 0)) and
          (.bytes | type == "number" and . > 0 and floor == .) and
          (.sha256 | type == "string" and test($sha_pattern))
        )) and
        ([.artifacts[].id] | length == (unique | length)) and
        .text_model.entry_artifact_id == "qwen38-text-00001" and
        .text_model.artifact_ids == $expected_text_artifacts and
        .text_model.total_bytes == 94525394976 and
        .capabilities == {
          vision: {
            default_enabled: true,
            projector_artifact_id: "qwen38-projector-f16",
            image_min_tokens: 1024
          },
          mtp: {
            artifact_id: "qwen38-mtp-q8-0",
            spec_type: "draft-mtp",
            draft_n_max: 2,
            gpu_layers: "all",
            dynamic_threshold: 32768
          }
        } and
        .metal == {
          gpu_layers: "all", fit: false, flash_attention: true,
          load_mode: "mmap", lazy_mmap: true
        } and
        .profiles == [
          {id: "fast", runtime: "tuned", context: 32768, mtp_policy: "on", status: "supported"},
          {id: "long", runtime: "tuned", context: 262144, mtp_policy: "off", status: "supported"},
          {id: "auto", runtime: "tuned", context: 262144, mtp_policy: "dynamic", status: "recommended"},
          {id: "stable", runtime: "upstream", context: 32768, mtp_policy: "off", status: "reference"}
        ] and
        ([.profiles[].id] | length == (unique | length))
    ' "$manifest_file" >/dev/null

    jq -e '
        . as $manifest |
        [.artifacts[].id] as $artifacts |
        ([.artifacts[] | select(.kind == "model") | .id]) as $model_ids |
        ($artifacts | index($manifest.text_model.entry_artifact_id)) != null and
        (($manifest.text_model.artifact_ids - $model_ids) | length == 0) and
        ([$manifest.artifacts[] as $artifact |
          select($manifest.text_model.artifact_ids | index($artifact.id)) | $artifact.bytes] | add) ==
          $manifest.text_model.total_bytes and
        ($artifacts | index($manifest.capabilities.vision.projector_artifact_id)) != null and
        ($artifacts | index($manifest.capabilities.mtp.artifact_id)) != null and
        any($manifest.profiles[]; .id == $manifest.default_profile)
    ' "$manifest_file" >/dev/null
done

for manifest_file in "${hardware_files[@]}"; do
    jq -e '
        .schema_version == 2 and
        (has("recommended_profile") | not) and
        ([.id, .chip] | all(type == "string" and length > 0)) and
        (.unified_memory_bytes | type == "number" and . > 0 and floor == .) and
        (.tested | type == "object")
    ' "$manifest_file" >/dev/null
done

jq -s -e '
    (.[0] | map(.id)) as $runtime_ids |
    all(.[1][] | (.runtime_aliases[]? // .runtime_id); . as $runtime_id | ($runtime_ids | index($runtime_id)) != null)
' <(jq -s '.' "${runtime_files[@]}") <(jq -s '.' "${model_files[@]}") >/dev/null

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-manifests.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT
real_model="$root/manifests/models/qwen3.8-flash-next.json"
model_id=$(jq -er '.id' "$real_model")

assert_invalid_model_change() {
    local description=$1
    local filter=$2
    local fixture="$temporary_root/invalid.json"
    jq "$filter" "$real_model" > "$fixture"
    if metal_llm_validate_model_manifest "$fixture" "$model_id"; then
        fail "$description was accepted"
    fi
}

assert_invalid_model_change 'duplicate profile ID' '.profiles += [.profiles[0]]'
assert_invalid_model_change 'default absent from profiles' '.default_profile = "missing"'
assert_invalid_model_change 'unknown runtime alias' '.profiles[0].runtime = "unknown"'
assert_invalid_model_change 'missing entry artifact reference' '.text_model.entry_artifact_id = "missing"'
assert_invalid_model_change 'missing projector artifact reference' '.capabilities.vision.projector_artifact_id = "missing"'
assert_invalid_model_change 'missing MTP artifact reference' '.capabilities.mtp.artifact_id = "missing"'
assert_invalid_model_change 'upstream MTP-on combination' '.profiles[0].runtime = "upstream"'
assert_invalid_model_change 'tuned alias referencing unknown runtime' '.runtime_aliases.tuned = "missing-runtime"'

print -- 'manifest checks: PASS'
