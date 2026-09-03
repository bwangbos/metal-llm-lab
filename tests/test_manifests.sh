#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
runtime_schema="$root/schemas/runtime.schema.json"
model_schema="$root/schemas/model.schema.json"
hardware_schema="$root/schemas/hardware.schema.json"

for manifest_file in "$runtime_schema" "$model_schema" "$hardware_schema"; do
    [[ -f "$manifest_file" ]] || { print -u2 -- "missing ${manifest_file#$root/}"; exit 1; }
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
    (.["$defs"].artifact.required) as $artifact_required |
    (.["$defs"].profile.required) as $profile_required |
    all(["id", "url", "bytes", "sha256", "license_url"][]; $artifact_required | index(.) != null) and
    all(["id", "runtime_id", "context", "vision", "mtp"][]; $profile_required | index(.) != null)
' "$model_schema" >/dev/null
jq -e '
    .required as $required |
    all(["id", "chip", "unified_memory_bytes", "tested"][]; $required | index(.) != null)
' "$hardware_schema" >/dev/null

runtime_files=("$root"/manifests/runtimes/*.json(N))
model_files=("$root"/manifests/models/*.json(N))
hardware_files=("$root"/manifests/hardware/*.json(N))
(( ${#runtime_files} > 0 )) || { print -u2 -- "missing runtime manifests"; exit 1; }
(( ${#model_files} > 0 )) || { print -u2 -- "missing model manifests"; exit 1; }
(( ${#hardware_files} > 0 )) || { print -u2 -- "missing hardware manifests"; exit 1; }

for manifest_file in "${runtime_files[@]}"; do
    jq -e '
        .schema_version == 1 and
        ([.id, .repository, .base_revision, .tested_revision, .tested_tree_sha] | all(type == "string" and length > 0)) and
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
    print -u2 -- "model schema accepted a 63-character checksum fixture"
    exit 1
fi

for manifest_file in "${model_files[@]}"; do
    jq -e --arg sha_pattern "$sha_pattern" '
        .schema_version == 1 and
        (.id | type == "string" and length > 0) and
        (.artifacts | type == "array" and length > 0 and
            all(
                ([.id, .url, .license_url] | all(type == "string" and length > 0)) and
                (.bytes | type == "number" and . > 0 and floor == .) and
                (.sha256 | type == "string" and test($sha_pattern))
            )) and
        ([.artifacts[].id] | length == (unique | length)) and
        (.profiles | type == "array" and length > 0 and
            all(
                ([.id, .runtime_id, .model_artifact_id] | all(type == "string" and length > 0)) and
                (.context | type == "number" and . > 0 and floor == .) and
                (.vision | type == "object" and (.enabled | type == "boolean")) and
                (.mtp | type == "object" and (.enabled | type == "boolean"))
            )) and
        ([.profiles[].id] | length == (unique | length))
    ' "$manifest_file" >/dev/null

    jq -e '
        [.artifacts[].id] as $artifacts |
        all(.profiles[]; . as $profile |
            ($artifacts | index($profile.model_artifact_id)) != null and
            (if $profile.vision.enabled then ($artifacts | index($profile.vision.projector_artifact_id)) != null else true end) and
            (if $profile.mtp.enabled then ($artifacts | index($profile.mtp.artifact_id)) != null else true end)
        )
    ' "$manifest_file" >/dev/null

    jq -e '
        .text_model as $text |
        [.artifacts[] | select(.kind == "model") | .id] as $model_ids |
        ($text.artifact_ids | length > 0) and
        (($text.artifact_ids - $model_ids) | length == 0) and
        ([.artifacts[] | . as $artifact | select($text.artifact_ids | index($artifact.id)) | .bytes] | add) == $text.total_bytes
    ' "$manifest_file" >/dev/null
done

for manifest_file in "${hardware_files[@]}"; do
    jq -e '
        .schema_version == 1 and
        ([.id, .chip, .recommended_profile] | all(type == "string" and length > 0)) and
        (.unified_memory_bytes | type == "number" and . > 0 and floor == .) and
        (.tested | type == "object")
    ' "$manifest_file" >/dev/null
done

jq -s -e '
    (.[0] | map(.id)) as $runtime_ids |
    all(.[1][] .profiles[]; . as $profile | ($runtime_ids | index($profile.runtime_id)) != null)
' <(jq -s '.' "${runtime_files[@]}") <(jq -s '.' "${model_files[@]}") >/dev/null

jq -s -e '
    ([.[0][] .profiles[].id] | unique) as $profile_ids |
    all(.[1][]; . as $hardware | ($profile_ids | index($hardware.recommended_profile)) != null)
' <(jq -s '.' "${model_files[@]}") <(jq -s '.' "${hardware_files[@]}") >/dev/null

print -- "manifest checks: PASS"
