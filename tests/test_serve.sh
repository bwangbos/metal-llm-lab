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
benign_equals_output=$(PATH="$test_path" "$cli" serve fixture-model --profile long --dry-run -- --threads=8)
assert_contains "$benign_equals_output" '--threads=8'

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
METAL_LLM_API_KEY="$secret" PATH="$test_path" "$cli" serve fixture-model --profile stable
serve_exec_log=$(command cat "$SERVE_TEST_EXEC_LOG")
assert_contains "$serve_exec_log" "--api-key $secret"

lease_dir="$managed_tmp/metal-llm-lab/full-model.lease"
lease_record="$lease_dir/identity.json"
[[ -f "$lease_record" ]] || fail 'serve did not publish a managed full-model identity record'
"$real_jq" -e --arg model fixture-model --arg profile stable --arg host 127.0.0.1 --argjson port 8080 '
  .schema_version == 1 and .owner_kind == "serve" and
  .model_id == $model and .profile_id == $profile and
  .host == $host and .port == $port and
  (.pid | type == "number" and . > 1 and floor == .) and
  (.process_started_at | type == "string" and length > 0) and
  (.runtime_id == "stable") and
  (.runtime_revision == "1111111111111111111111111111111111111111") and
  (.runtime_tree_sha | test("^[0-9a-f]{40}$")) and
  (.runtime_manifest_sha256 | test("^[0-9a-f]{64}$")) and
  (.build_receipt_sha256 | test("^[0-9a-f]{64}$")) and
  (.executable_sha256 | test("^[0-9a-f]{64}$")) and
  (.model_manifest_sha256 | test("^[0-9a-f]{64}$")) and
  (.artifacts | type == "array" and length == 1 and .[0].id == "model" and
    (.[0].sha256 | test("^[0-9a-f]{64}$")))
' "$lease_record" >/dev/null || fail 'serve published an incomplete managed identity record'

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
