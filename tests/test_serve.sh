#!/bin/zsh
set -euo pipefail
unsetopt bg_nice

source_root=${0:A:h:h}
real_jq=$(command -v jq)
real_shasum=$(command -v shasum)
real_git=$(command -v git)

fail() {
    print -u2 -- "$1"
    exit 1
}

assert_equals() {
    local actual=$1
    local expected=$2
    [[ "$actual" == "$expected" ]] || fail "expected:\n$expected\nactual:\n$actual"
}

assert_count() {
    local haystack=$1
    local needle=$2
    local expected=$3
    local actual
    actual=$(print -r -- "$haystack" | /usr/bin/grep -F -c -- "$needle" || true)
    (( actual == expected )) || fail "expected $expected occurrences of '$needle', got $actual"
}

assert_passthrough_rejected() {
    local description=$1
    shift
    local passthrough_output
    if passthrough_output=$(PATH="$test_path" "$cli" serve fixture-model --profile long \
        --dry-run -- "$@" 2>&1); then
        fail "serve accepted identity-changing passthrough: $description"
    fi
    assert_contains "$passthrough_output" 'unsupported serve passthrough option'
}

assert_contains() {
    local haystack=$1
    local needle=$2
    [[ "$haystack" == *"$needle"* ]] || fail "missing expected output: $needle"
}

assert_serve_usage_rejected() {
    local description=$1
    shift
    local usage_output
    if usage_output=$(PATH="$test_path" "$cli" serve fixture-model "$@" --dry-run 2>&1); then
        fail "serve accepted invalid parser input: $description"
    else
        local usage_status=$?
    fi
    (( usage_status == 2 )) || fail "serve parser rejection exited $usage_status, expected 2: $description"
    assert_contains "$usage_output" 'usage: metal-llm serve MODEL'
}

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-serve.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT
fixture_root="$temporary_root/repository"
fake_bin="$temporary_root/bin"
managed_tmp="$temporary_root/managed-tmp"
mkdir -p "$fixture_root"/{bin,lib,manifests/models,manifests/runtimes,manifests/hardware} \
    "$fake_bin" "$managed_tmp" "$fixture_root/.lab/artifacts/fixture-model"
export TMPDIR="$managed_tmp"
fixture_root=${fixture_root:A}
artifact_dir="$fixture_root/.lab/artifacts/fixture-model"
cp "$source_root/bin/metal-llm" "$fixture_root/bin/metal-llm"
cp "$source_root/lib"/*.zsh "$fixture_root/lib/"

print -n -- 'model' > "$artifact_dir/model.gguf"
print -n -- 'projector' > "$artifact_dir/projector.gguf"
print -n -- 'mtp' > "$artifact_dir/mtp.gguf"
model_sha=$($real_shasum -a 256 "$artifact_dir/model.gguf" | awk '{print $1}')
projector_sha=$($real_shasum -a 256 "$artifact_dir/projector.gguf" | awk '{print $1}')
mtp_sha=$($real_shasum -a 256 "$artifact_dir/mtp.gguf" | awk '{print $1}')

"$real_jq" -n \
    --arg model_sha "$model_sha" \
    --arg projector_sha "$projector_sha" \
    --arg mtp_sha "$mtp_sha" '
    {
      schema_version: 2,
      id: "fixture-model",
      name: "Fixture Model",
      default_profile: "auto",
      max_context: 262144,
      runtime_aliases: {tuned: "hybrid", upstream: "stable"},
      artifacts: [
        {id: "model", kind: "model", filename: "model.gguf", url: "https://example.invalid/model", bytes: 5, sha256: $model_sha, license_url: "https://example.invalid/license"},
        {id: "projector", kind: "projector", filename: "projector.gguf", url: "https://example.invalid/projector", bytes: 9, sha256: $projector_sha, license_url: "https://example.invalid/license"},
        {id: "mtp", kind: "mtp", filename: "mtp.gguf", url: "https://example.invalid/mtp", bytes: 3, sha256: $mtp_sha, license_url: "https://example.invalid/license"}
      ],
      text_model: {entry_artifact_id: "model", artifact_ids: ["model"], total_bytes: 5},
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

for runtime_id in hybrid stable; do
    runtime_dir="$fixture_root/.lab/runtimes/$runtime_id"
    source_dir="$runtime_dir/source"
    build_dir="$runtime_dir/build-metal"
    mkdir -p "$source_dir" "$build_dir/bin"
    "$real_git" -C "$source_dir" init -q
    "$real_git" -C "$source_dir" config filter.conceal.clean "sed 's/^conceal-B$/conceal-A/'"
    "$real_git" -C "$source_dir" config filter.conceal.smudge cat
    "$real_git" -C "$source_dir" config filter.conceal.required true
    print -- 'filtered.txt filter=conceal' > "$source_dir/.gitattributes"
    print -- conceal-A > "$source_dir/filtered.txt"
    funny_source_name=$'funny\tname\nsource.txt'
    print -- 'funny filename source' > "$source_dir/$funny_source_name"
    print -- "$runtime_id source" > "$source_dir/runtime.txt"
    "$real_git" -C "$source_dir" add .gitattributes filtered.txt "$funny_source_name" runtime.txt
    "$real_git" -C "$source_dir" -c user.name='Serve Test' -c user.email='serve-test@localhost' \
        commit -qm 'fixture runtime'
    source_tree=$($real_git -C "$source_dir" rev-parse 'HEAD^{tree}')
    print -r -- '#!/bin/zsh' > "$build_dir/bin/llama-server"
    print -r -- 'print -r -- "$@" > "$SERVE_TEST_EXEC_LOG"' >> "$build_dir/bin/llama-server"
    print -r -- 'if [[ "${SERVE_TEST_HOLD:-0}" == 1 ]]; then' >> "$build_dir/bin/llama-server"
    print -r -- '  print ready > "$SERVE_TEST_READY"' >> "$build_dir/bin/llama-server"
    print -r -- '  while true; do sleep 1; done' >> "$build_dir/bin/llama-server"
    print -r -- 'fi' >> "$build_dir/bin/llama-server"
    print -r -- '#!/bin/zsh' > "$build_dir/bin/llama-bench"
    print -r -- 'exit 0' >> "$build_dir/bin/llama-bench"
    chmod +x "$build_dir/bin/llama-server" "$build_dir/bin/llama-bench"
    "$real_jq" -n --arg id "$runtime_id" --arg tree "$source_tree" '{
      schema_version: 1, id: $id, repository: "https://example.invalid/runtime.git",
      base_revision: "1111111111111111111111111111111111111111", patches: [],
      tested_revision: "1111111111111111111111111111111111111111",
      tested_tree_sha: $tree,
      build: {generator: "Ninja", build_type: "Release", architecture: "arm64",
              cmake_options: {CMAKE_BUILD_TYPE: "Release"}, targets: ["llama-server"]}
    }' > "$fixture_root/manifests/runtimes/$runtime_id.json"
    manifest_sha=$($real_shasum -a 256 "$fixture_root/manifests/runtimes/$runtime_id.json" | awk '{print $1}')
    server_sha=$($real_shasum -a 256 "$build_dir/bin/llama-server" | awk '{print $1}')
    bench_sha=$($real_shasum -a 256 "$build_dir/bin/llama-bench" | awk '{print $1}')
    "$real_jq" -n \
        --arg id "$runtime_id" --arg tree "$source_tree" --arg manifest "$manifest_sha" \
        --arg server "$server_sha" --arg bench "$bench_sha" '{
          schema_version: 1, runtime_id: $id, runtime_manifest_sha256: $manifest,
          tested_revision: "1111111111111111111111111111111111111111",
          source_tree_sha: $tree, tested_tree_sha: $tree,
          binaries: {
            "llama-server": {sha256: $server},
            "llama-bench": {sha256: $bench}
          }
        }' > "$build_dir/build-receipt.json"
done

cat > "$fixture_root/manifests/hardware/apple-m5-max-128gb.json" <<'EOF'
{
  "schema_version": 1,
  "id": "apple-m5-max-128gb",
  "chip": "Apple M5 Max",
  "architecture": "arm64",
  "gpu_cores": 40,
  "unified_memory_bytes": 137438953472,
  "recommended_profile": "vision",
  "tested": {"date": "2026-09-03", "operating_system": "macOS"}
}
EOF

cat > "$fake_bin/uname" <<'EOF'
#!/bin/zsh
case "$1" in
  -s) print -- Darwin ;;
  -m) print -- arm64 ;;
  *) exit 2 ;;
esac
EOF
cat > "$fake_bin/system_profiler" <<'EOF'
#!/bin/zsh
print -- '      Chip: Apple M5 Max'
print -- '      Memory: 128 GB'
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
chmod +x "$fake_bin/uname" "$fake_bin/system_profiler" "$fake_bin/ps"
ln -s "$real_jq" "$fake_bin/jq"
cat > "$fake_bin/shasum" <<EOF
#!/bin/zsh
for argument in "\$@"; do
  [[ "\$argument" == *.gguf ]] && print -r -- "\$argument" >> "\${SERVE_TEST_ARTIFACT_HASH_LOG:?}"
done
exec "$real_shasum" "\$@"
EOF
chmod +x "$fake_bin/shasum"
test_path="$fake_bin:/bin:/usr/bin"
cli="$fixture_root/bin/metal-llm"
model_path="$artifact_dir/model.gguf"
projector_path="$artifact_dir/projector.gguf"
mtp_path="$artifact_dir/mtp.gguf"
hybrid_server="$fixture_root/.lab/runtimes/hybrid/build-metal/bin/llama-server"
stable_server="$fixture_root/.lab/runtimes/stable/build-metal/bin/llama-server"

common_hybrid="command: $hybrid_server -m $model_path -ngl all -fit off -fa on -lm mmap -lzm on"
network_defaults='-np 1 --host 127.0.0.1 --port 8080'
mtp_flags="--spec-draft-model $mtp_path --spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-ngl all"
dynamic_threshold='--spec-draft-max-prompt-tokens 32768'
export SERVE_TEST_ARTIFACT_HASH_LOG="$temporary_root/artifact-hashes.log"
: > "$SERVE_TEST_ARTIFACT_HASH_LOG"

lab_before=$(find "$fixture_root/.lab" -type f -exec "$real_shasum" -a 256 {} \; | LC_ALL=C sort)
auto_output=$(PATH="$test_path" "$cli" serve fixture-model --dry-run)
assert_contains "$auto_output" 'artifact verification: requested=cached effective=full cache_hits=0 cache_misses=3 full_hashes=3'
assert_contains "$auto_output" "$common_hybrid -c 262144 $network_defaults -mm $projector_path --image-min-tokens 1024 $mtp_flags $dynamic_threshold"
assert_count "$auto_output" 'artifact verification:' 1
assert_equals "$(wc -l < "$SERVE_TEST_ARTIFACT_HASH_LOG" | tr -d ' ')" 3
for required_path in "$model_path" "$projector_path" "$mtp_path"; do
    assert_count "$(<"$SERVE_TEST_ARTIFACT_HASH_LOG")" "${required_path:A}" 1
done
[[ ! -e "$managed_tmp/metal-llm-lab" ]] || fail 'serve --dry-run wrote managed lease state'
lab_after=$(find "$fixture_root/.lab" -type f -exec "$real_shasum" -a 256 {} \; | LC_ALL=C sort)
assert_equals "$lab_after" "$lab_before"

fast_output=$(PATH="$test_path" "$cli" serve fixture-model --profile fast --dry-run)
assert_contains "$fast_output" 'artifact verification: requested=cached effective=full'
assert_contains "$fast_output" "$common_hybrid -c 32768 $network_defaults -mm $projector_path --image-min-tokens 1024 $mtp_flags"
assert_count "$fast_output" 'artifact verification:' 1

long_output=$(PATH="$test_path" "$cli" serve fixture-model --profile long --vision off --dry-run)
assert_contains "$long_output" 'artifact verification: requested=cached effective=full'
assert_contains "$long_output" "$common_hybrid -c 262144 $network_defaults"
assert_count "$long_output" 'artifact verification:' 1
[[ "$long_output" != *'spec-'* ]] || fail 'long profile unexpectedly enabled MTP'
[[ "$long_output" != *'-mm '* ]] || fail 'long profile with vision off unexpectedly enabled a projector'

stable_output=$(PATH="$test_path" "$cli" serve fixture-model --profile stable --dry-run)
assert_contains "$stable_output" 'artifact verification: requested=cached effective=full'
assert_contains "$stable_output" "command: $stable_server -m $model_path -ngl all -fit off -fa on -lm mmap -lzm on -c 32768 $network_defaults -mm $projector_path --image-min-tokens 1024"
assert_count "$stable_output" 'artifact verification:' 1

custom_output=$(PATH="$test_path" "$cli" serve fixture-model --profile custom --runtime tuned \
    --mtp dynamic --context 65536 --vision off --dry-run)
assert_contains "$custom_output" 'artifact verification: requested=cached effective=full'
assert_contains "$custom_output" "$common_hybrid -c 65536 $network_defaults $mtp_flags $dynamic_threshold"
assert_count "$custom_output" 'artifact verification:' 1

override_output=$(METAL_LLM_HOST=0.0.0.0 METAL_LLM_PORT=9000 METAL_LLM_PARALLEL=4 \
    PATH="$test_path" "$cli" serve fixture-model --profile fast --dry-run -- --threads 8)
assert_contains "$override_output" 'artifact verification: requested=cached effective=full'
assert_contains "$override_output" "$common_hybrid -c 32768 -np 4 --host 0.0.0.0 --port 9000 -mm $projector_path --image-min-tokens 1024 $mtp_flags --threads 8"
assert_count "$override_output" 'artifact verification:' 1
benign_equals_output=$(PATH="$test_path" "$cli" serve fixture-model --profile long --dry-run -- --threads=8)
assert_contains "$benign_equals_output" '--threads=8'

if removed_profile_output=$(PATH="$test_path" "$cli" serve fixture-model --profile vision --dry-run 2>&1); then
    fail 'serve accepted the removed vision profile'
fi
assert_contains "$removed_profile_output" 'profile vision was removed; select a preset and use --vision on'

if obsolete_context_output=$(METAL_LLM_CONTEXT=4096 PATH="$test_path" "$cli" serve fixture-model --dry-run 2>&1); then
    fail 'serve accepted removed METAL_LLM_CONTEXT'
fi
assert_contains "$obsolete_context_output" 'METAL_LLM_CONTEXT was removed; use --profile custom --runtime RUNTIME --mtp POLICY --context TOKENS'

assert_serve_usage_rejected 'explicit empty profile' --profile ''
assert_serve_usage_rejected 'explicit empty vision' --vision ''
assert_serve_usage_rejected 'explicit empty runtime' --profile custom --runtime '' --mtp off --context 65536
assert_serve_usage_rejected 'explicit empty named-profile runtime override' --profile fast --runtime ''
assert_serve_usage_rejected 'explicit empty MTP policy' --profile custom --runtime tuned --mtp '' --context 65536
assert_serve_usage_rejected 'explicit empty context' --profile custom --runtime tuned --mtp off --context ''
assert_serve_usage_rejected 'missing artifact-check value' --artifact-check
assert_serve_usage_rejected 'duplicate artifact-check option' --artifact-check cached --artifact-check full
assert_serve_usage_rejected 'removed artifact-check off value' --artifact-check off
assert_serve_usage_rejected 'unknown artifact-check value' --artifact-check other
assert_serve_usage_rejected 'artifact-check equals form' --artifact-check=full

assert_serve_usage_rejected 'empty-first duplicate profile' --profile '' --profile fast
assert_serve_usage_rejected 'empty-first duplicate vision' --vision '' --vision off
assert_serve_usage_rejected 'empty-first duplicate runtime' --profile custom --runtime '' --runtime tuned --mtp off --context 65536
assert_serve_usage_rejected 'empty-first duplicate MTP policy' --profile custom --runtime tuned --mtp '' --mtp off --context 65536
assert_serve_usage_rejected 'empty-first duplicate context' --profile custom --runtime tuned --mtp off --context '' --context 65536

for invalid_named_arguments in \
    '--profile fast --runtime tuned' \
    '--profile fast --mtp on' \
    '--profile fast --context 32768'; do
    if named_output=$(PATH="$test_path" "$cli" serve fixture-model ${(z)invalid_named_arguments} --dry-run 2>&1); then
        fail "named profile accepted custom controls: $invalid_named_arguments"
    fi
    assert_contains "$named_output" 'named profiles reject --runtime, --mtp, and --context; use --profile custom'
done

for incomplete_custom_arguments in \
    '--profile custom --mtp off --context 65536' \
    '--profile custom --runtime tuned --context 65536' \
    '--profile custom --runtime tuned --mtp off'; do
    if custom_error_output=$(PATH="$test_path" "$cli" serve fixture-model ${(z)incomplete_custom_arguments} --dry-run 2>&1); then
        fail "serve accepted incomplete custom controls: $incomplete_custom_arguments"
    fi
    assert_contains "$custom_error_output" 'custom requires --runtime tuned|upstream --mtp on|off|dynamic --context TOKENS'
done

for upstream_mtp in on dynamic; do
    if upstream_output=$(PATH="$test_path" "$cli" serve fixture-model --profile custom \
        --runtime upstream --mtp "$upstream_mtp" --context 32768 --dry-run 2>&1); then
        fail "serve accepted upstream runtime with MTP $upstream_mtp"
    fi
    assert_contains "$upstream_output" 'runtime upstream supports only MTP policy off'
done

assert_passthrough_rejected 'short model override' -m other.gguf
assert_passthrough_rejected 'long model equals override' --model=other.gguf
assert_passthrough_rejected 'host override' --host 0.0.0.0
assert_passthrough_rejected 'port equals override' --port=9000
assert_passthrough_rejected 'projector override' -mm other-projector.gguf
assert_passthrough_rejected 'projector equals override' --mmproj=other-projector.gguf
assert_passthrough_rejected 'draft model override' --spec-draft-model other-draft.gguf
assert_passthrough_rejected 'draft count equals override' --spec-draft-n-max=8
assert_passthrough_rejected 'draft GPU override' --spec-draft-ngl all
assert_passthrough_rejected 'draft type override' --spec-type other
assert_passthrough_rejected 'draft threshold override' --spec-draft-max-prompt-tokens 1
assert_passthrough_rejected 'context override' -c 4096
assert_passthrough_rejected 'batch-size override' --batch-size=128
assert_passthrough_rejected 'micro-batch override' -ub 128
assert_passthrough_rejected 'parallel equals override' --parallel=4
assert_passthrough_rejected 'GPU offload override' -ngl 1
assert_passthrough_rejected 'fit override' -fit on
assert_passthrough_rejected 'flash-attention equals override' --flash-attn=off
assert_passthrough_rejected 'vision token override' --image-min-tokens=64
assert_passthrough_rejected 'profile semantic override' --chat-template=other
assert_passthrough_rejected 'option smuggled as a tuning value' --threads -m
assert_passthrough_rejected 'nonpositive tuning value' --threads=0
assert_passthrough_rejected 'positional passthrough value' unexpected-value
assert_passthrough_rejected 'nested option delimiter' --
assert_passthrough_rejected 'lab artifact-check option after passthrough delimiter' --artifact-check full

secret='serve-secret-must-not-leak'
secret_output=$(METAL_LLM_API_KEY="$secret" PATH="$test_path" "$cli" serve fixture-model --profile long --dry-run)
[[ "$secret_output" != *"$secret"* ]] || fail 'dry-run exposed METAL_LLM_API_KEY'
assert_contains "$secret_output" '--api-key <redacted>'

passthrough_secret='passthrough-secret-must-not-leak'
if passthrough_secret_output=$(PATH="$test_path" "$cli" serve fixture-model --profile long --dry-run -- \
    --api-key "$passthrough_secret" 2>&1); then
    fail 'serve accepted a passthrough API key instead of requiring METAL_LLM_API_KEY'
fi
[[ "$passthrough_secret_output" != *"$passthrough_secret"* ]] || fail 'rejection exposed a passthrough API key'
assert_contains "$passthrough_secret_output" 'unsupported serve passthrough option'

export SERVE_TEST_EXEC_LOG="$temporary_root/exec.log"
: > "$SERVE_TEST_ARTIFACT_HASH_LOG"
serve_run_output=$(METAL_LLM_API_KEY="$secret" PATH="$test_path" "$cli" serve fixture-model)
assert_contains "$serve_run_output" 'artifact verification: requested=cached effective=full cache_hits=0 cache_misses=3 full_hashes=3'
assert_count "$serve_run_output" 'artifact verification:' 1
assert_equals "$(wc -l < "$SERVE_TEST_ARTIFACT_HASH_LOG" | tr -d ' ')" 3
for required_path in "$model_path" "$projector_path" "$mtp_path"; do
    assert_count "$(<"$SERVE_TEST_ARTIFACT_HASH_LOG")" "${required_path:A}" 1
done
serve_exec_log=$(command cat "$SERVE_TEST_EXEC_LOG")
assert_contains "$serve_exec_log" "--api-key $secret"

: > "$SERVE_TEST_ARTIFACT_HASH_LOG"
warm_output=$(PATH="$test_path" "$cli" serve fixture-model --dry-run)
assert_contains "$warm_output" 'artifact verification: requested=cached effective=cached cache_hits=3 cache_misses=0 full_hashes=0'
assert_count "$warm_output" 'artifact verification:' 1
[[ ! -s "$SERVE_TEST_ARTIFACT_HASH_LOG" ]] || fail 'warm cached serve hashed a GGUF body'

full_inventory_before=$(find "$fixture_root/.lab" -type f -exec "$real_shasum" -a 256 {} \; | LC_ALL=C sort)
: > "$SERVE_TEST_ARTIFACT_HASH_LOG"
full_output=$(PATH="$test_path" "$cli" serve fixture-model --dry-run --artifact-check full)
assert_contains "$full_output" 'artifact verification: requested=full effective=full cache_hits=0 cache_misses=0 full_hashes=3'
assert_count "$full_output" 'artifact verification:' 1
assert_equals "$(wc -l < "$SERVE_TEST_ARTIFACT_HASH_LOG" | tr -d ' ')" 3
full_inventory_after=$(find "$fixture_root/.lab" -type f -exec "$real_shasum" -a 256 {} \; | LC_ALL=C sort)
assert_equals "$full_inventory_after" "$full_inventory_before"

lease_dir="$managed_tmp/metal-llm-lab/full-model.lease"
lease_record="$lease_dir/identity.json"
[[ -f "$lease_record" ]] || fail 'serve did not publish a managed full-model identity record'
"$real_jq" -e --arg model fixture-model --arg profile auto --arg host 127.0.0.1 --argjson port 8080 '
  (keys | sort) == ([
    "schema_version", "owner_kind", "owner_token", "pid", "process_started_at",
    "model_id", "profile_id", "runtime_alias", "context", "vision", "mtp_policy",
    "mtp_threshold", "runtime_id", "runtime_revision", "runtime_tree_sha",
    "runtime_manifest_sha256", "build_receipt_sha256", "executable_name",
    "executable_sha256", "model_manifest_sha256", "artifacts",
    "artifact_verification", "host", "port"
  ] | sort) and
  .schema_version == 3 and .owner_kind == "serve" and
  .model_id == $model and .profile_id == $profile and
  .runtime_alias == "tuned" and .context == 262144 and .vision == true and
  .mtp_policy == "dynamic" and .mtp_threshold == 32768 and
  .host == $host and .port == $port and
  (.pid | type == "number" and . > 1 and floor == .) and
  (.process_started_at | type == "string" and length > 0) and
  (.runtime_id == "hybrid") and
  (.runtime_revision == "1111111111111111111111111111111111111111") and
  (.runtime_tree_sha | test("^[0-9a-f]{40}$")) and
  (.runtime_manifest_sha256 | test("^[0-9a-f]{64}$")) and
  (.build_receipt_sha256 | test("^[0-9a-f]{64}$")) and
  (.executable_sha256 | test("^[0-9a-f]{64}$")) and
  (.model_manifest_sha256 | test("^[0-9a-f]{64}$")) and
  (.artifacts | type == "array" and map(.id) == ["model", "projector", "mtp"] and
    all(.[].sha256; test("^[0-9a-f]{64}$"))) and
  .artifact_verification == {
    requested_mode: "cached", effective_mode: "full", cache_hits: 0,
    cache_misses: 3, full_hashes: 3,
    receipt_set_sha256: .artifact_verification.receipt_set_sha256
  } and
  (.artifact_verification | keys | sort) == ([
    "requested_mode", "effective_mode", "cache_hits", "cache_misses",
    "full_hashes", "receipt_set_sha256"
  ] | sort) and
  (.artifact_verification.receipt_set_sha256 | test("^[0-9a-f]{64}$"))
' "$lease_record" >/dev/null || fail 'serve published an incomplete managed identity record'

# Old and partially upgraded live records are invalid and must neither be
# replaced nor cause the named process to receive a signal.
cp "$lease_record" "$temporary_root/valid-identity.json"
sleep 60 &!
invalid_identity_pid=$!
for identity_mutation in \
    'del(.runtime_alias, .context, .mtp_policy, .mtp_threshold) | .schema_version = 1' \
    '.schema_version = 2' \
    'del(.mtp_threshold)' \
    'del(.artifact_verification.full_hashes)' \
    '.artifact_verification.unexpected = true' \
    '.artifact_verification.cache_hits = -1' \
    '.artifact_verification.requested_mode = "other"' \
    '.artifact_verification.effective_mode = "other"' \
    '.artifact_verification.receipt_set_sha256 = "BAD"' \
    '.artifact_verification.effective_mode = "cached"' \
    '.artifact_verification.effective_mode = "full" | .artifact_verification.full_hashes = 0' \
    '.artifact_verification.effective_mode = "mixed" | .artifact_verification.cache_hits = 0'; do
    "$real_jq" --argjson pid "$invalid_identity_pid" --arg started "fixture-start-$invalid_identity_pid" \
      "$identity_mutation | .pid = \$pid | .process_started_at = \$started" \
      "$temporary_root/valid-identity.json" > "$lease_record"
    if invalid_identity_output=$(PATH="$test_path" "$cli" serve fixture-model --profile stable 2>&1); then
        kill "$invalid_identity_pid" 2>/dev/null || true
        wait "$invalid_identity_pid" 2>/dev/null || true
        fail 'serve replaced an invalid managed identity that named a live PID'
    fi
    assert_contains "$invalid_identity_output" 'refusing to replace an invalid lease that names a live PID'
    kill -0 "$invalid_identity_pid" 2>/dev/null || fail 'invalid identity recovery signaled the named PID'
done
kill "$invalid_identity_pid" 2>/dev/null || true
wait "$invalid_identity_pid" 2>/dev/null || true
cp "$temporary_root/valid-identity.json" "$lease_record"

# A dead exec owner leaves a stale record; the next managed launch must recover
# it without signaling the recorded PID.
stale_pid=$("$real_jq" -r '.pid' "$lease_record")
METAL_LLM_API_KEY="$secret" PATH="$test_path" "$cli" serve fixture-model --profile stable
new_stale_pid=$("$real_jq" -r '.pid' "$lease_record")
[[ "$new_stale_pid" != "$stale_pid" ]] || fail 'serve did not replace a stale managed lease'

export SERVE_TEST_READY="$temporary_root/server.ready"
SERVE_TEST_HOLD=1 PATH="$test_path" "$cli" serve fixture-model --profile stable &
managed_server_pid=$!
for _ in {1..50}; do
    [[ -f "$SERVE_TEST_READY" && -f "$lease_record" ]] && break
    sleep 0.1
done
[[ -f "$SERVE_TEST_READY" && -f "$lease_record" ]] || fail 'managed fixture server did not start'
if second_output=$(PATH="$test_path" "$cli" serve fixture-model --profile stable 2>&1); then
    kill "$managed_server_pid" 2>/dev/null || true
    wait "$managed_server_pid" 2>/dev/null || true
    fail 'serve allowed a second live managed full-model process'
fi
assert_contains "$second_output" 'managed full-model process is already active'
kill "$managed_server_pid" 2>/dev/null || true
wait "$managed_server_pid" 2>/dev/null || true
rm -f -- "$SERVE_TEST_READY"

# The dead server record is stale and must not prevent a later dry verification
# or normal managed launch.
PATH="$test_path" "$cli" serve fixture-model --profile stable >/dev/null

if invalid_output=$(PATH="$test_path" "$cli" serve fixture-model --profile impossible --dry-run 2>&1); then
    fail 'serve accepted an invalid profile'
fi
assert_contains "$invalid_output" 'profile not found or duplicated: impossible'

hybrid_receipt="$fixture_root/.lab/runtimes/hybrid/build-metal/build-receipt.json"
mv "$hybrid_receipt" "$hybrid_receipt.missing"
if receipt_output=$(PATH="$test_path" "$cli" serve fixture-model --profile long --dry-run 2>&1); then
    fail 'serve accepted a missing build receipt'
fi
assert_contains "$receipt_output" 'build receipt is missing: hybrid'
mv "$hybrid_receipt.missing" "$hybrid_receipt"

cp "$hybrid_receipt" "$hybrid_receipt.saved"
"$real_jq" '.runtime_manifest_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
    "$hybrid_receipt.saved" > "$hybrid_receipt"
if receipt_output=$(PATH="$test_path" "$cli" serve fixture-model --profile long --dry-run 2>&1); then
    fail 'serve accepted a stale build receipt'
fi
assert_contains "$receipt_output" 'build receipt does not match runtime manifest: hybrid'
mv "$hybrid_receipt.saved" "$hybrid_receipt"

hybrid_source="$fixture_root/.lab/runtimes/hybrid/source"
correct_head=$($real_git -C "$hybrid_source" rev-parse HEAD)
print -- 'different clean source tree' > "$hybrid_source/runtime.txt"
"$real_git" -C "$hybrid_source" add runtime.txt
"$real_git" -C "$hybrid_source" -c user.name='Serve Test' -c user.email='serve-test@localhost' \
    commit -qm 'wrong fixture tree'
if tree_output=$(PATH="$test_path" "$cli" serve fixture-model --profile long --dry-run 2>&1); then
    fail 'serve accepted the wrong clean source tree'
fi
assert_contains "$tree_output" 'runtime source tree mismatch for hybrid'
"$real_git" -C "$hybrid_source" checkout -q --detach "$correct_head"

"$real_git" -C "$hybrid_source" update-index --assume-unchanged runtime.txt
print -- 'concealed assume-unchanged modification' > "$hybrid_source/runtime.txt"
if flag_output=$(PATH="$test_path" "$cli" serve fixture-model --profile long --dry-run 2>&1); then
    "$real_git" -C "$hybrid_source" update-index --no-assume-unchanged runtime.txt
    "$real_git" -C "$hybrid_source" checkout -q -- runtime.txt
    fail 'serve accepted a concealed assume-unchanged source modification'
fi
assert_contains "$flag_output" 'unsafe tracked-file index flag'
"$real_git" -C "$hybrid_source" update-index --no-assume-unchanged runtime.txt
"$real_git" -C "$hybrid_source" checkout -q -- runtime.txt

"$real_git" -C "$hybrid_source" update-index --skip-worktree runtime.txt
print -- 'concealed skip-worktree modification' > "$hybrid_source/runtime.txt"
if flag_output=$(PATH="$test_path" "$cli" serve fixture-model --profile long --dry-run 2>&1); then
    "$real_git" -C "$hybrid_source" update-index --no-skip-worktree runtime.txt
    "$real_git" -C "$hybrid_source" checkout -q -- runtime.txt
    fail 'serve accepted a concealed skip-worktree source modification'
fi
assert_contains "$flag_output" 'unsafe tracked-file index flag'
"$real_git" -C "$hybrid_source" update-index --no-skip-worktree runtime.txt
"$real_git" -C "$hybrid_source" checkout -q -- runtime.txt

filter_timestamp_reference="$temporary_root/filter-timestamp-reference"
cp -p "$hybrid_source/filtered.txt" "$filter_timestamp_reference"
"$real_git" -C "$hybrid_source" config core.trustctime false
"$real_git" -C "$hybrid_source" config core.checkstat minimal
print -- conceal-B > "$hybrid_source/filtered.txt"
touch -r "$filter_timestamp_reference" "$hybrid_source/filtered.txt"
[[ -z $("$real_git" -C "$hybrid_source" status --porcelain=v1 --untracked-files=all) ]] || \
    fail 'clean-filter regression did not conceal the raw-byte modification from Git status'
if filter_output=$(PATH="$test_path" "$cli" serve fixture-model --profile long --dry-run 2>&1); then
    rm -f -- "$hybrid_source/filtered.txt"
    "$real_git" -C "$hybrid_source" checkout -q HEAD -- filtered.txt
    fail 'serve accepted raw worktree bytes concealed by a clean filter'
fi
assert_contains "$filter_output" 'runtime source content differs from the index'
rm -f -- "$hybrid_source/filtered.txt"
"$real_git" -C "$hybrid_source" checkout -q HEAD -- filtered.txt

stable_binary="$fixture_root/.lab/runtimes/stable/build-metal/bin/llama-server"
cp "$stable_binary" "$stable_binary.saved"
print -- '# changed' >> "$stable_binary"
if binary_output=$(PATH="$test_path" "$cli" serve fixture-model --profile stable --dry-run 2>&1); then
    fail 'serve accepted a changed server binary'
fi
assert_contains "$binary_output" 'server binary checksum mismatch for stable'
mv "$stable_binary.saved" "$stable_binary"

stable_bench="$fixture_root/.lab/runtimes/stable/build-metal/bin/llama-bench"
cp "$stable_bench" "$stable_bench.saved"
print -- '# changed non-selected binary' >> "$stable_bench"
if binary_output=$(PATH="$test_path" "$cli" serve fixture-model --profile stable --dry-run 2>&1); then
    mv "$stable_bench.saved" "$stable_bench"
    fail 'serve accepted a changed non-selected bench binary'
fi
assert_contains "$binary_output" 'bench binary checksum mismatch for stable'
mv "$stable_bench.saved" "$stable_bench"

mv "$artifact_dir/projector.gguf" "$artifact_dir/projector.gguf.missing"
if missing_output=$(PATH="$test_path" "$cli" serve fixture-model --profile long --vision on --dry-run 2>&1); then
    fail 'serve accepted a missing projector artifact'
fi
assert_contains "$missing_output" 'artifact is missing: projector'
mv "$artifact_dir/projector.gguf.missing" "$artifact_dir/projector.gguf"

print -n -- 'other' > "$artifact_dir/model.gguf"
if checksum_output=$(PATH="$test_path" "$cli" serve fixture-model --profile long --dry-run 2>&1); then
    fail 'serve accepted an artifact with a checksum mismatch'
fi
assert_contains "$checksum_output" 'checksum mismatch for model'

print -- 'serve checks: PASS'
