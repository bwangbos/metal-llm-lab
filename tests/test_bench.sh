#!/bin/zsh
set -euo pipefail

source_root=${0:A:h:h}
suite="$source_root/benchmarks/suites/qwen3.8-smoke.json"
real_jq=$(command -v jq)
real_shasum=$(command -v shasum)

fail() {
    print -u2 -- "$1"
    exit 1
}

assert_contains() {
    local haystack=$1
    local needle=$2
    [[ "$haystack" == *"$needle"* ]] || fail "missing expected output: $needle"
}

[[ -f "$suite" ]] || fail 'missing benchmarks/suites/qwen3.8-smoke.json'
jq -e '
    .schema_version == 1 and .id == "qwen3.8-smoke" and .default_mode == "local" and
    all(.cases[] | select(.mode == "local"); .kind == "llama-bench") and
    any(.cases[]; .mode == "local" and .kind == "llama-bench" and .prompt_tokens == 512) and
    any(.cases[]; .mode == "local" and .kind == "llama-bench" and .generated_tokens == 128) and
    all(.cases[] | select(.mode == "endpoint"); .kind == "api" or .kind == "vision") and
    any(.cases[]; .mode == "endpoint" and .kind == "api" and .temperature == 0 and .seed == 1234) and
    any(.cases[]; .mode == "endpoint" and .kind == "vision" and .optional == true and (.fixture | endswith(".png")))
' "$suite" >/dev/null
vision_fixture=$(jq -r 'first(.cases[] | select(.kind == "vision") | .fixture)' "$suite")
[[ -f "$source_root/$vision_fixture" ]] || fail "missing optional vision fixture: $vision_fixture"
file "$source_root/$vision_fixture" | grep -Fq 'PNG image data' || fail 'vision fixture is not PNG'
if strings "$source_root/$vision_fixture" | grep -Eiq 'blue|orange|circle|square|left|right'; then
    fail 'vision fixture contains its expected answer as visible text metadata'
fi

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-bench.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT
fixture_root="$temporary_root/repository"
fake_bin="$temporary_root/bin"
results_dir="$temporary_root/results"
mkdir -p "$fixture_root"/{bin,lib,schemas,results/raw,benchmarks/suites,benchmarks/fixtures,manifests/models,manifests/runtimes,manifests/hardware,.lab/artifacts/fixture-model,.lab/runtimes/fixture-runtime/build-metal/bin} \
    "$fake_bin" "$results_dir"
cp "$source_root/bin/metal-llm" "$fixture_root/bin/metal-llm"
cp "$source_root/lib"/*.zsh "$fixture_root/lib/"
cp "$source_root/schemas/result.schema.json" "$fixture_root/schemas/result.schema.json"
chmod +x "$fixture_root/bin/metal-llm"
cp "$suite" "$fixture_root/benchmarks/suites/qwen3.8-smoke.json"
cp "$source_root/$vision_fixture" "$fixture_root/$vision_fixture"

print -n -- 'fixture-model' > "$fixture_root/.lab/artifacts/fixture-model/model.gguf"
model_bytes=$(wc -c < "$fixture_root/.lab/artifacts/fixture-model/model.gguf" | tr -d ' ')
model_sha=$($real_shasum -a 256 "$fixture_root/.lab/artifacts/fixture-model/model.gguf" | awk '{print $1}')

$real_jq -n --arg sha "$model_sha" --argjson bytes "$model_bytes" '{
  schema_version: 1,
  id: "fixture-model",
  name: "Fixture Model",
  artifacts: [{id: "model", kind: "model", filename: "model.gguf", url: "https://example.invalid/model", bytes: $bytes, sha256: $sha, license_url: "https://example.invalid/license"}],
  text_model: {artifact_ids: ["model"], total_bytes: $bytes},
  profiles: [{
    id: "fast", runtime_id: "fixture-runtime", model_artifact_id: "model", context: 32768,
    vision: {enabled: false, projector_artifact_id: null, image_min_tokens: null},
    mtp: {enabled: false, artifact_id: null, spec_type: null, draft_n_max: null, gpu_layers: null},
    metal: {gpu_layers: "all", fit: false, flash_attention: true, load_mode: "mmap", lazy_mmap: true}
  }]
}' > "$fixture_root/manifests/models/fixture-model.json"

$real_jq -n '{
  schema_version: 1, id: "fixture-runtime", repository: "https://example.invalid/runtime.git",
  base_revision: "1111111111111111111111111111111111111111", patches: [],
  tested_revision: "2222222222222222222222222222222222222222",
  tested_tree_sha: "3333333333333333333333333333333333333333",
  build: {generator: "Ninja", build_type: "Release", architecture: "arm64", cmake_options: {}, targets: ["llama-bench"]}
}' > "$fixture_root/manifests/runtimes/fixture-runtime.json"

$real_jq -n '{
  schema_version: 1, id: "fixture-hardware", chip: "Fixture Chip", architecture: "arm64",
  gpu_cores: 1, unified_memory_bytes: 1024, recommended_profile: "fast",
  tested: {date: "2026-09-03", operating_system: "macOS"}
}' > "$fixture_root/manifests/hardware/fixture-hardware.json"

fake_bench="$fixture_root/.lab/runtimes/fixture-runtime/build-metal/bin/llama-bench"
print -r -- '#!/bin/zsh' > "$fake_bench"
print -r -- 'print -r -- "$*" >> "$FAKE_BENCH_LOG"' >> "$fake_bench"
print -r -- 'if [[ "$*" == *"-p 512"* ]]; then' >> "$fake_bench"
print -r -- '  print -r -- '\''[{"n_prompt":512,"n_gen":0,"avg_ts":987.25}]'\''' >> "$fake_bench"
print -r -- 'else' >> "$fake_bench"
print -r -- '  print -r -- '\''[{"n_prompt":0,"n_gen":128,"avg_ts":44.5}]'\''' >> "$fake_bench"
print -r -- 'fi' >> "$fake_bench"
chmod +x "$fake_bench"
bench_sha=$($real_shasum -a 256 "$fake_bench" | awk '{print $1}')
$real_jq -n --arg sha "$bench_sha" '{
  schema_version: 1, runtime_id: "fixture-runtime",
  runtime_manifest_sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  source_tree_sha: "3333333333333333333333333333333333333333",
  tested_tree_sha: "3333333333333333333333333333333333333333",
  binaries: {"llama-bench": {sha256: $sha}}
}' > "$fixture_root/.lab/runtimes/fixture-runtime/build-metal/build-receipt.json"

print -r -- '#!/bin/zsh' > "$fake_bin/uname"
print -r -- '[[ "${1:-}" == -s ]] && { print Darwin; exit; }' >> "$fake_bin/uname"
print -r -- '[[ "${1:-}" == -m ]] && { print arm64; exit; }' >> "$fake_bin/uname"
print -r -- 'print Darwin' >> "$fake_bin/uname"
chmod +x "$fake_bin/uname"
print -r -- '#!/bin/zsh' > "$fake_bin/curl"
print -r -- 'print -r -- "$*" >> "${FAKE_CURL_LOG:-/dev/null}"' >> "$fake_bin/curl"
print -r -- 'if [[ "$*" == *"/health"* ]]; then' >> "$fake_bin/curl"
print -r -- '  [[ "${FAKE_SERVER_ACTIVE:-0}" == 1 ]] && { print '\''{"status":"ok"}'\''; exit 0; }' >> "$fake_bin/curl"
print -r -- '  exit 22' >> "$fake_bin/curl"
print -r -- 'fi' >> "$fake_bin/curl"
print -r -- 'if [[ "${FAKE_OMIT_USAGE:-0}" == 1 ]]; then' >> "$fake_bin/curl"
print -r -- '  print '\''{"choices":[{"message":{"content":"fixture response"}}]}'\''' >> "$fake_bin/curl"
print -r -- 'else' >> "$fake_bin/curl"
print -r -- '  print '\''{"choices":[{"message":{"content":"fixture response"}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}'\''' >> "$fake_bin/curl"
print -r -- 'fi' >> "$fake_bin/curl"
chmod +x "$fake_bin/curl"

fixture_cli="$fixture_root/bin/metal-llm"
common_environment=(
  PATH="$fake_bin:$PATH"
  METAL_LLM_HARDWARE_ID=fixture-hardware
  METAL_LLM_RESULTS_DIR="$results_dir"
  METAL_LLM_REPOSITORY_REVISION=4444444444444444444444444444444444444444
  METAL_LLM_NOW=2026-09-03T12:34:56Z
  FAKE_BENCH_LOG="$temporary_root/bench.log"
  FAKE_CURL_LOG="$temporary_root/curl.log"
)

dry_output=$(env "${common_environment[@]}" "$fixture_cli" bench fixture-model --suite qwen3.8-smoke --dry-run)
assert_contains "$dry_output" 'llama-bench'
assert_contains "$dry_output" '-p 512 -n 0'
assert_contains "$dry_output" '-p 0 -n 128'
[[ "$dry_output" != *'HTTP POST'* ]] || fail 'local mode included endpoint cases'
dry_result_files=("$results_dir"/*(N))
(( ${#dry_result_files} == 0 )) || fail 'bench --dry-run wrote a result file'

run_output=$(env "${common_environment[@]}" "$fixture_cli" bench fixture-model --suite qwen3.8-smoke)
assert_contains "$run_output" 'wrote benchmark result:'
result_files=("$results_dir"/*.json(N))
(( ${#result_files} == 1 )) || fail "expected one result, found ${#result_files}"
result_file=$result_files[1]
jq -e '
  .model_id == "fixture-model" and .suite_id == "qwen3.8-smoke" and .benchmark_mode == "local" and
  (.runs | length == 2) and
  (.runs[0].prompt_tokens_per_second == 987.25) and
  (.runs[1].generation_tokens_per_second == 44.5)
' "$result_file" >/dev/null
partial_files=("$results_dir"/*.part*(N))
(( ${#partial_files} == 0 )) || fail 'bench left a partial result behind'
assert_contains "$(<"$temporary_root/bench.log")" '-m'

if busy_output=$(env "${common_environment[@]}" FAKE_SERVER_ACTIVE=1 "$fixture_cli" bench fixture-model --suite qwen3.8-smoke 2>&1); then
    fail 'bench ran beside an active lab server'
fi
assert_contains "$busy_output" 'configured port is owned by a running lab server'

if injection_output=$(env "${common_environment[@]}" "$fixture_cli" bench 'fixture-model;touch-pwned' --suite qwen3.8-smoke 2>&1); then
    fail 'bench accepted an unsafe model ID'
fi
assert_contains "$injection_output" 'invalid model id'
[[ ! -e "$temporary_root/pwned" ]] || fail 'bench evaluated a model argument'

endpoint_results="$temporary_root/endpoint-results"
mkdir -p "$endpoint_results"
# Endpoint-only cases use the already loaded server and must not depend on a
# standalone llama-bench executable being present locally.
rm -f -- "$fake_bench"
if inactive_output=$(env "${common_environment[@]}" METAL_LLM_RESULTS_DIR="$endpoint_results" \
    "$fixture_cli" bench fixture-model --suite qwen3.8-smoke --mode endpoint 2>&1); then
    fail 'endpoint mode ran without an active endpoint'
fi
assert_contains "$inactive_output" 'endpoint mode requires a running endpoint'

endpoint_dry=$(env "${common_environment[@]}" FAKE_SERVER_ACTIVE=1 METAL_LLM_INCLUDE_OPTIONAL=1 \
    METAL_LLM_RESULTS_DIR="$endpoint_results" "$fixture_cli" bench fixture-model \
    --suite qwen3.8-smoke --mode endpoint --dry-run)
assert_contains "$endpoint_dry" 'HTTP POST'
[[ "$endpoint_dry" != *'llama-bench'* ]] || fail 'endpoint mode included local cases'

env "${common_environment[@]}" FAKE_SERVER_ACTIVE=1 FAKE_OMIT_USAGE=1 METAL_LLM_INCLUDE_OPTIONAL=1 \
    METAL_LLM_RESULTS_DIR="$endpoint_results" "$fixture_cli" bench fixture-model \
    --suite qwen3.8-smoke --mode endpoint >/dev/null
endpoint_files=("$endpoint_results"/*.json(N))
(( ${#endpoint_files} == 1 )) || fail "expected one endpoint result, found ${#endpoint_files}"
jq -e '
  .benchmark_mode == "endpoint" and (.runs | length == 2) and
  all(.runs[];
    .effective_prompt_tokens == null and .generated_tokens == null and
    .prompt_tokens_per_second == null and .generation_tokens_per_second == null)
' "$endpoint_files[1]" >/dev/null
assert_contains "$(<"$temporary_root/curl.log")" 'data:image/png;base64,'
cp "$endpoint_files[1]" "$fixture_root/results/raw/endpoint.json"
endpoint_report=$(env "${common_environment[@]}" "$fixture_cli" report)
assert_contains "$endpoint_report" '| deterministic-api-smoke | suite-run | n/a | n/a | n/a | n/a |'
assert_contains "$endpoint_report" '| vision-spatial-smoke | suite-run | n/a | n/a | n/a | n/a |'

if mode_output=$(env "${common_environment[@]}" "$fixture_cli" bench fixture-model \
    --suite qwen3.8-smoke --mode mixed 2>&1); then
    fail 'bench accepted an unknown suite mode'
fi
assert_contains "$mode_output" 'mode not found: mixed'

print -- 'bench checks: PASS'
