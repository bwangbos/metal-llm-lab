#!/bin/zsh
set -euo pipefail

source_root=${0:A:h:h}
real_curl=$(command -v curl)
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

assert_count() {
    local haystack=$1
    local needle=$2
    local expected=$3
    local actual
    actual=$(print -r -- "$haystack" | /usr/bin/grep -F -c -- "$needle" || true)
    (( actual == expected )) || fail "expected $expected occurrences of '$needle', got $actual"
}

assert_setup_usage_rejected() {
    local description=$1
    shift
    local output exit_status
    if output=$(PATH="$test_path" "$fixture_root/bin/metal-llm" setup "$@" 2>&1); then
        fail "setup accepted $description"
    else
        exit_status=$?
    fi
    (( exit_status == 2 )) || fail "setup rejected $description with status $exit_status, expected 2"
    assert_contains "$output" 'usage: metal-llm setup MODEL [--artifact-check cached|full] [--dry-run] [--yes]'
}

inventory_lab() {
    local item relative metadata digest
    while IFS= read -r item; do
        relative=${item#"$fixture_root/.lab/"}
        if [[ -f "$item" && ! -L "$item" ]]; then
            metadata=$(/usr/bin/stat -f '%u:%Lp:%z' "$item") || return 1
            digest=$($real_shasum -a 256 "$item" | awk '{print $1}') || return 1
            print -r -- "file:$relative:$metadata:$digest"
        elif [[ -d "$item" && ! -L "$item" ]]; then
            metadata=$(/usr/bin/stat -f '%u:%Lp' "$item") || return 1
            print -r -- "directory:$relative:$metadata"
        elif [[ -L "$item" ]]; then
            print -r -- "symlink:$relative:$(/bin/readlink "$item")"
        fi
    done < <(/usr/bin/find "$fixture_root/.lab" -print | /usr/bin/sort)
}

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-setup.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT
fixture_root="$temporary_root/repository"
fake_bin="$temporary_root/bin"
source_artifact="$temporary_root/tiny-model.gguf"
mkdir -p "$fixture_root"/{bin,lib,scripts,manifests/models,manifests/runtimes} "$fake_bin"
cp "$source_root/bin/metal-llm" "$fixture_root/bin/metal-llm"
cp "$source_root/lib"/*.zsh "$fixture_root/lib/"
print -n -- 'tiny model artifact for setup tests' > "$source_artifact"
artifact_bytes=$(wc -c < "$source_artifact" | tr -d ' ')
artifact_sha=$($real_shasum -a 256 "$source_artifact" | awk '{print $1}')

write_model_manifest() {
    local expected_bytes=$1
    local expected_sha=$2
    local destination=${3:-$fixture_root/manifests/models/fixture-model.json}

    "$real_jq" -n \
        --arg url "file://$source_artifact" \
        --arg sha "$expected_sha" \
        --argjson bytes "$expected_bytes" '
        {
            schema_version: 1,
            id: "fixture-model",
            name: "Fixture Model",
            artifacts: [{
                id: "fixture-artifact",
                kind: "model",
                filename: "fixture.gguf",
                url: $url,
                bytes: $bytes,
                sha256: $sha,
                license_url: "https://example.invalid/license"
            }],
            text_model: {
                artifact_ids: ["fixture-artifact"],
                total_bytes: $bytes
            },
            profiles: [{
                id: "fast",
                runtime_id: "fixture-runtime",
                model_artifact_id: "fixture-artifact",
                context: 128,
                vision: {enabled: false, projector_artifact_id: null, image_min_tokens: null},
                mtp: {enabled: false, artifact_id: null, spec_type: null, draft_n_max: null, gpu_layers: null},
                metal: {gpu_layers: "all", fit: false, flash_attention: true, load_mode: "mmap", lazy_mmap: true}
            }, {
                id: "long",
                runtime_id: "fixture-runtime",
                model_artifact_id: "fixture-artifact",
                context: 256,
                vision: {enabled: false, projector_artifact_id: null, image_min_tokens: null},
                mtp: {enabled: false, artifact_id: null, spec_type: null, draft_n_max: null, gpu_layers: null},
                metal: {gpu_layers: "all", fit: false, flash_attention: true, load_mode: "mmap", lazy_mmap: true}
            }, {
                id: "stable",
                runtime_id: "fixture-stable",
                model_artifact_id: "fixture-artifact",
                context: 128,
                vision: {enabled: false, projector_artifact_id: null, image_min_tokens: null},
                mtp: {enabled: false, artifact_id: null, spec_type: null, draft_n_max: null, gpu_layers: null},
                metal: {gpu_layers: "all", fit: false, flash_attention: true, load_mode: "mmap", lazy_mmap: true}
            }]
        }' > "$destination"
}

cat > "$fixture_root/manifests/runtimes/fixture-runtime.json" <<'EOF'
{
  "schema_version": 1,
  "id": "fixture-runtime",
  "repository": "https://example.invalid/runtime.git",
  "base_revision": "1111111111111111111111111111111111111111",
  "patches": [],
  "tested_revision": "1111111111111111111111111111111111111111",
  "tested_tree_sha": "2222222222222222222222222222222222222222",
  "build": {
    "generator": "Ninja",
    "build_type": "Release",
    "architecture": "arm64",
    "cmake_options": {
      "CMAKE_BUILD_TYPE": "Release",
      "CMAKE_OSX_ARCHITECTURES": "arm64",
      "GGML_METAL": "ON"
    },
    "targets": ["llama-server", "llama-bench"]
  }
}
EOF
"$real_jq" '.id = "fixture-stable"' "$fixture_root/manifests/runtimes/fixture-runtime.json" > \
    "$fixture_root/manifests/runtimes/fixture-stable.json"

cat > "$fixture_root/scripts/runtime-sync.zsh" <<EOF
#!/bin/zsh
set -eu
runtime_id=\$1
print -r -- "runtime-sync \$*"
[[ " \$* " == *' --dry-run '* ]] && exit 0
mkdir -p '$fixture_root/.lab/runtimes/'"\$runtime_id"'/source/.git'
print -r -- "\$*" >> '$temporary_root/runtime-sync.log'
EOF
chmod +x "$fixture_root/scripts/runtime-sync.zsh"

ln -s "$real_curl" "$fake_bin/curl"
ln -s "$real_jq" "$fake_bin/jq"

cat > "$fake_bin/shasum" <<EOF
#!/bin/zsh
set -eu
for argument in "\$@"; do
    case "\$argument" in
        *.gguf|*.gguf.part) print -r -- "\$argument" >> "\${SETUP_TEST_ARTIFACT_HASH_LOG:?}" ;;
    esac
done
exec "$real_shasum" "\$@"
EOF

cat > "$fake_bin/git" <<'EOF'
#!/bin/zsh
set -eu
while (( $# > 0 )); do
    case "$1" in
        -C) shift 2 ;;
        rev-parse)
            if [[ "$2" == '--git-dir' ]]; then
                print -- '.git'
            else
                print -- '2222222222222222222222222222222222222222'
            fi
            exit 0
            ;;
        status|ls-files|diff-index|diff-files) exit 0 ;;
        *) exit 2 ;;
    esac
done
EOF

cat > "$fake_bin/cmake" <<EOF
#!/bin/zsh
set -eu
print -r -- "\$*" >> '$temporary_root/cmake.log'
if [[ "\$1" == '--build' ]]; then
    build_dir=\$2
    mkdir -p "\$build_dir/bin"
    ln -sf '$fake_bin/smoke-executable' "\$build_dir/bin/llama-server"
    ln -sf '$fake_bin/smoke-executable' "\$build_dir/bin/llama-bench"
fi
EOF

cat > "$fake_bin/smoke-executable" <<'EOF'
#!/bin/zsh
print -r -- "${0:t} $*" >> "$SETUP_TEST_SMOKE_LOG"
[[ "${SETUP_TEST_SMOKE_FAIL:-}" != "${0:t}" ]]
EOF

cat > "$fake_bin/uname" <<'EOF'
#!/bin/zsh
case "$1" in
    -s) print -- "${SETUP_TEST_OS:-Darwin}" ;;
    -m) print -- "${SETUP_TEST_ARCH:-arm64}" ;;
    *) exit 2 ;;
esac
EOF

cat > "$fake_bin/df" <<'EOF'
#!/bin/zsh
print -- 'Filesystem 1024-blocks Used Available Capacity Mounted on'
print -- "/dev/test 20000000 1 ${SETUP_TEST_BLOCKS:-10000000} 1% /"
EOF
chmod +x "$fake_bin/cmake" "$fake_bin/smoke-executable" "$fake_bin/uname" "$fake_bin/df" "$fake_bin/git" "$fake_bin/shasum"

test_path="$fake_bin:/bin:/usr/bin"
export SETUP_TEST_SMOKE_LOG="$temporary_root/smoke.log"
export SETUP_TEST_ARTIFACT_HASH_LOG="$temporary_root/artifact-hashes.log"
: > "$SETUP_TEST_ARTIFACT_HASH_LOG"
write_model_manifest "$artifact_bytes" "$artifact_sha"
dry_manifest="$fixture_root/manifests/models/dry-model.json"
"$real_jq" '
    .id = "dry-model" |
    .artifacts += [(.artifacts[0] |
        .id = "fixture-artifact-two" |
        .filename = "fixture-two.gguf")]
' "$fixture_root/manifests/models/fixture-model.json" > "$dry_manifest"

assert_setup_usage_rejected 'missing value' fixture-model --artifact-check
assert_setup_usage_rejected 'disabled verification' fixture-model --artifact-check off
assert_setup_usage_rejected 'equals form' fixture-model --artifact-check=full
assert_setup_usage_rejected 'duplicate' fixture-model --artifact-check cached --artifact-check full

if unsupported_output=$(SETUP_TEST_ARCH=x86_64 PATH="$test_path" "$fixture_root/bin/metal-llm" setup fixture-model --yes 2>&1); then
    fail 'setup accepted an unsupported architecture'
fi
assert_contains "$unsupported_output" 'unsupported architecture: x86_64 (requires arm64)'
[[ ! -e "$fixture_root/.lab" ]] || fail 'unsupported-host rejection created .lab state'
[[ ! -e "$temporary_root/runtime-sync.log" ]] || fail 'unsupported-host rejection synchronized the runtime'
[[ ! -e "$temporary_root/cmake.log" ]] || fail 'unsupported-host rejection invoked CMake'

if unsupported_output=$(SETUP_TEST_OS=Linux PATH="$test_path" "$fixture_root/bin/metal-llm" setup fixture-model --yes 2>&1); then
    fail 'setup accepted an unsupported operating system'
fi
assert_contains "$unsupported_output" 'unsupported operating system: Linux (requires macOS)'
[[ ! -e "$fixture_root/.lab" ]] || fail 'unsupported-OS rejection created .lab state'
[[ ! -e "$temporary_root/runtime-sync.log" ]] || fail 'unsupported-OS rejection synchronized the runtime'
[[ ! -e "$temporary_root/cmake.log" ]] || fail 'unsupported-OS rejection invoked CMake'

runtime_manifest="$fixture_root/manifests/runtimes/fixture-runtime.json"
cp "$runtime_manifest" "$runtime_manifest.saved"
"$real_jq" '.tested_revision = "3333333333333333333333333333333333333333"' \
    "$runtime_manifest.saved" > "$runtime_manifest"
if runtime_linkage_output=$(PATH="$test_path" "$fixture_root/bin/metal-llm" setup fixture-model --dry-run 2>&1); then
    mv "$runtime_manifest.saved" "$runtime_manifest"
    fail 'setup accepted a patchless runtime whose tested revision differs from its base revision'
fi
mv "$runtime_manifest.saved" "$runtime_manifest"
assert_contains "$runtime_linkage_output" 'invalid runtime manifest'
[[ ! -e "$fixture_root/.lab" ]] || fail 'invalid runtime linkage created .lab state'

dry_output=$(HF_TOKEN='secret-token-must-not-leak' PATH="$test_path" "$fixture_root/bin/metal-llm" setup dry-model --dry-run)
assert_contains "$dry_output" 'runtime-sync fixture-runtime --dry-run'
assert_contains "$dry_output" 'runtime-sync fixture-stable --dry-run'
assert_count "$dry_output" 'runtime-sync fixture-runtime --dry-run' 1
assert_contains "$dry_output" 'configure runtime: fixture-runtime'
assert_contains "$dry_output" 'configure runtime: fixture-stable'
assert_count "$dry_output" 'configure runtime: fixture-runtime' 1
assert_contains "$dry_output" 'build targets: llama-server llama-bench'
assert_contains "$dry_output" 'smoke test executable: llama-server --help'
assert_contains "$dry_output" 'smoke test executable: llama-bench --help'
assert_contains "$dry_output" 'build reserve bytes: 5368709120'
assert_contains "$dry_output" 'download artifact: fixture-artifact'
assert_contains "$dry_output" 'download artifact: fixture-artifact-two'
assert_contains "$dry_output" 'verify bytes:'
assert_contains "$dry_output" 'verify sha256:'
assert_contains "$dry_output" 'publish artifact atomically:'
assert_contains "$dry_output" 'write build receipt atomically:'
assert_contains "$dry_output" 'artifact verification: requested=cached effective=not-run cache_hits=0 cache_misses=0 full_hashes=0'
[[ "$dry_output" != *'secret-token-must-not-leak'* ]] || fail 'dry-run exposed HF_TOKEN'
[[ ! -e "$fixture_root/.lab" ]] || fail 'dry-run created .lab state'

dry_artifact_dir="$fixture_root/.lab/artifacts/fixture-model"
dry_final_artifact="$dry_artifact_dir/fixture.gguf"
dry_receipt_dir="$fixture_root/.lab/verification/artifacts/fixture-model"
mkdir -p "$dry_artifact_dir" "$dry_receipt_dir"
cp "$source_artifact" "$dry_final_artifact"
chmod 700 "$fixture_root/.lab/verification/artifacts" "$dry_receipt_dir"
print -r -- '{"stale":true}' > "$dry_receipt_dir/fixture-artifact.json"
chmod 600 "$dry_receipt_dir/fixture-artifact.json"
dry_inventory_before="$temporary_root/dry-inventory-before"
dry_inventory_after="$temporary_root/dry-inventory-after"
inventory_lab > "$dry_inventory_before"
: > "$SETUP_TEST_ARTIFACT_HASH_LOG"
dry_existing_output=$(PATH="$test_path" "$fixture_root/bin/metal-llm" setup fixture-model --dry-run)
assert_contains "$dry_existing_output" 'artifact verification: requested=cached effective=full cache_hits=0 cache_misses=1 full_hashes=1'
dry_hash_count=$(wc -l < "$SETUP_TEST_ARTIFACT_HASH_LOG" | tr -d ' ')
(( dry_hash_count == 1 )) || fail 'dry-run did not read exactly one GGUF body'
[[ "$(/usr/bin/tail -n 1 "$SETUP_TEST_ARTIFACT_HASH_LOG")" == "${dry_final_artifact:A}" ]] ||
    fail 'dry-run did not read the existing final GGUF body'
inventory_lab > "$dry_inventory_after"
cmp -s "$dry_inventory_before" "$dry_inventory_after" || fail 'dry-run changed existing .lab state'
rm -rf "$fixture_root/.lab"

cp "$source_root/manifests/models/qwen3.8-flash-next.json" "$fixture_root/manifests/models/"
cp "$source_root/manifests/runtimes/llama-cpp-qwen38-hybrid.json" "$fixture_root/manifests/runtimes/"
cp "$source_root/manifests/runtimes/llama-cpp-upstream-stable.json" "$fixture_root/manifests/runtimes/"
real_dry_output=$(SETUP_TEST_BLOCKS=200000000 PATH="$test_path" \
    "$fixture_root/bin/metal-llm" setup qwen3.8-flash-next --dry-run)
assert_contains "$real_dry_output" 'default profile: auto'
assert_count "$real_dry_output" 'runtime-sync llama-cpp-qwen38-hybrid --dry-run' 1
assert_count "$real_dry_output" 'runtime-sync llama-cpp-upstream-stable --dry-run' 1
assert_count "$real_dry_output" 'configure runtime:' 2
assert_count "$real_dry_output" 'download artifact:' 35
assert_count "$real_dry_output" 'verify bytes:' 35
assert_count "$real_dry_output" 'verify sha256:' 35
assert_count "$real_dry_output" 'publish artifact atomically:' 35
assert_contains "$real_dry_output" 'artifact verification: requested=cached effective=not-run cache_hits=0 cache_misses=0 full_hashes=0'
[[ "$real_dry_output" != *'recommended_profile'* ]] ||
  fail 'v2 dry-run mentioned removed hardware profile selection'
[[ ! -e "$fixture_root/.lab" ]] || fail 'v2 dry-run created .lab state'

if smoke_output=$(SETUP_TEST_SMOKE_FAIL=llama-server METAL_LLM_BUILD_RESERVE_BYTES=1000 \
    SETUP_TEST_BLOCKS=2 PATH="$test_path" "$fixture_root/bin/metal-llm" setup fixture-model --yes 2>&1); then
    fail 'setup accepted a failing runtime smoke test'
fi
assert_contains "$smoke_output" 'smoke test failed: llama-server'
[[ "$(<"$temporary_root/smoke.log")" == 'llama-server --help' ]] || fail 'smoke failure did not stop at the failing executable'
[[ ! -e "$fixture_root/.lab/artifacts" ]] || fail 'smoke failure started artifact acquisition'

rm -rf "$fixture_root/.lab"
rm -f "$temporary_root/runtime-sync.log" "$temporary_root/cmake.log" "$temporary_root/smoke.log"
artifact_dir="$fixture_root/.lab/artifacts/fixture-model"
final_artifact="$artifact_dir/fixture.gguf"
part_artifact="$final_artifact.part"
mkdir -p "$artifact_dir"
/usr/bin/head -c 12 "$source_artifact" > "$part_artifact"
remaining_after_partial=$(( artifact_bytes - 12 ))
success_output=$(HF_TOKEN='normal-secret-must-not-leak' METAL_LLM_BUILD_RESERVE_BYTES=1000 SETUP_TEST_BLOCKS=1 \
    PATH="$test_path" "$fixture_root/bin/metal-llm" setup fixture-model --yes)
[[ "$success_output" != *'normal-secret-must-not-leak'* ]] || fail 'normal setup exposed HF_TOKEN'
assert_contains "$success_output" "remaining artifact bytes: $remaining_after_partial"
assert_contains "$success_output" "total required disk bytes: $(( remaining_after_partial + 1000 ))"
assert_contains "$success_output" $'artifact: fixture-artifact\nsource: file://'
assert_contains "$success_output" $'license: https://example.invalid/license\nexpected bytes:'
assert_contains "$success_output" 'resuming artifact: fixture-artifact'
assert_contains "$success_output" 'artifact verification: requested=cached effective=full cache_hits=0 cache_misses=0 full_hashes=1'
assert_contains "$success_output" './bin/metal-llm serve fixture-model --profile auto'
[[ -f "$final_artifact" ]] || fail 'verified artifact was not published'
[[ ! -e "$part_artifact" ]] || fail 'successful setup left a partial artifact'
[[ $(wc -c < "$final_artifact" | tr -d ' ') == "$artifact_bytes" ]] || fail 'published artifact has wrong byte count'
[[ $($real_shasum -a 256 "$final_artifact" | awk '{print $1}') == "$artifact_sha" ]] || fail 'published artifact has wrong checksum'
artifact_receipt="$fixture_root/.lab/verification/artifacts/fixture-model/fixture-artifact.json"
"$real_jq" -e --arg final_path "${final_artifact:A}" '
    .canonical_path == $final_path and .artifact_id == "fixture-artifact"
' "$artifact_receipt" >/dev/null || fail 'artifact receipt does not name the final artifact'
assert_contains "$(<"$temporary_root/cmake.log")" '-G Ninja'
assert_contains "$(<"$temporary_root/cmake.log")" '-DGGML_METAL=ON'
assert_contains "$(<"$temporary_root/cmake.log")" '--target llama-server llama-bench'
assert_count "$(<"$temporary_root/cmake.log")" '--target llama-server llama-bench' 2
assert_contains "$(<"$temporary_root/smoke.log")" 'llama-server --help'
assert_contains "$(<"$temporary_root/smoke.log")" 'llama-bench --help'
for runtime_id in fixture-runtime fixture-stable; do
    receipt="$fixture_root/.lab/runtimes/$runtime_id/build-metal/build-receipt.json"
    [[ -f "$receipt" ]] || fail "setup did not write receipt for $runtime_id"
    [[ ! -e "$receipt.part" ]] || fail "setup left a partial receipt for $runtime_id"
    "$real_jq" -e --arg id "$runtime_id" '
        .schema_version == 1 and .runtime_id == $id and
        .tested_revision == "1111111111111111111111111111111111111111" and
        .source_tree_sha == "2222222222222222222222222222222222222222" and
        .tested_tree_sha == "2222222222222222222222222222222222222222" and
        (.runtime_manifest_sha256 | test("^[0-9a-f]{64}$")) and
        (.binaries["llama-server"].sha256 | test("^[0-9a-f]{64}$")) and
        (.binaries["llama-bench"].sha256 | test("^[0-9a-f]{64}$"))
    ' "$receipt" >/dev/null || fail "invalid build receipt for $runtime_id"
done

rm "$source_artifact"
: > "$SETUP_TEST_ARTIFACT_HASH_LOG"
reuse_output=$(METAL_LLM_BUILD_RESERVE_BYTES=1024 SETUP_TEST_BLOCKS=1 \
    PATH="$test_path" "$fixture_root/bin/metal-llm" setup fixture-model --yes)
assert_contains "$reuse_output" 'remaining artifact bytes: 0'
assert_contains "$reuse_output" 'total required disk bytes: 1024'
assert_contains "$reuse_output" $'artifact: fixture-artifact\nsource: file://'
assert_contains "$reuse_output" $'license: https://example.invalid/license\nexpected bytes:'
assert_contains "$reuse_output" 'using verified artifact: fixture-artifact'
assert_contains "$reuse_output" 'artifact verification: requested=cached effective=cached cache_hits=1 cache_misses=0 full_hashes=0'
[[ ! -s "$SETUP_TEST_ARTIFACT_HASH_LOG" ]] || fail 'warm cached setup hashed a GGUF body'

: > "$SETUP_TEST_ARTIFACT_HASH_LOG"
full_output=$(METAL_LLM_BUILD_RESERVE_BYTES=1024 SETUP_TEST_BLOCKS=1 \
    PATH="$test_path" "$fixture_root/bin/metal-llm" setup fixture-model --yes --artifact-check full)
assert_contains "$full_output" 'artifact verification: requested=full effective=full cache_hits=0 cache_misses=0 full_hashes=1'
full_hash_count=$(wc -l < "$SETUP_TEST_ARTIFACT_HASH_LOG" | tr -d ' ')
(( full_hash_count == 1 )) || fail 'full setup did not read exactly one GGUF body'
[[ "$(/usr/bin/tail -n 1 "$SETUP_TEST_ARTIFACT_HASH_LOG")" == "${final_artifact:A}" ]] ||
    fail 'full setup did not read the final GGUF body'

rm -rf "$fixture_root/.lab"
print -n -- 'tiny model artifact for setup tests' > "$source_artifact"
write_model_manifest "$(( artifact_bytes + 1 ))" "$artifact_sha"
if size_output=$(PATH="$test_path" "$fixture_root/bin/metal-llm" setup fixture-model --yes 2>&1); then
    fail 'setup accepted an artifact with the wrong byte count'
fi
assert_contains "$size_output" 'byte count mismatch for fixture-artifact'
[[ ! -e "$final_artifact" ]] || fail 'byte-count failure published an artifact'
[[ -f "$part_artifact" ]] || fail 'byte-count failure did not retain the partial download'

rm -rf "$fixture_root/.lab"
write_model_manifest "$artifact_bytes" 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
if checksum_output=$(PATH="$test_path" "$fixture_root/bin/metal-llm" setup fixture-model --yes 2>&1); then
    fail 'setup accepted a checksum mismatch'
fi
assert_contains "$checksum_output" 'checksum mismatch for fixture-artifact'
[[ ! -e "$final_artifact" ]] || fail 'checksum failure published an artifact'
[[ -f "$part_artifact" ]] || fail 'checksum failure did not retain the partial download'

rm -rf "$fixture_root/.lab"
rm -f "$temporary_root/runtime-sync.log" "$temporary_root/cmake.log" "$temporary_root/smoke.log"
write_model_manifest "$artifact_bytes" "$artifact_sha"
if disk_output=$(METAL_LLM_BUILD_RESERVE_BYTES=1000 SETUP_TEST_BLOCKS=1 \
    PATH="$test_path" "$fixture_root/bin/metal-llm" setup fixture-model --yes 2>&1); then
    fail 'setup accepted insufficient disk space'
fi
assert_contains "$disk_output" 'insufficient disk space'
assert_contains "$disk_output" "remaining artifact bytes: $artifact_bytes"
assert_contains "$disk_output" "total required disk bytes: $(( artifact_bytes + 1000 ))"
[[ ! -e "$fixture_root/.lab" ]] || fail 'disk-space rejection created .lab state'
[[ ! -e "$temporary_root/runtime-sync.log" ]] || fail 'disk-space rejection synchronized the runtime'
[[ ! -e "$temporary_root/cmake.log" ]] || fail 'disk-space rejection invoked CMake'

bad_manifest="$fixture_root/manifests/models/broken-model.json"
print -r -- '{"schema_version":1,"id":"broken-model"}' > "$bad_manifest"
if manifest_output=$(PATH="$test_path" "$fixture_root/bin/metal-llm" setup broken-model --yes 2>&1); then
    fail 'setup accepted an invalid model manifest'
fi
assert_contains "$manifest_output" 'invalid model manifest'
[[ ! -e "$fixture_root/.lab" ]] || fail 'manifest rejection created .lab state'

print -- 'setup checks: PASS'
