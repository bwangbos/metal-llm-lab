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

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-setup.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT
fixture_root="$temporary_root/repository"
fake_bin="$temporary_root/bin"
source_artifact="$temporary_root/tiny-model.gguf"
mkdir -p "$fixture_root"/{bin,lib,scripts,manifests/models,manifests/runtimes} "$fake_bin"
cp "$source_root/bin/metal-llm" "$fixture_root/bin/metal-llm"
cp "$source_root/lib/common.zsh" "$source_root/lib/setup.zsh" "$source_root/lib/doctor.zsh" \
    "$source_root/lib/serve.zsh" "$fixture_root/lib/"
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

cat > "$fixture_root/scripts/runtime-sync.zsh" <<EOF
#!/bin/zsh
set -eu
print -r -- "runtime-sync \$*"
[[ " \$* " == *' --dry-run '* ]] && exit 0
mkdir -p '$fixture_root/.lab/runtimes/fixture-runtime/source'
print -r -- "\$*" >> '$temporary_root/runtime-sync.log'
EOF
chmod +x "$fixture_root/scripts/runtime-sync.zsh"

ln -s "$real_curl" "$fake_bin/curl"
ln -s "$real_jq" "$fake_bin/jq"
ln -s "$real_shasum" "$fake_bin/shasum"

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
chmod +x "$fake_bin/cmake" "$fake_bin/smoke-executable" "$fake_bin/uname" "$fake_bin/df"

test_path="$fake_bin:/bin:/usr/bin"
export SETUP_TEST_SMOKE_LOG="$temporary_root/smoke.log"
write_model_manifest "$artifact_bytes" "$artifact_sha"
dry_manifest="$fixture_root/manifests/models/dry-model.json"
"$real_jq" '
    .id = "dry-model" |
    .artifacts += [(.artifacts[0] |
        .id = "fixture-artifact-two" |
        .filename = "fixture-two.gguf")]
' "$fixture_root/manifests/models/fixture-model.json" > "$dry_manifest"

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

dry_output=$(HF_TOKEN='secret-token-must-not-leak' PATH="$test_path" "$fixture_root/bin/metal-llm" setup dry-model --dry-run)
assert_contains "$dry_output" 'runtime-sync fixture-runtime --dry-run'
assert_contains "$dry_output" 'configure runtime: fixture-runtime'
assert_contains "$dry_output" 'build targets: llama-server llama-bench'
assert_contains "$dry_output" 'smoke test executable: llama-server --help'
assert_contains "$dry_output" 'smoke test executable: llama-bench --help'
assert_contains "$dry_output" 'build reserve bytes: 5368709120'
assert_contains "$dry_output" 'download artifact: fixture-artifact'
assert_contains "$dry_output" 'download artifact: fixture-artifact-two'
assert_contains "$dry_output" 'verify bytes:'
assert_contains "$dry_output" 'verify sha256:'
assert_contains "$dry_output" 'publish artifact atomically:'
[[ "$dry_output" != *'secret-token-must-not-leak'* ]] || fail 'dry-run exposed HF_TOKEN'
[[ ! -e "$fixture_root/.lab" ]] || fail 'dry-run created .lab state'

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
assert_contains "$success_output" './bin/metal-llm serve fixture-model --profile auto'
[[ -f "$final_artifact" ]] || fail 'verified artifact was not published'
[[ ! -e "$part_artifact" ]] || fail 'successful setup left a partial artifact'
[[ $(wc -c < "$final_artifact" | tr -d ' ') == "$artifact_bytes" ]] || fail 'published artifact has wrong byte count'
[[ $($real_shasum -a 256 "$final_artifact" | awk '{print $1}') == "$artifact_sha" ]] || fail 'published artifact has wrong checksum'
assert_contains "$(<"$temporary_root/cmake.log")" '-G Ninja'
assert_contains "$(<"$temporary_root/cmake.log")" '-DGGML_METAL=ON'
assert_contains "$(<"$temporary_root/cmake.log")" '--target llama-server llama-bench'
assert_contains "$(<"$temporary_root/smoke.log")" 'llama-server --help'
assert_contains "$(<"$temporary_root/smoke.log")" 'llama-bench --help'

rm "$source_artifact"
reuse_output=$(METAL_LLM_BUILD_RESERVE_BYTES=1024 SETUP_TEST_BLOCKS=1 \
    PATH="$test_path" "$fixture_root/bin/metal-llm" setup fixture-model --yes)
assert_contains "$reuse_output" 'remaining artifact bytes: 0'
assert_contains "$reuse_output" 'total required disk bytes: 1024'
assert_contains "$reuse_output" $'artifact: fixture-artifact\nsource: file://'
assert_contains "$reuse_output" $'license: https://example.invalid/license\nexpected bytes:'
assert_contains "$reuse_output" 'using verified artifact: fixture-artifact'

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
