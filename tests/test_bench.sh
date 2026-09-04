#!/bin/zsh
set -euo pipefail
unsetopt bg_nice

source_root=${0:A:h:h}
suite="$source_root/benchmarks/suites/qwen3.8-smoke.json"
real_jq=$(command -v jq)
real_shasum=$(command -v shasum)
real_git=$(command -v git)

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
    (has("default_profile") | not) and
    all(.cases[] | select(.mode == "local"); .kind == "llama-bench") and
    any(.cases[]; .mode == "local" and .kind == "llama-bench" and .prompt_tokens == 512) and
    any(.cases[]; .mode == "local" and .kind == "llama-bench" and .generated_tokens == 128) and
    all(.cases[] | select(.mode == "endpoint"); .kind == "api" or .kind == "vision") and
    any(.cases[]; .mode == "endpoint" and .kind == "api" and .temperature == 0 and .seed == 1234) and
    any(.cases[]; .mode == "endpoint" and .kind == "vision" and .optional == true and
      .stream == true and (.fixture | endswith(".png")))
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
managed_tmp="$temporary_root/managed-tmp"
mkdir -p "$fixture_root"/{bin,lib,schemas,results/raw,benchmarks/suites,benchmarks/fixtures,manifests/models,manifests/runtimes,manifests/hardware,.lab/artifacts/fixture-model,.lab/runtimes/fixture-runtime/build-metal/bin,.lab/runtimes/fixture-runtime/source} \
    "$fake_bin" "$results_dir" "$managed_tmp"
cp "$source_root/bin/metal-llm" "$fixture_root/bin/metal-llm"
cp "$source_root/lib"/*.zsh "$fixture_root/lib/"
cp "$source_root/.gitignore" "$fixture_root/.gitignore"
cp "$source_root/schemas/result.schema.json" "$fixture_root/schemas/result.schema.json"
chmod +x "$fixture_root/bin/metal-llm"
cp "$suite" "$fixture_root/benchmarks/suites/qwen3.8-smoke.json"
cp "$source_root/$vision_fixture" "$fixture_root/$vision_fixture"

print -n -- 'fixture-model' > "$fixture_root/.lab/artifacts/fixture-model/model.gguf"
print -n -- 'fixture-projector' > "$fixture_root/.lab/artifacts/fixture-model/projector.gguf"
print -n -- 'fixture-mtp' > "$fixture_root/.lab/artifacts/fixture-model/mtp.gguf"
model_bytes=$(wc -c < "$fixture_root/.lab/artifacts/fixture-model/model.gguf" | tr -d ' ')
model_sha=$($real_shasum -a 256 "$fixture_root/.lab/artifacts/fixture-model/model.gguf" | awk '{print $1}')
projector_bytes=$(wc -c < "$fixture_root/.lab/artifacts/fixture-model/projector.gguf" | tr -d ' ')
projector_sha=$($real_shasum -a 256 "$fixture_root/.lab/artifacts/fixture-model/projector.gguf" | awk '{print $1}')
mtp_bytes=$(wc -c < "$fixture_root/.lab/artifacts/fixture-model/mtp.gguf" | tr -d ' ')
mtp_sha=$($real_shasum -a 256 "$fixture_root/.lab/artifacts/fixture-model/mtp.gguf" | awk '{print $1}')

$real_jq -n --arg sha "$model_sha" --argjson bytes "$model_bytes" \
  --arg projector_sha "$projector_sha" --argjson projector_bytes "$projector_bytes" \
  --arg mtp_sha "$mtp_sha" --argjson mtp_bytes "$mtp_bytes" '{
  schema_version: 2,
  id: "fixture-model",
  name: "Fixture Model",
  default_profile: "auto",
  max_context: 262144,
  runtime_aliases: {tuned: "fixture-runtime", upstream: "fixture-runtime"},
  artifacts: [
    {id: "model", kind: "model", filename: "model.gguf", url: "https://example.invalid/model", bytes: $bytes, sha256: $sha, license_url: "https://example.invalid/license"},
    {id: "projector", kind: "projector", filename: "projector.gguf", url: "https://example.invalid/projector", bytes: $projector_bytes, sha256: $projector_sha, license_url: "https://example.invalid/license"},
    {id: "mtp", kind: "mtp", filename: "mtp.gguf", url: "https://example.invalid/mtp", bytes: $mtp_bytes, sha256: $mtp_sha, license_url: "https://example.invalid/license"}
  ],
  text_model: {entry_artifact_id: "model", artifact_ids: ["model"], total_bytes: $bytes},
  capabilities: {
    vision: {default_enabled: true, projector_artifact_id: "projector", image_min_tokens: 1024},
    mtp: {artifact_id: "mtp", spec_type: "draft-mtp", draft_n_max: 2,
      gpu_layers: "all", dynamic_threshold: 32768}
  },
  metal: {gpu_layers: "all", fit: false, flash_attention: true, load_mode: "mmap", lazy_mmap: true},
  profiles: [
    {id: "fast", runtime: "tuned", context: 32768, mtp_policy: "on", status: "supported"},
    {id: "long", runtime: "tuned", context: 262144, mtp_policy: "off", status: "supported"},
    {id: "auto", runtime: "tuned", context: 262144, mtp_policy: "dynamic", status: "pending-acceptance"},
    {id: "stable", runtime: "upstream", context: 32768, mtp_policy: "off", status: "reference"}
  ]
}' > "$fixture_root/manifests/models/fixture-model.json"

runtime_source="$fixture_root/.lab/runtimes/fixture-runtime/source"
$real_git -C "$runtime_source" init -q
print -- 'fixture runtime source' > "$runtime_source/runtime.txt"
$real_git -C "$runtime_source" add runtime.txt
$real_git -C "$runtime_source" -c user.name='Bench Test' -c user.email='bench-test@localhost' \
  commit -qm 'fixture runtime'
runtime_tree=$($real_git -C "$runtime_source" rev-parse 'HEAD^{tree}')

$real_jq -n --arg tree "$runtime_tree" '{
  schema_version: 1, id: "fixture-runtime", repository: "https://example.invalid/runtime.git",
  base_revision: "2222222222222222222222222222222222222222", patches: [],
  tested_revision: "2222222222222222222222222222222222222222",
  tested_tree_sha: $tree,
  build: {generator: "Ninja", build_type: "Release", architecture: "arm64", cmake_options: {}, targets: ["llama-server", "llama-bench"]}
}' > "$fixture_root/manifests/runtimes/fixture-runtime.json"

$real_jq -n '{
  schema_version: 1, id: "fixture-hardware", chip: "Fixture Chip", architecture: "arm64",
  gpu_cores: 1, unified_memory_bytes: 1073741824, recommended_profile: "fast",
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
fake_server="$fixture_root/.lab/runtimes/fixture-runtime/build-metal/bin/llama-server"
print -r -- '#!/bin/zsh' > "$fake_server"
print -r -- 'exit 0' >> "$fake_server"
chmod +x "$fake_server"
bench_sha=$($real_shasum -a 256 "$fake_bench" | awk '{print $1}')
server_sha=$($real_shasum -a 256 "$fake_server" | awk '{print $1}')
runtime_manifest_sha=$($real_shasum -a 256 "$fixture_root/manifests/runtimes/fixture-runtime.json" | awk '{print $1}')
$real_jq -n --arg bench_sha "$bench_sha" --arg server_sha "$server_sha" \
  --arg tree "$runtime_tree" --arg manifest_sha "$runtime_manifest_sha" '{
  schema_version: 1, runtime_id: "fixture-runtime",
  runtime_manifest_sha256: $manifest_sha,
  tested_revision: "2222222222222222222222222222222222222222",
  source_tree_sha: $tree,
  tested_tree_sha: $tree,
  binaries: {"llama-server": {sha256: $server_sha}, "llama-bench": {sha256: $bench_sha}}
}' > "$fixture_root/.lab/runtimes/fixture-runtime/build-metal/build-receipt.json"

print -r -- '#!/bin/zsh' > "$fake_bin/uname"
print -r -- '[[ "${1:-}" == -s ]] && { print Darwin; exit; }' >> "$fake_bin/uname"
print -r -- '[[ "${1:-}" == -m ]] && { print arm64; exit; }' >> "$fake_bin/uname"
print -r -- 'print Darwin' >> "$fake_bin/uname"
chmod +x "$fake_bin/uname"
cat > "$fake_bin/curl" <<'EOF'
#!/bin/zsh
typeset -a shown
shown=()
for argument in "$@"; do
  if [[ "$argument" == 'Authorization: Bearer '* ]]; then
    shown+=('Authorization: Bearer <redacted>')
    print -r -- "$argument" >> "${FAKE_AUTH_CAPTURE:-/dev/null}"
  else
    shown+=("$argument")
  fi
done
print -r -- "${shown[*]}" >> "${FAKE_CURL_LOG:-/dev/null}"
if [[ "${shown[*]}" == *"/health"* ]]; then
  [[ "${FAKE_SERVER_ACTIVE:-0}" == 1 ]] && { print '{"status":"ok"}'; exit 0; }
  exit 22
fi
request="${shown[*]}"
effective_prompt_tokens=32768
speculative=true
if [[ "$request" == *'"image_url"'* ]]; then
  effective_prompt_tokens=32769
  speculative=false
fi
usage_prompt_tokens=$effective_prompt_tokens
[[ "${FAKE_BAD_SHORT_ROUTE:-0}" == 0 || "$request" == *'"image_url"'* ]] || speculative=false
[[ "${FAKE_BAD_LONG_ROUTE:-0}" == 0 || "$request" != *'"image_url"'* ]] || speculative=true
if [[ "${FAKE_TEXT_ONLY_TIMING:-0}" == 1 && "$request" == *'"image_url"'* ]]; then
  effective_prompt_tokens=3
  speculative=true
fi
if [[ "${FAKE_SUBSTITUTED_VISION_TIMING:-0}" == 1 && "$request" == *'"image_url"'* ]]; then
  effective_prompt_tokens=32768
  speculative=true
fi
timings=',"timings":{"speculative":'$speculative',"speculative_policy":"dynamic","effective_prompt_tokens":'$effective_prompt_tokens',"speculative_threshold":32768}'
[[ "${FAKE_OMIT_TIMINGS:-0}" == 0 ]] || timings=''
usage=',"usage":{"prompt_tokens":'$usage_prompt_tokens',"completion_tokens":2}'
[[ "${FAKE_OMIT_USAGE:-0}" == 0 ]] || usage=''
if [[ "${FAKE_NEGATIVE_USAGE:-0}" == 1 ]]; then
  usage=',"usage":{"prompt_tokens":-1,"completion_tokens":2}'
fi
if [[ "$request" == *'"stream":true'* ]]; then
  first_speculative=$speculative
  [[ "${FAKE_STREAM_ROUTE_CHANGE:-0}" == 0 ]] || {
    [[ "$speculative" == true ]] && first_speculative=false || first_speculative=true
  }
  first_timings=',"timings":{"speculative":'$first_speculative',"speculative_policy":"dynamic","effective_prompt_tokens":'$effective_prompt_tokens',"speculative_threshold":32768}'
  [[ "${FAKE_OMIT_TIMINGS:-0}" == 0 ]] || first_timings=''
  print -r -- 'data: {"choices":[{"delta":{"content":"fixture "}}]'$first_timings'}'
  print -r -- 'data: {"choices":[{"delta":{"content":"response"},"finish_reason":"stop"}]'$usage$timings'}'
  print -r -- 'data: [DONE]'
else
  print -r -- '{"choices":[{"message":{"content":"fixture response"}}]'$usage$timings'}'
fi
EOF
chmod +x "$fake_bin/curl"
cat > "$fake_bin/system_profiler" <<'EOF'
#!/bin/zsh
print -- "      Chip: ${BENCH_TEST_CHIP:-Fixture Chip}"
print -- "      Memory: ${BENCH_TEST_MEMORY_GB:-1} GB"
EOF
cat > "$fake_bin/ps" <<'EOF'
#!/bin/zsh
pid=''
while (( $# > 0 )); do
  [[ "$1" == -p ]] && { pid=$2; shift 2; continue; }
  shift
done
[[ -n "$pid" ]] || exit 2
print -- "fixture-start-$pid"
EOF
cat > "$fake_bin/sw_vers" <<'EOF'
#!/bin/zsh
[[ "$1" == -productVersion ]] || exit 2
print -- '26.0'
EOF
cat > "$fake_bin/xcrun" <<'EOF'
#!/bin/zsh
[[ "${BENCH_TEST_XCRUN_UNAVAILABLE:-0}" == 0 ]] || exit 127
if [[ "$*" == 'clang --version' ]]; then
  print -- 'Apple clang version 18.0.0 (clang-1800.0.1)'
elif [[ "$*" == '--sdk macosx --show-sdk-version' ]]; then
  print -- '26.0'
else
  exit 2
fi
EOF
cat > "$fake_bin/pmset" <<'EOF'
#!/bin/zsh
[[ "${BENCH_TEST_PMSET_UNAVAILABLE:-0}" == 0 ]] || exit 127
if [[ "$*" == '-g batt' ]]; then
  print -- "Now drawing from 'AC Power'"
elif [[ "$*" == '-g custom' ]]; then
  print -- ' lowpowermode         0'
else
  exit 2
fi
EOF
cat > "$fake_bin/date" <<'EOF'
#!/bin/zsh
[[ "$*" == '-u +%Y-%m-%dT%H:%M:%SZ' ]] || exit 2
print -- invoked >> "$FAKE_DATE_LOG"
print -- '1999-01-02T03:04:05Z'
EOF
chmod +x "$fake_bin/system_profiler" "$fake_bin/ps" "$fake_bin/sw_vers" "$fake_bin/xcrun" "$fake_bin/pmset" \
  "$fake_bin/date"

$real_git -C "$fixture_root" init -q
$real_git -C "$fixture_root" add .gitignore bin lib schemas benchmarks manifests
$real_git -C "$fixture_root" -c user.name='Bench Test' -c user.email='bench-test@localhost' \
  commit -qm 'fixture repository'
receipt_path="$fixture_root/.lab/runtimes/fixture-runtime/build-metal/build-receipt.json"
fixture_revision=$($real_git -C "$fixture_root" rev-parse HEAD)
fixture_tree=$($real_git -C "$fixture_root" rev-parse 'HEAD^{tree}')
suite_sha=$($real_shasum -a 256 "$fixture_root/benchmarks/suites/qwen3.8-smoke.json" | awk '{print $1}')
receipt_sha=$($real_shasum -a 256 "$receipt_path" | awk '{print $1}')
model_manifest_sha=$($real_shasum -a 256 "$fixture_root/manifests/models/fixture-model.json" | awk '{print $1}')

fixture_cli="$fixture_root/bin/metal-llm"
common_environment=(
  PATH="$fake_bin:$PATH"
  TMPDIR="$managed_tmp"
  METAL_LLM_RESULTS_DIR="$results_dir"
  BENCH_TEST_NOW=1998-01-02T03:04:05Z
  FAKE_DATE_LOG="$temporary_root/date.log"
  FAKE_BENCH_LOG="$temporary_root/bench.log"
  FAKE_CURL_LOG="$temporary_root/curl.log"
  FAKE_AUTH_CAPTURE="$temporary_root/auth.capture"
)

lease_dir="$managed_tmp/metal-llm-lab/full-model.lease"
lease_record="$lease_dir/identity.json"

clear_managed_lease() {
    rm -f -- "$lease_record" "$lease_dir/identity.json.part"
    rmdir "$lease_dir" 2>/dev/null || true
}

write_live_server_identity() {
    local pid=$1
    local profile=$2
    local vision=$3
    local runtime_alias context mtp_policy mtp_threshold
    case "$profile" in
        auto)
            runtime_alias=tuned
            context=262144
            mtp_policy=dynamic
            mtp_threshold=32768
            ;;
        fast)
            runtime_alias=tuned
            context=32768
            mtp_policy=on
            mtp_threshold=null
            ;;
        long)
            runtime_alias=tuned
            context=262144
            mtp_policy=off
            mtp_threshold=null
            ;;
        stable)
            runtime_alias=upstream
            context=32768
            mtp_policy=off
            mtp_threshold=null
            ;;
        custom)
            runtime_alias=${4:-tuned}
            context=${5:-65536}
            mtp_policy=${6:-dynamic}
            [[ "$mtp_policy" == dynamic ]] && mtp_threshold=32768 || mtp_threshold=null
            ;;
        *) fail "unknown managed identity test profile: $profile" ;;
    esac
    local current_receipt_sha model_manifest_sha artifacts
    current_receipt_sha=$($real_shasum -a 256 "$receipt_path" | awk '{print $1}')
    model_manifest_sha=$($real_shasum -a 256 "$fixture_root/manifests/models/fixture-model.json" | awk '{print $1}')
    artifacts=$($real_jq -c --argjson vision "$vision" --arg policy "$mtp_policy" '
      [.artifacts[] |
        select(.kind == "model" or ($vision and .kind == "projector") or
          ($policy != "off" and .kind == "mtp")) |
        {id, bytes, sha256}]
    ' "$fixture_root/manifests/models/fixture-model.json")
    mkdir -p "$lease_dir"
    $real_jq -n --argjson pid "$pid" --arg started "fixture-start-$pid" \
      --arg profile "$profile" --arg runtime_alias "$runtime_alias" \
      --argjson context "$context" --argjson vision "$vision" \
      --arg mtp_policy "$mtp_policy" --argjson mtp_threshold "$mtp_threshold" \
      --arg tree "$runtime_tree" \
      --arg runtime_manifest_sha "$runtime_manifest_sha" --arg receipt_sha "$current_receipt_sha" \
      --arg server_sha "$server_sha" --arg model_manifest_sha "$model_manifest_sha" \
      --argjson artifacts "$artifacts" '{
        schema_version: 2, owner_kind: "serve",
        owner_token: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        pid: $pid, process_started_at: $started,
        model_id: "fixture-model", profile_id: $profile, vision: $vision,
        runtime_alias: $runtime_alias, context: $context,
        mtp_policy: $mtp_policy, mtp_threshold: $mtp_threshold,
        runtime_id: "fixture-runtime", runtime_revision: "2222222222222222222222222222222222222222",
        runtime_tree_sha: $tree, runtime_manifest_sha256: $runtime_manifest_sha,
        build_receipt_sha256: $receipt_sha, executable_name: "llama-server",
        executable_sha256: $server_sha, model_manifest_sha256: $model_manifest_sha,
        artifacts: $artifacts, host: "127.0.0.1", port: 8080
      }' > "$lease_record"
}

dry_output=$(env "${common_environment[@]}" "$fixture_cli" bench fixture-model --suite qwen3.8-smoke --dry-run)
assert_contains "$dry_output" 'llama-bench'
assert_contains "$dry_output" '-p 512 -n 0'
assert_contains "$dry_output" '-p 0 -n 128'
[[ "$dry_output" != *'mtp.gguf'* && "$dry_output" != *'-md'* && "$dry_output" != *'--spec-'* ]] || \
  fail 'standalone llama-bench dry-run enabled server speculative decoding'
[[ "$dry_output" != *'HTTP POST'* ]] || fail 'local mode included endpoint cases'
dry_result_files=("$results_dir"/*(N))
(( ${#dry_result_files} == 0 )) || fail 'bench --dry-run wrote a result file'

upstream_dry=$(env "${common_environment[@]}" "$fixture_cli" bench fixture-model \
  --suite qwen3.8-smoke --runtime upstream --dry-run)
assert_contains "$upstream_dry" 'llama-bench'
for local_option in '--profile auto' '--vision on' '--mtp off' '--context 32768'; do
    if local_option_output=$(env "${common_environment[@]}" "$fixture_cli" bench fixture-model \
        --suite qwen3.8-smoke ${(z)local_option} --dry-run 2>&1); then
        fail "local benchmark accepted endpoint configuration: $local_option"
    fi
    assert_contains "$local_option_output" 'local benchmark accepts only --runtime tuned|upstream'
done
if invalid_runtime_output=$(env "${common_environment[@]}" "$fixture_cli" bench fixture-model \
    --suite qwen3.8-smoke --runtime other --dry-run 2>&1); then
    fail 'local benchmark accepted an unknown runtime alias'
fi
assert_contains "$invalid_runtime_output" 'runtime must be tuned or upstream'

run_output=$(env "${common_environment[@]}" "$fixture_cli" bench fixture-model --suite qwen3.8-smoke)
assert_contains "$run_output" 'wrote benchmark result:'
[[ "$run_output" != *'command_json='* ]] || fail 'local benchmark leaked an internal shell variable'
result_files=("$results_dir"/*.json(N))
(( ${#result_files} == 1 )) || fail "expected one result, found ${#result_files}"
result_file=$result_files[1]
jq -e '
  .date != "1999-01-02" and .date != "1998-01-02" and
  ((.experiment_id | startswith("19990102t030405z")) | not) and
  ((.experiment_id | startswith("19980102t030405z")) | not)
' "$result_file" >/dev/null || fail 'PATH or legacy test environment controlled the recorded benchmark time'
[[ ! -e "$temporary_root/date.log" ]] || fail 'benchmark invoked a PATH-selected date executable'
jq -e '
  .model_id == "fixture-model" and .suite_id == "qwen3.8-smoke" and .benchmark_mode == "local" and
  (.runs | length == 2) and
  (.runs[0].prompt_tokens_per_second == 987.25) and
  (.runs[1].generation_tokens_per_second == 44.5) and
  (.runs[0].prompt_tokens == 512) and (.runs[1].prompt_tokens == 0) and
  all(.runs[];
    .profile == null and .profile_id == null and .runtime_alias == "tuned" and
    .context == null and .vision == null and .mtp_policy == null and
    .mtp_selected == null and .effective_prompt_tokens == null and .mtp_threshold == null and
    (has("mtp") | not))
' "$result_file" >/dev/null
jq -e --arg revision "$fixture_revision" --arg tree "$fixture_tree" \
  --arg runtime_tree "$runtime_tree" --arg runtime_manifest_sha "$runtime_manifest_sha" \
  --arg receipt_sha "$receipt_sha" --arg bench_sha "$bench_sha" \
  --arg model_manifest_sha "$model_manifest_sha" --arg model_sha "$model_sha" --arg suite_sha "$suite_sha" '
  .provenance.repository == {revision: $revision, tree_sha: $tree, clean: true} and
  .provenance.hardware == {id: "fixture-hardware", chip: "Fixture Chip", unified_memory_bytes: 1073741824} and
  .provenance.system == {
    operating_system: "macOS", operating_system_version: "26.0",
    compiler: "Apple clang version 18.0.0 (clang-1800.0.1)", sdk: "26.0",
    power_source: "AC Power", low_power_mode: false
  } and
  .provenance.profile_id == null and .provenance.runtime_alias == "tuned" and
  .provenance.context == null and .provenance.vision == null and
  .provenance.mtp_policy == null and .provenance.mtp_threshold == null and
  .provenance.runtime.id == "fixture-runtime" and
  .provenance.runtime.tested_revision == "2222222222222222222222222222222222222222" and
  .provenance.runtime.tested_tree_sha == $runtime_tree and
  .provenance.runtime.manifest_sha256 == $runtime_manifest_sha and
  .provenance.runtime.build_receipt_sha256 == $receipt_sha and
  .provenance.runtime.executable == {name: "llama-bench", sha256: $bench_sha} and
  .provenance.model_manifest_sha256 == $model_manifest_sha and
  .provenance.artifacts == [{id: "model", bytes: 13, sha256: $model_sha}] and
  .provenance.suite == {id: "qwen3.8-smoke", sha256: $suite_sha, fixtures: []} and
  .runs[0].command == [
    "llama-bench", "-m", "artifact:model", "-ngl", "all", "-p", "512", "-n", "0",
    "-b", "512", "-ub", "512", "-r", "3", "-fa", "on", "-lm", "mmap", "-lzm", "on", "-o", "json"
  ] and
  .runs[1].command == [
    "llama-bench", "-m", "artifact:model", "-ngl", "all", "-p", "0", "-n", "128",
    "-b", "512", "-ub", "512", "-r", "3", "-fa", "on", "-lm", "mmap", "-lzm", "on", "-o", "json"
  ]
' "$result_file" >/dev/null || {
  jq '.provenance, .runs[].command' "$result_file" >&2
  fail 'benchmark result omitted or falsified required provenance'
}
partial_files=("$results_dir"/*.part*(N))
(( ${#partial_files} == 0 )) || fail 'bench left a partial result behind'
bench_log_contents=$(command cat -- "$temporary_root/bench.log")
assert_contains "$bench_log_contents" '-m'

collision_target="$temporary_root/collision-target.json"
collision_part="$temporary_root/collision-part.json"
print -n -- 'existing-result' > "$collision_target"
print -n -- 'candidate-result' > "$collision_part"
result_before_collision=$($real_shasum -a 256 "$collision_target" | awk '{print $1}')
if collision_output=$(zsh -fc '
    source "$1"
    source "$2"
    metal_llm_publish_benchmark_result "$3" "$4"
  ' -- "$fixture_root/lib/common.zsh" "$fixture_root/lib/bench.zsh" \
  "$collision_part" "$collision_target" 2>&1); then
    fail 'benchmark publication helper replaced an existing target'
fi
assert_contains "$collision_output" 'benchmark result already exists'
[[ $($real_shasum -a 256 "$collision_target" | awk '{print $1}') == "$result_before_collision" ]] || \
  fail 'benchmark collision changed the existing measurement'
[[ ! -e "$collision_part" ]] || fail 'benchmark collision leaked its candidate result'

time_override_results="$temporary_root/time-override-results"
mkdir -p "$time_override_results"
if time_override_output=$(env "${common_environment[@]}" \
    METAL_LLM_NOW=2026-09-03T12:34:59Z BENCH_TEST_NOW=2026-09-03T12:35:59Z \
    METAL_LLM_RESULTS_DIR="$time_override_results" \
    "$fixture_cli" bench fixture-model --suite qwen3.8-smoke 2>&1); then
    fail 'benchmark accepted the METAL_LLM_NOW production timestamp override'
fi
assert_contains "$time_override_output" 'METAL_LLM_NOW is not accepted'
time_override_files=("$time_override_results"/*(N))
(( ${#time_override_files} == 0 )) || fail 'rejected timestamp override leaked result data'

if timestamp_output=$(zsh -fc '
    source "$1"
    source "$2"
    metal_llm_validate_benchmark_timestamp "$3"
  ' -- "$fixture_root/lib/common.zsh" "$fixture_root/lib/bench.zsh" \
  '2026-02-30T12:34:56Z' 2>&1); then
    fail 'benchmark timestamp validator accepted an impossible calendar timestamp'
fi
assert_contains "$timestamp_output" 'real RFC 3339 UTC calendar timestamp'

hardware_results="$temporary_root/hardware-mismatch-results"
mkdir -p "$hardware_results"
if hardware_output=$(env "${common_environment[@]}" BENCH_TEST_MEMORY_GB=2 \
    METAL_LLM_RESULTS_DIR="$hardware_results" \
    "$fixture_cli" bench fixture-model --suite qwen3.8-smoke 2>&1); then
    fail 'benchmark assumed a hardware manifest that did not match the detected memory'
fi
assert_contains "$hardware_output" 'no unique hardware manifest matches Fixture Chip with 2 GB'

revision_results="$temporary_root/revision-override-results"
mkdir -p "$revision_results"
if revision_output=$(env "${common_environment[@]}" \
    METAL_LLM_REPOSITORY_REVISION=4444444444444444444444444444444444444444 \
    METAL_LLM_RESULTS_DIR="$revision_results" \
    "$fixture_cli" bench fixture-model --suite qwen3.8-smoke 2>&1); then
    fail 'benchmark accepted an arbitrary repository revision claim'
fi
assert_contains "$revision_output" 'METAL_LLM_REPOSITORY_REVISION is not accepted'

cp "$fixture_root/.gitignore" "$fixture_root/.gitignore.saved"
print -- '# dirty benchmark checkout' >> "$fixture_root/.gitignore"
dirty_results="$temporary_root/dirty-repository-results"
mkdir -p "$dirty_results"
if dirty_output=$(env "${common_environment[@]}" METAL_LLM_RESULTS_DIR="$dirty_results" \
    "$fixture_cli" bench fixture-model --suite qwen3.8-smoke 2>&1); then
    mv "$fixture_root/.gitignore.saved" "$fixture_root/.gitignore"
    fail 'benchmark accepted a dirty repository checkout'
fi
mv "$fixture_root/.gitignore.saved" "$fixture_root/.gitignore"
assert_contains "$dirty_output" 'benchmark repository checkout is not clean'

unavailable_results="$temporary_root/unavailable-environment-results"
mkdir -p "$unavailable_results"
env "${common_environment[@]}" BENCH_TEST_XCRUN_UNAVAILABLE=1 BENCH_TEST_PMSET_UNAVAILABLE=1 \
  METAL_LLM_RESULTS_DIR="$unavailable_results" \
  "$fixture_cli" bench fixture-model --suite qwen3.8-smoke >/dev/null
unavailable_files=("$unavailable_results"/*.json(N))
(( ${#unavailable_files} == 1 )) || fail 'unavailable-environment benchmark did not publish exactly one result'
unavailable_file=$unavailable_files[1]
jq -e '
  .provenance.system.compiler == null and .provenance.system.sdk == null and
  .provenance.system.power_source == null and .provenance.system.low_power_mode == null
' "$unavailable_file" >/dev/null || fail 'unavailable environment evidence was omitted or encoded as a fake value'

cp "$receipt_path" "$receipt_path.saved"
$real_jq '.unexpected = true' "$receipt_path.saved" > "$receipt_path"
if receipt_output=$(env "${common_environment[@]}" "$fixture_cli" bench fixture-model --suite qwen3.8-smoke 2>&1); then
    fail 'bench accepted a build receipt with an unknown field'
fi
assert_contains "$receipt_output" 'invalid build receipt'
mv "$receipt_path.saved" "$receipt_path"

cp "$receipt_path" "$receipt_path.saved"
$real_jq '.runtime_manifest_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  "$receipt_path.saved" > "$receipt_path"
if receipt_output=$(env "${common_environment[@]}" "$fixture_cli" bench fixture-model --suite qwen3.8-smoke 2>&1); then
    fail 'bench accepted a stale runtime-manifest receipt identity'
fi
assert_contains "$receipt_output" 'build receipt does not match runtime manifest'
mv "$receipt_path.saved" "$receipt_path"

mv "$runtime_source" "$runtime_source.missing"
if source_output=$(env "${common_environment[@]}" "$fixture_cli" bench fixture-model --suite qwen3.8-smoke 2>&1); then
    fail 'bench accepted a missing runtime source checkout'
fi
assert_contains "$source_output" 'runtime source is missing'
mv "$runtime_source.missing" "$runtime_source"

print -- dirty > "$runtime_source/untracked.txt"
if source_output=$(env "${common_environment[@]}" "$fixture_cli" bench fixture-model --suite qwen3.8-smoke 2>&1); then
    fail 'bench accepted a dirty runtime source checkout'
fi
assert_contains "$source_output" 'runtime source is not clean'
rm "$runtime_source/untracked.txt"

cp "$fake_server" "$fake_server.saved"
print -- '# changed non-selected binary' >> "$fake_server"
if binary_output=$(env "${common_environment[@]}" "$fixture_cli" bench fixture-model \
    --suite qwen3.8-smoke 2>&1); then
    mv "$fake_server.saved" "$fake_server"
    fail 'local benchmark accepted a changed non-selected server binary'
fi
assert_contains "$binary_output" 'server binary checksum mismatch for fixture-runtime'
mv "$fake_server.saved" "$fake_server"

sleep 60 &!
managed_identity_pid=$!
write_live_server_identity "$managed_identity_pid" auto true
live_results="$temporary_root/live-conflict-results"
mkdir -p "$live_results"
if lease_output=$(env "${common_environment[@]}" METAL_LLM_RESULTS_DIR="$live_results" \
    "$fixture_cli" bench fixture-model --suite qwen3.8-smoke 2>&1); then
    kill "$managed_identity_pid" 2>/dev/null || true
    wait "$managed_identity_pid" 2>/dev/null || true
    fail 'local bench ran beside a live managed full-model process'
fi
assert_contains "$lease_output" 'managed full-model process is already active'
kill "$managed_identity_pid" 2>/dev/null || true
wait "$managed_identity_pid" 2>/dev/null || true

stale_results="$temporary_root/stale-recovery-results"
mkdir -p "$stale_results"
env "${common_environment[@]}" METAL_LLM_RESULTS_DIR="$stale_results" \
  "$fixture_cli" bench fixture-model --suite qwen3.8-smoke >/dev/null
[[ ! -e "$lease_dir" ]] || fail 'local bench did not release a recovered stale managed lease'

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
# Strict receipt verification checks both recorded runtime executables even
# though endpoint mode invokes only the already loaded server.

endpoint_dry=$(env "${common_environment[@]}" FAKE_SERVER_ACTIVE=1 METAL_LLM_INCLUDE_OPTIONAL=1 \
    METAL_LLM_RESULTS_DIR="$endpoint_results" "$fixture_cli" bench fixture-model \
    --suite qwen3.8-smoke --mode endpoint --dry-run)
assert_contains "$endpoint_dry" 'HTTP POST'
[[ "$endpoint_dry" != *'llama-bench'* ]] || fail 'endpoint mode included local cases'

clear_managed_lease
no_identity_results="$temporary_root/no-identity-results"
mkdir -p "$no_identity_results"
if identity_output=$(env "${common_environment[@]}" FAKE_SERVER_ACTIVE=1 \
    METAL_LLM_RESULTS_DIR="$no_identity_results" "$fixture_cli" bench fixture-model \
    --suite qwen3.8-smoke --mode endpoint 2>&1); then
    fail 'endpoint mode trusted a responding endpoint without managed identity'
fi
assert_contains "$identity_output" 'no managed full-model identity is available'

sleep 60 &!
managed_identity_pid=$!
write_live_server_identity "$managed_identity_pid" auto true
if inactive_output=$(env "${common_environment[@]}" METAL_LLM_RESULTS_DIR="$endpoint_results" \
    "$fixture_cli" bench fixture-model --suite qwen3.8-smoke --mode endpoint 2>&1); then
    kill "$managed_identity_pid" 2>/dev/null || true
    wait "$managed_identity_pid" 2>/dev/null || true
    fail 'endpoint mode ran when its managed server was not responding'
fi
assert_contains "$inactive_output" 'endpoint mode requires a running endpoint'

if mismatch_output=$(env "${common_environment[@]}" FAKE_SERVER_ACTIVE=1 \
    METAL_LLM_RESULTS_DIR="$endpoint_results" "$fixture_cli" bench fixture-model \
    --suite qwen3.8-smoke --mode endpoint --profile fast 2>&1); then
    kill "$managed_identity_pid" 2>/dev/null || true
    wait "$managed_identity_pid" 2>/dev/null || true
    fail 'endpoint mode accepted a requested profile that did not match the managed server'
fi
assert_contains "$mismatch_output" 'managed endpoint identity does not match resolved configuration'
if vision_mismatch_output=$(env "${common_environment[@]}" FAKE_SERVER_ACTIVE=1 \
    METAL_LLM_RESULTS_DIR="$endpoint_results" "$fixture_cli" bench fixture-model \
    --suite qwen3.8-smoke --mode endpoint --vision off 2>&1); then
    kill "$managed_identity_pid" 2>/dev/null || true
    wait "$managed_identity_pid" 2>/dev/null || true
    fail 'endpoint mode accepted requested vision state that did not match the managed server'
fi
assert_contains "$vision_mismatch_output" 'managed endpoint identity does not match resolved configuration'

identity_base="$temporary_root/managed-auto-identity.json"
cp "$lease_record" "$identity_base"
identity_mismatch_results="$temporary_root/identity-mismatch-results"
mkdir -p "$identity_mismatch_results"
typeset -a identity_mutations
identity_mutations=(
  '.runtime_alias = "upstream" | .mtp_policy = "off" | .mtp_threshold = null | .artifacts |= map(select(.id != "mtp"))'
  '.context = 131072'
  '.mtp_policy = "on" | .mtp_threshold = null'
  '.mtp_threshold = 32767'
  '.artifacts |= map(select(.id != "projector"))'
)
for identity_mutation in "${identity_mutations[@]}"; do
    $real_jq "$identity_mutation" "$identity_base" > "$lease_record.part"
    mv "$lease_record.part" "$lease_record"
    if identity_mismatch_output=$(env "${common_environment[@]}" FAKE_SERVER_ACTIVE=1 \
        METAL_LLM_RESULTS_DIR="$identity_mismatch_results" "$fixture_cli" bench fixture-model \
        --suite qwen3.8-smoke --mode endpoint 2>&1); then
        kill "$managed_identity_pid" 2>/dev/null || true
        wait "$managed_identity_pid" 2>/dev/null || true
        fail "endpoint mode accepted mismatched managed identity: $identity_mutation"
    fi
    assert_contains "$identity_mismatch_output" 'managed endpoint identity does not match resolved configuration'
done
cp "$identity_base" "$lease_record"
identity_mismatch_files=("$identity_mismatch_results"/*(N))
(( ${#identity_mismatch_files} == 0 )) || fail 'identity mismatch leaked benchmark result data'

assert_endpoint_route_failure() {
    local fake_setting=$1
    local expected_error=$2
    local label=${fake_setting%%=*}
    local failure_results="$temporary_root/${(L)label}-results"
    mkdir -p "$failure_results"
    if route_failure_output=$(env "${common_environment[@]}" FAKE_SERVER_ACTIVE=1 \
        METAL_LLM_INCLUDE_OPTIONAL=1 "$fake_setting" METAL_LLM_RESULTS_DIR="$failure_results" \
        "$fixture_cli" bench fixture-model --suite qwen3.8-smoke --mode endpoint 2>&1); then
        fail "endpoint benchmark accepted invalid route evidence: $label"
    fi
    assert_contains "$route_failure_output" "$expected_error"
    route_failure_files=("$failure_results"/*(N))
    (( ${#route_failure_files} == 0 )) || fail "invalid route evidence leaked output: $label"
}

assert_endpoint_route_failure FAKE_OMIT_TIMINGS=1 'missing final endpoint timing metadata'
assert_endpoint_route_failure FAKE_BAD_SHORT_ROUTE=1 'endpoint timing metadata does not match managed MTP policy'
assert_endpoint_route_failure FAKE_BAD_LONG_ROUTE=1 'endpoint timing metadata does not match managed MTP policy'
assert_endpoint_route_failure FAKE_TEXT_ONLY_TIMING=1 'endpoint effective prompt count is below resolved vision expansion minimum'
assert_endpoint_route_failure FAKE_SUBSTITUTED_VISION_TIMING=1 \
  'endpoint vision prompt-token usage does not match effective prompt timing'
assert_endpoint_route_failure FAKE_STREAM_ROUTE_CHANGE=1 'endpoint stream changed MTP route metadata'

endpoint_secret='endpoint-secret-must-not-leak'
endpoint_output=$(env "${common_environment[@]}" METAL_LLM_API_KEY="$endpoint_secret" \
    FAKE_SERVER_ACTIVE=1 METAL_LLM_INCLUDE_OPTIONAL=1 \
    METAL_LLM_RESULTS_DIR="$endpoint_results" "$fixture_cli" bench fixture-model \
    --suite qwen3.8-smoke --mode endpoint)
[[ "$endpoint_output" != *"$endpoint_secret"* ]] || fail 'endpoint benchmark printed METAL_LLM_API_KEY'
[[ "$endpoint_output" != *'command_json='* ]] || fail 'endpoint benchmark leaked an internal shell variable'
endpoint_files=("$endpoint_results"/*.json(N))
(( ${#endpoint_files} == 1 )) || fail "expected one endpoint result, found ${#endpoint_files}"
jq -e '
  .benchmark_mode == "endpoint" and (.runs | length == 2) and
  .provenance.profile_id == "auto" and .provenance.runtime_alias == "tuned" and
  .provenance.context == 262144 and .provenance.vision == true and
  .provenance.mtp_policy == "dynamic" and .provenance.mtp_threshold == 32768 and
  all(.runs[];
    .profile == null and .profile_id == "auto" and .runtime_alias == "tuned" and
    .runtime_id == "fixture-runtime" and .context == 262144 and .vision == true and
    .mtp_policy == "dynamic" and .mtp_threshold == 32768 and
    (.request_kind == "text" or .request_kind == "vision") and
    (.prompt_tokens | type == "number" and floor == . and . >= 0) and .generated_tokens == 2 and
    .prompt_tokens_per_second == null and .generation_tokens_per_second == null) and
  (.runs | map({id, effective_prompt_tokens, mtp_selected})) == [
    {id: "deterministic-api-smoke", effective_prompt_tokens: 32768, mtp_selected: true},
    {id: "vision-spatial-smoke", effective_prompt_tokens: 32769, mtp_selected: false}
  ]
' "$endpoint_files[1]" >/dev/null
curl_log_contents=$(command cat -- "$temporary_root/curl.log")
auth_capture_contents=$(command cat -- "$temporary_root/auth.capture")
assert_contains "$curl_log_contents" 'data:image/png;base64,'
assert_contains "$curl_log_contents" 'Authorization: Bearer <redacted>'
assert_contains "$auth_capture_contents" "Authorization: Bearer $endpoint_secret"
[[ "$curl_log_contents" != *"$endpoint_secret"* ]] || fail 'endpoint benchmark logged METAL_LLM_API_KEY'
if rg -q --fixed-strings "$endpoint_secret" "$endpoint_files[1]"; then
    fail 'endpoint result persisted METAL_LLM_API_KEY'
fi

negative_usage_results="$temporary_root/negative-usage-results"
mkdir -p "$negative_usage_results"
if negative_usage_output=$(env "${common_environment[@]}" FAKE_SERVER_ACTIVE=1 FAKE_NEGATIVE_USAGE=1 \
    METAL_LLM_RESULTS_DIR="$negative_usage_results" \
    "$fixture_cli" bench fixture-model --suite qwen3.8-smoke --mode endpoint 2>&1); then
    fail 'endpoint benchmark published a result with negative API usage counters'
fi
assert_contains "$negative_usage_output" 'invalid result document: pending benchmark result'
negative_usage_files=("$negative_usage_results"/*(N))
(( ${#negative_usage_files} == 0 )) || fail 'invalid API usage leaked a result or temporary file'

custom_results="$temporary_root/custom-endpoint-results"
mkdir -p "$custom_results"
write_live_server_identity "$managed_identity_pid" custom false tuned 65536 dynamic
custom_output=$(env "${common_environment[@]}" FAKE_SERVER_ACTIVE=1 \
  METAL_LLM_RESULTS_DIR="$custom_results" "$fixture_cli" bench fixture-model \
  --suite qwen3.8-smoke --mode endpoint --profile custom --runtime tuned \
  --mtp dynamic --context 65536 --vision off)
assert_contains "$custom_output" 'wrote benchmark result:'
custom_files=("$custom_results"/*.json(N))
(( ${#custom_files} == 1 )) || fail 'custom endpoint benchmark did not publish exactly one result'
jq -e '
  .provenance.profile_id == "custom" and .provenance.runtime_alias == "tuned" and
  .provenance.context == 65536 and .provenance.vision == false and
  .provenance.mtp_policy == "dynamic" and .provenance.mtp_threshold == 32768 and
  (.runs | length == 1) and .runs[0].profile_id == "custom" and
  .runs[0].effective_prompt_tokens == 32768 and .runs[0].mtp_selected == true
' "$custom_files[1]" >/dev/null || fail 'custom endpoint configuration was not recorded exactly'

kill "$managed_identity_pid" 2>/dev/null || true
wait "$managed_identity_pid" 2>/dev/null || true
clear_managed_lease

sleep 60 &!
managed_identity_pid=$!
write_live_server_identity "$managed_identity_pid" fast false
nonvision_results="$temporary_root/nonvision-results"
mkdir -p "$nonvision_results"
if vision_output=$(env "${common_environment[@]}" FAKE_SERVER_ACTIVE=1 METAL_LLM_INCLUDE_OPTIONAL=1 \
    METAL_LLM_RESULTS_DIR="$nonvision_results" "$fixture_cli" bench fixture-model \
    --suite qwen3.8-smoke --mode endpoint 2>&1); then
    kill "$managed_identity_pid" 2>/dev/null || true
    wait "$managed_identity_pid" 2>/dev/null || true
    fail 'endpoint mode sent a vision case to a non-vision managed profile'
fi
assert_contains "$vision_output" 'vision benchmark requires a vision-capable managed profile'
kill "$managed_identity_pid" 2>/dev/null || true
wait "$managed_identity_pid" 2>/dev/null || true
clear_managed_lease

print -n -- 'outside-fixture' > "$fixture_root/outside.png"
ln -s ../../outside.png "$fixture_root/benchmarks/fixtures/escape.png"
cp "$fixture_root/$vision_fixture" "$fixture_root/benchmarks/fixtures/png-content.jpg"
cp "$fixture_root/$vision_fixture" "$fixture_root/benchmarks/fixtures/uppercase.PNG"
printf '\377\330\377\340\000\020JFIF\000\001\001\000\000\001\000\001\000\000\377\331' > \
  "$fixture_root/benchmarks/fixtures/jpeg-content.png"
$real_jq -n '{
  schema_version: 1, id: "traversal-fixture", default_mode: "endpoint",
  cases: [{id: "traversal", mode: "endpoint", kind: "vision", prompt: "Describe it.",
    fixture: "benchmarks/fixtures/../outside.png", max_tokens: 8, temperature: 0, seed: 1,
    notes: "Traversal fixture must be rejected"}]
}' > "$fixture_root/benchmarks/suites/traversal-fixture.json"
$real_jq -n '{
  schema_version: 1, id: "symlink-fixture", default_mode: "endpoint",
  cases: [{id: "symlink", mode: "endpoint", kind: "vision", prompt: "Describe it.",
    fixture: "benchmarks/fixtures/escape.png", max_tokens: 8, temperature: 0, seed: 1,
    notes: "Symlink fixture must be rejected"}]
}' > "$fixture_root/benchmarks/suites/symlink-fixture.json"
for fixture_suite in png-as-jpg jpeg-as-png uppercase-png; do
    if [[ "$fixture_suite" == png-as-jpg ]]; then
        mislabeled_fixture=benchmarks/fixtures/png-content.jpg
    elif [[ "$fixture_suite" == jpeg-as-png ]]; then
        mislabeled_fixture=benchmarks/fixtures/jpeg-content.png
    else
        mislabeled_fixture=benchmarks/fixtures/uppercase.PNG
    fi
    "$real_jq" -n --arg id "$fixture_suite" --arg fixture "$mislabeled_fixture" '{
      schema_version: 1, id: $id, default_mode: "endpoint",
      cases: [{id: "mislabeled", mode: "endpoint", kind: "vision", prompt: "Describe it.",
        fixture: $fixture, max_tokens: 8, temperature: 0, seed: 1,
        notes: "Fixture extension and MIME must agree"}]
    }' > "$fixture_root/benchmarks/suites/$fixture_suite.json"
done
$real_git -C "$fixture_root" add outside.png benchmarks/fixtures/escape.png \
  benchmarks/fixtures/png-content.jpg benchmarks/fixtures/jpeg-content.png benchmarks/fixtures/uppercase.PNG \
  benchmarks/suites/traversal-fixture.json benchmarks/suites/symlink-fixture.json \
  benchmarks/suites/png-as-jpg.json benchmarks/suites/jpeg-as-png.json benchmarks/suites/uppercase-png.json
$real_git -C "$fixture_root" -c user.name='Bench Test' -c user.email='bench-test@localhost' \
  commit -qm 'add adversarial fixture cases'

sleep 60 &!
managed_identity_pid=$!
write_live_server_identity "$managed_identity_pid" auto true
for fixture_suite in traversal-fixture symlink-fixture png-as-jpg jpeg-as-png uppercase-png; do
    fixture_escape_results="$temporary_root/$fixture_suite-results"
    mkdir -p "$fixture_escape_results"
    if fixture_escape_output=$(env "${common_environment[@]}" FAKE_SERVER_ACTIVE=1 \
        METAL_LLM_RESULTS_DIR="$fixture_escape_results" \
        "$fixture_cli" bench fixture-model --suite "$fixture_suite" --mode endpoint 2>&1); then
        kill "$managed_identity_pid" 2>/dev/null || true
        wait "$managed_identity_pid" 2>/dev/null || true
        fail "endpoint benchmark accepted unsafe fixture suite: $fixture_suite"
    fi
    assert_contains "$fixture_escape_output" 'vision fixture'
    fixture_escape_files=("$fixture_escape_results"/*(N))
    (( ${#fixture_escape_files} == 0 )) || fail "unsafe fixture suite leaked output: $fixture_suite"
done
kill "$managed_identity_pid" 2>/dev/null || true
wait "$managed_identity_pid" 2>/dev/null || true
clear_managed_lease

cp "$endpoint_files[1]" "$fixture_root/results/raw/endpoint.json"
endpoint_report=$(env "${common_environment[@]}" "$fixture_cli" report)
assert_contains "$endpoint_report" '| Run | Experiment | Prompt tokens | Effective prompt tokens | MTP policy | Selected route | Generated tokens | Prompt tok/s | Generation tok/s |'
assert_contains "$endpoint_report" '| deterministic-api-smoke | suite-run | 32,768 | 32,768 | dynamic | on | 2 | n/a | n/a |'
assert_contains "$endpoint_report" '| vision-spatial-smoke | suite-run | 32,769 | 32,769 | dynamic | off | 2 | n/a | n/a |'

if mode_output=$(env "${common_environment[@]}" "$fixture_cli" bench fixture-model \
    --suite qwen3.8-smoke --mode mixed 2>&1); then
    fail 'bench accepted an unknown suite mode'
fi
assert_contains "$mode_output" 'mode not found: mixed'

print -- 'bench checks: PASS'
