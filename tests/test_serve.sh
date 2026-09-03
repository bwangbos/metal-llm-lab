#!/bin/zsh
set -euo pipefail

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

assert_contains() {
    local haystack=$1
    local needle=$2
    [[ "$haystack" == *"$needle"* ]] || fail "missing expected output: $needle"
}

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-serve.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT
fixture_root="$temporary_root/repository"
fake_bin="$temporary_root/bin"
mkdir -p "$fixture_root"/{bin,lib,manifests/models,manifests/runtimes,manifests/hardware} \
    "$fake_bin" "$fixture_root/.lab/artifacts/fixture-model"
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
      schema_version: 1,
      id: "fixture-model",
      name: "Fixture Model",
      artifacts: [
        {id: "model", kind: "model", filename: "model.gguf", url: "https://example.invalid/model", bytes: 5, sha256: $model_sha, license_url: "https://example.invalid/license"},
        {id: "projector", kind: "projector", filename: "projector.gguf", url: "https://example.invalid/projector", bytes: 9, sha256: $projector_sha, license_url: "https://example.invalid/license"},
        {id: "mtp", kind: "mtp", filename: "mtp.gguf", url: "https://example.invalid/mtp", bytes: 3, sha256: $mtp_sha, license_url: "https://example.invalid/license"}
      ],
      text_model: {artifact_ids: ["model"], total_bytes: 5},
      profiles: [
        {id: "fast", runtime_id: "hybrid", model_artifact_id: "model", context: 32768,
         vision: {enabled: false, projector_artifact_id: null, image_min_tokens: null},
         mtp: {enabled: true, artifact_id: "mtp", spec_type: "draft-mtp", draft_n_max: 2, gpu_layers: "all"},
         metal: {gpu_layers: "all", fit: false, flash_attention: true, load_mode: "mmap", lazy_mmap: true}},
        {id: "vision", runtime_id: "hybrid", model_artifact_id: "model", context: 32768,
         vision: {enabled: true, projector_artifact_id: "projector", image_min_tokens: 1024},
         mtp: {enabled: true, artifact_id: "mtp", spec_type: "draft-mtp", draft_n_max: 2, gpu_layers: "all"},
         metal: {gpu_layers: "all", fit: false, flash_attention: true, load_mode: "mmap", lazy_mmap: true}},
        {id: "long", runtime_id: "hybrid", model_artifact_id: "model", context: 131072,
         vision: {enabled: false, projector_artifact_id: null, image_min_tokens: null},
         mtp: {enabled: false, artifact_id: null, spec_type: null, draft_n_max: null, gpu_layers: null},
         metal: {gpu_layers: "all", fit: false, flash_attention: true, load_mode: "mmap", lazy_mmap: true}},
        {id: "stable", runtime_id: "stable", model_artifact_id: "model", context: 32768,
         vision: {enabled: false, projector_artifact_id: null, image_min_tokens: null},
         mtp: {enabled: false, artifact_id: null, spec_type: null, draft_n_max: null, gpu_layers: null},
         metal: {gpu_layers: "all", fit: false, flash_attention: true, load_mode: "mmap", lazy_mmap: true}}
      ]
    }' > "$fixture_root/manifests/models/fixture-model.json"

for runtime_id in hybrid stable; do
    runtime_dir="$fixture_root/.lab/runtimes/$runtime_id"
    source_dir="$runtime_dir/source"
    build_dir="$runtime_dir/build-metal"
    mkdir -p "$source_dir" "$build_dir/bin"
    "$real_git" -C "$source_dir" init -q
    print -- "$runtime_id source" > "$source_dir/runtime.txt"
    "$real_git" -C "$source_dir" add runtime.txt
    "$real_git" -C "$source_dir" -c user.name='Serve Test' -c user.email='serve-test@localhost' \
        commit -qm 'fixture runtime'
    source_tree=$($real_git -C "$source_dir" rev-parse 'HEAD^{tree}')
    print -r -- '#!/bin/zsh' > "$build_dir/bin/llama-server"
    print -r -- 'print -r -- "$@" > "$SERVE_TEST_EXEC_LOG"' >> "$build_dir/bin/llama-server"
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
chmod +x "$fake_bin/uname" "$fake_bin/system_profiler"
ln -s "$real_jq" "$fake_bin/jq"
ln -s "$real_shasum" "$fake_bin/shasum"
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

fast_output=$(PATH="$test_path" "$cli" serve fixture-model --profile fast --dry-run)
assert_equals "$fast_output" "$common_hybrid -c 32768 $network_defaults $mtp_flags"

vision_output=$(PATH="$test_path" "$cli" serve fixture-model --profile vision --dry-run)
assert_equals "$vision_output" "$common_hybrid -c 32768 $network_defaults -mm $projector_path --image-min-tokens 1024 $mtp_flags"

long_output=$(PATH="$test_path" "$cli" serve fixture-model --profile long --dry-run)
assert_equals "$long_output" "$common_hybrid -c 131072 $network_defaults"
[[ "$long_output" != *'spec-'* ]] || fail 'long profile unexpectedly enabled MTP'

stable_output=$(PATH="$test_path" "$cli" serve fixture-model --profile stable --dry-run)
assert_equals "$stable_output" "command: $stable_server -m $model_path -ngl all -fit off -fa on -lm mmap -lzm on -c 32768 $network_defaults"

auto_output=$(PATH="$test_path" "$cli" serve fixture-model --profile auto --dry-run)
assert_equals "$auto_output" "$vision_output"

override_output=$(METAL_LLM_HOST=0.0.0.0 METAL_LLM_PORT=9000 METAL_LLM_PARALLEL=4 METAL_LLM_CONTEXT=4096 \
    PATH="$test_path" "$cli" serve fixture-model --profile fast --dry-run -- --threads 8)
assert_equals "$override_output" "$common_hybrid -c 4096 -np 4 --host 0.0.0.0 --port 9000 $mtp_flags --threads 8"

secret='serve-secret-must-not-leak'
secret_output=$(METAL_LLM_API_KEY="$secret" PATH="$test_path" "$cli" serve fixture-model --profile long --dry-run)
[[ "$secret_output" != *"$secret"* ]] || fail 'dry-run exposed METAL_LLM_API_KEY'
assert_contains "$secret_output" '--api-key <redacted>'

passthrough_secret='passthrough-secret-must-not-leak'
passthrough_secret_output=$(PATH="$test_path" "$cli" serve fixture-model --profile long --dry-run -- \
    --api-key "$passthrough_secret")
[[ "$passthrough_secret_output" != *"$passthrough_secret"* ]] || fail 'dry-run exposed a passthrough API key'
assert_contains "$passthrough_secret_output" '--api-key <redacted>'

export SERVE_TEST_EXEC_LOG="$temporary_root/exec.log"
METAL_LLM_API_KEY="$secret" PATH="$test_path" "$cli" serve fixture-model --profile stable
assert_contains "$(<"$SERVE_TEST_EXEC_LOG")" "--api-key $secret"

if invalid_output=$(PATH="$test_path" "$cli" serve fixture-model --profile impossible --dry-run 2>&1); then
    fail 'serve accepted an invalid profile'
fi
assert_contains "$invalid_output" 'profile not found: impossible'

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

stable_binary="$fixture_root/.lab/runtimes/stable/build-metal/bin/llama-server"
cp "$stable_binary" "$stable_binary.saved"
print -- '# changed' >> "$stable_binary"
if binary_output=$(PATH="$test_path" "$cli" serve fixture-model --profile stable --dry-run 2>&1); then
    fail 'serve accepted a changed server binary'
fi
assert_contains "$binary_output" 'server binary checksum mismatch for stable'
mv "$stable_binary.saved" "$stable_binary"

mv "$artifact_dir/projector.gguf" "$artifact_dir/projector.gguf.missing"
if missing_output=$(PATH="$test_path" "$cli" serve fixture-model --profile vision --dry-run 2>&1); then
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
