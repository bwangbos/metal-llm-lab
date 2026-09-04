#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
METAL_LLM_ROOT=$root
export METAL_LLM_ROOT
model_manifest="$root/manifests/models/qwen3.8-flash-next.json"

source "$root/lib/common.zsh"
source "$root/lib/profile.zsh"

fail() {
    print -u2 -- "$1"
    exit 1
}

resolve() {
    metal_llm_resolve_profile "$model_manifest" "$@"
}

assert_rejected() {
    local description=$1
    shift
    local output
    if output=$(resolve "$@" 2>&1); then
        fail "$description was accepted"
    fi
}

resolve '' '' '' ''
jq -e '
  .profile_id == "auto" and .runtime_alias == "tuned" and
  .runtime_id == "llama-cpp-qwen38-hybrid" and
  .context == 262144 and .vision.enabled == true and
  .vision.projector_artifact_id == "qwen38-projector-f16" and
  .vision.image_min_tokens == 1024 and
  .mtp.policy == "dynamic" and .mtp.artifact_id == "qwen38-mtp-q8-0" and
  .mtp.spec_type == "draft-mtp" and .mtp.draft_n_max == 2 and
  .mtp.gpu_layers == "all" and .mtp.threshold == 32768 and
  .model_artifact_id == "qwen38-text-00001" and
  .metal == {
    gpu_layers: "all", fit: false, flash_attention: true,
    load_mode: "mmap", lazy_mmap: true
  }
' <<< "$METAL_LLM_EFFECTIVE_PROFILE" >/dev/null

resolve fast off '' '' ''
jq -e '
  .profile_id == "fast" and .runtime_alias == "tuned" and
  .context == 32768 and .vision == {
    enabled: false, projector_artifact_id: null, image_min_tokens: null
  } and
  .mtp.policy == "on" and .mtp.threshold == null
' <<< "$METAL_LLM_EFFECTIVE_PROFILE" >/dev/null

resolve custom on tuned off 65536
jq -e '
  .profile_id == "custom" and .runtime_alias == "tuned" and
  .context == 65536 and .vision.enabled == true and
  .mtp == {
    policy: "off", artifact_id: null, spec_type: null,
    draft_n_max: null, gpu_layers: null, threshold: null
  }
' <<< "$METAL_LLM_EFFECTIVE_PROFILE" >/dev/null

assert_rejected 'custom profile without runtime' custom on '' off 65536
assert_rejected 'custom profile without MTP policy' custom on tuned '' 65536
assert_rejected 'custom profile without context' custom on tuned off ''

assert_rejected 'named profile runtime override' fast on tuned '' ''
assert_rejected 'named profile MTP override' fast on '' on ''
assert_rejected 'named profile context override' fast on '' '' 32768

assert_rejected 'upstream runtime with MTP on' custom on upstream on 32768
assert_rejected 'upstream runtime with dynamic MTP' custom on upstream dynamic 32768
assert_rejected 'zero context' custom on tuned off 0
assert_rejected 'context above model maximum' custom on tuned off 262145
assert_rejected 'invalid vision value' auto sometimes '' '' ''
assert_rejected 'removed vision profile' vision on '' '' ''

if obsolete_output=$(METAL_LLM_CONTEXT=65536 resolve '' '' '' '' 2>&1); then
    fail 'obsolete METAL_LLM_CONTEXT was accepted'
fi

source "$root/lib/runtime-state.zsh"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-profiles.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT
fixture_root="$temporary_root/repository"
artifact_dir="$fixture_root/artifacts"
fixture_manifest="$fixture_root/manifests/models/fixture-model.json"
missing_runtime_manifest="$fixture_root/manifests/models/missing-runtime-model.json"
mkdir -p "$artifact_dir" "$fixture_root/manifests/models" "$fixture_root/manifests/runtimes"
for artifact_file in model.gguf projector.gguf mtp.gguf; do
    print -n -- "$artifact_file fixture" > "$artifact_dir/$artifact_file"
done
model_sha=$(metal_llm_sha256 "$artifact_dir/model.gguf")
projector_sha=$(metal_llm_sha256 "$artifact_dir/projector.gguf")
mtp_sha=$(metal_llm_sha256 "$artifact_dir/mtp.gguf")
jq -n \
  --arg model_sha "$model_sha" \
  --arg projector_sha "$projector_sha" \
  --arg mtp_sha "$mtp_sha" \
  --argjson model_bytes "$(metal_llm_file_size "$artifact_dir/model.gguf")" \
  --argjson projector_bytes "$(metal_llm_file_size "$artifact_dir/projector.gguf")" \
  --argjson mtp_bytes "$(metal_llm_file_size "$artifact_dir/mtp.gguf")" '
  {
    schema_version: 2,
    id: "fixture-model",
    name: "Fixture Model",
    default_profile: "auto",
    max_context: 256,
    runtime_aliases: {tuned: "fixture-runtime", upstream: "fixture-upstream"},
    artifacts: [
      {id: "model", kind: "model", filename: "model.gguf", url: "https://example.invalid/model",
       bytes: $model_bytes, sha256: $model_sha, license_url: "https://example.invalid/license"},
      {id: "projector", kind: "projector", filename: "projector.gguf", url: "https://example.invalid/projector",
       bytes: $projector_bytes, sha256: $projector_sha, license_url: "https://example.invalid/license"},
      {id: "mtp", kind: "mtp", filename: "mtp.gguf", url: "https://example.invalid/mtp",
       bytes: $mtp_bytes, sha256: $mtp_sha, license_url: "https://example.invalid/license"}
    ],
    text_model: {entry_artifact_id: "model", artifact_ids: ["model"], total_bytes: $model_bytes},
    capabilities: {
      vision: {default_enabled: true, projector_artifact_id: "projector", image_min_tokens: 16},
      mtp: {artifact_id: "mtp", spec_type: "draft-mtp", draft_n_max: 2,
        gpu_layers: "all", dynamic_threshold: 128}
    },
    metal: {gpu_layers: "all", fit: false, flash_attention: true, load_mode: "mmap", lazy_mmap: true},
    profiles: [
      {id: "auto", runtime: "tuned", context: 256, mtp_policy: "dynamic", status: "supported"}
    ]
  }
' > "$fixture_manifest"

jq '.id = "fixture-runtime"' \
  "$root/manifests/runtimes/llama-cpp-upstream-stable.json" > \
  "$fixture_root/manifests/runtimes/fixture-runtime.json"
jq '.id = "fixture-upstream"' \
  "$root/manifests/runtimes/llama-cpp-upstream-stable.json" > \
  "$fixture_root/manifests/runtimes/fixture-upstream.json"
METAL_LLM_ROOT=$fixture_root

jq '.id = "missing-runtime-model" | .runtime_aliases.tuned = "missing-runtime"' \
  "$fixture_manifest" > "$missing_runtime_manifest"
unset METAL_LLM_EFFECTIVE_PROFILE
if metal_llm_resolve_profile "$missing_runtime_manifest" \
    custom off tuned off 128 2> "$temporary_root/missing-runtime.err"; then
    fail 'resolver accepted an alias targeting a missing runtime manifest'
fi
[[ -z "${METAL_LLM_EFFECTIVE_PROFILE:-}" ]] ||
  fail 'failed runtime-reference resolution published normalized JSON'

if raw_v2_output=$(metal_llm_profile_artifact_identities \
    "$fixture_manifest" "$artifact_dir" auto 2>&1); then
    fail 'v2 artifact identity accepted a raw profile ID'
fi

metal_llm_resolve_profile "$fixture_manifest" custom off tuned off 128
metal_llm_profile_artifact_identities "$fixture_manifest" "$artifact_dir" \
  "$METAL_LLM_EFFECTIVE_PROFILE"
jq -e 'map(.id) == ["model"]' <<< "$METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES" >/dev/null

metal_llm_resolve_profile "$fixture_manifest" custom on tuned on 128
metal_llm_profile_artifact_identities "$fixture_manifest" "$artifact_dir" \
  "$METAL_LLM_EFFECTIVE_PROFILE"
jq -e 'map(.id) == ["model", "projector", "mtp"]' \
  <<< "$METAL_LLM_VERIFIED_ARTIFACT_IDENTITIES" >/dev/null

METAL_LLM_ROOT=$root

print -- 'profile checks: PASS'
