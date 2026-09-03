#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
sync_script="$root/scripts/runtime-sync.zsh"
runtime_id=llama-cpp-qwen38-hybrid

fail() {
    print -u2 -- "$1"
    exit 1
}

assert_contains() {
    local haystack=$1
    local needle=$2
    [[ "$haystack" == *"$needle"* ]] || fail "missing expected output: $needle"
}

write_manifest() {
    local destination=$1
    local id=$2
    local repository=$3
    local base_revision=$4
    local patches_json=$5
    local tested_revision=$6
    local tested_tree=$7

    jq -n \
        --arg id "$id" \
        --arg repository "$repository" \
        --arg base_revision "$base_revision" \
        --argjson patches "$patches_json" \
        --arg tested_revision "$tested_revision" \
        --arg tested_tree "$tested_tree" \
        '{
            schema_version: 1,
            id: $id,
            repository: $repository,
            base_revision: $base_revision,
            patches: $patches,
            tested_revision: $tested_revision,
            tested_tree_sha: $tested_tree,
            build: {
                generator: "Ninja",
                build_type: "Release",
                architecture: "arm64",
                cmake_options: {GGML_METAL: "ON"},
                targets: ["fixture"]
            }
        }' > "$destination"
}

[[ -x "$sync_script" ]] || fail "missing executable scripts/runtime-sync.zsh"
grep -Fqx '0013-server-gate-mtp-by-effective-prompt.patch' \
    "$root/patches/llama.cpp/qwen3.8-hybrid/series" || \
    fail 'missing dynamic MTP patch from tuned runtime series'
patch_13="$root/patches/llama.cpp/qwen3.8-hybrid/0013-server-gate-mtp-by-effective-prompt.patch"
grep -Fq -- '--spec-draft-max-prompt-tokens' "$patch_13" || \
    fail 'dynamic MTP patch is missing the server option'
grep -Fq 'effective_prompt_tokens' "$patch_13" || \
    fail 'dynamic MTP patch is missing effective prompt accounting'
grep -Fq 'speculative_threshold' "$patch_13" || \
    fail 'dynamic MTP patch is missing threshold provenance'
grep -Fq 'speculative_policy' "$patch_13" || \
    fail 'dynamic MTP patch is missing policy provenance'

expected_dry_run=$'runtime: llama-cpp-qwen38-hybrid\n'
expected_dry_run+=$'repository: https://github.com/ggml-org/llama.cpp.git\n'
expected_dry_run+=$'base revision: 7798007a29a90e3053e799394da48cf53a2f8e0f\n'
expected_dry_run+=$'patch: 0001-metal-optimize-qwen4-exp-inference.patch\n'
expected_dry_run+=$'patch: 0002-gguf-py-register-qwen4exp-nextn-tensors.patch\n'
expected_dry_run+=$'patch: 0003-model-add-qwen4exp-nextn-mtp-draft-head.patch\n'
expected_dry_run+=$'patch: 0004-convert-export-qwen4exp-nextn-mtp-draft-head.patch\n'
expected_dry_run+=$'patch: 0005-ggml-cuda-key-cuda-graph-cache-by-shape.patch\n'
expected_dry_run+=$'patch: 0006-llama-let-mtp-draft-borrow-target-embeddings-lm-head.patch\n'
expected_dry_run+=$'patch: 0007-qwen4exp-allow-loading-draft-only-mtp-export.patch\n'
expected_dry_run+=$'patch: 0008-qwen4exp-mtp-trim-comments.patch\n'
expected_dry_run+=$'patch: 0009-convert-declare-mtp-shared-embd-on-qwen-mtp-mixin.patch\n'
expected_dry_run+=$'patch: 0010-ggml-cuda-guard-graph-key-against-empty-graph.patch\n'
expected_dry_run+=$'patch: 0011-qwen4exp-reject-draft-only-export-without-target.patch\n'
expected_dry_run+=$'patch: 0012-qwen4exp-expose-optimized-graph-helpers-to-mtp.patch\n'
expected_dry_run+=$'patch: 0013-server-gate-mtp-by-effective-prompt.patch\n'
expected_dry_run+='tested tree: 3eaf84fd5e0f7a29ce9395aa0283b9ade26f7f7c'
actual_dry_run=$("$sync_script" "$runtime_id" --dry-run)
[[ "$actual_dry_run" == "$expected_dry_run" ]] || {
    diff -u <(print -r -- "$expected_dry_run") <(print -r -- "$actual_dry_run") || true
    fail "dry-run output did not describe the pinned reconstruction"
}

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-runtime-sync.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT
origin="$temporary_root/origin"
fixture_root="$temporary_root/lab"
mkdir -p "$origin" "$fixture_root/scripts" "$fixture_root/manifests/runtimes" \
    "$fixture_root/patches/llama.cpp/fixture-good" \
    "$fixture_root/patches/llama.cpp/fixture-bad"
cp "$sync_script" "$fixture_root/scripts/runtime-sync.zsh"

git -C "$origin" init -q
git -C "$origin" config user.name 'Runtime Fixture'
git -C "$origin" config user.email 'runtime-fixture@example.invalid'
git -C "$origin" config uploadpack.allowFilter true
repository_url="file://$origin"
print -- 'base' > "$origin/model.txt"
mkdir -p "$origin/tests"
print -- 'fixed' > "$origin/tests/server-route.cpp"
git -C "$origin" add model.txt tests/server-route.cpp
git -C "$origin" commit -q -m 'fixture: base'
base_revision=$(git -C "$origin" rev-parse HEAD)

patches_json='[]'
series_file="$fixture_root/patches/llama.cpp/fixture-good/series"
print -- 'patched' > "$origin/model.txt"
git -C "$origin" commit -qam 'fixture: patch model'
patch_revision=$(git -C "$origin" rev-parse HEAD)
first_patch_revision=$patch_revision
first_patch_tree=$(git -C "$origin" rev-parse 'HEAD^{tree}')
patch_file=0001-fixture-patch-model.patch
git -C "$origin" format-patch -1 --stdout "$patch_revision" > \
    "$fixture_root/patches/llama.cpp/fixture-good/$patch_file"
print -- "$patch_file" > "$series_file"
patches_json=$(jq -c \
    --arg revision "$patch_revision" \
    --arg file "$patch_file" \
    '. + [{revision: $revision, file: $file}]' <<< "$patches_json")

for patch_index in {2..12}; do
    print -- "history $patch_index" >> "$origin/history.txt"
    git -C "$origin" add history.txt
    git -C "$origin" commit -q -m "fixture: patch $patch_index"
    patch_revision=$(git -C "$origin" rev-parse HEAD)
    patch_file=$(printf '%04d-fixture-patch-%02d.patch' "$patch_index" "$patch_index")
    git -C "$origin" format-patch -1 --stdout "$patch_revision" > \
        "$fixture_root/patches/llama.cpp/fixture-good/$patch_file"
    print -- "$patch_file" >> "$series_file"
    patches_json=$(jq -c \
        --arg revision "$patch_revision" \
        --arg file "$patch_file" \
        '. + [{revision: $revision, file: $file}]' <<< "$patches_json")
done
penultimate_revision=$patch_revision

print -- 'dynamic' > "$origin/tests/server-route.cpp"
git -C "$origin" commit -qam 'fixture: patch server route test'
patch_revision=$(git -C "$origin" rev-parse HEAD)
patch_file=0013-fixture-patch-server-route-test.patch
git -C "$origin" format-patch -1 --stdout "$patch_revision" > \
    "$fixture_root/patches/llama.cpp/fixture-good/$patch_file"
print -- "$patch_file" >> "$series_file"
patches_json=$(jq -c \
    --arg revision "$patch_revision" \
    --arg file "$patch_file" \
    '. + [{revision: $revision, file: $file}]' <<< "$patches_json")
tested_tree=$(git -C "$origin" rev-parse 'HEAD^{tree}')

write_manifest \
    "$fixture_root/manifests/runtimes/fixture-good.json" \
    fixture-good "$repository_url" "$base_revision" "$patches_json" "$patch_revision" "$tested_tree"

good_manifest="$fixture_root/manifests/runtimes/fixture-good.json"
cp "$good_manifest" "$good_manifest.saved"
jq --arg penultimate_revision "$penultimate_revision" \
    '.tested_revision = $penultimate_revision' "$good_manifest.saved" > "$good_manifest"
if linkage_output=$("$fixture_root/scripts/runtime-sync.zsh" fixture-good --dry-run 2>&1); then
    mv "$good_manifest.saved" "$good_manifest"
    fail 'runtime sync accepted a patched manifest whose tested revision was not the final patch revision'
fi
mv "$good_manifest.saved" "$good_manifest"
assert_contains "$linkage_output" 'invalid runtime manifest'

"$fixture_root/scripts/runtime-sync.zsh" fixture-good --dry-run >/dev/null
[[ ! -e "$fixture_root/.lab" ]] || fail "dry-run wrote runtime state"

"$fixture_root/scripts/runtime-sync.zsh" fixture-good >/dev/null
good_source="$fixture_root/.lab/runtimes/fixture-good/source"
[[ $(git -C "$good_source" rev-parse 'HEAD^{tree}') == "$tested_tree" ]] || \
    fail "fixture reconstruction did not reach the tested tree"
[[ $(git -C "$good_source" config --get remote.origin.partialclonefilter) == 'blob:none' ]] || \
    fail "fixture clone did not request blob filtering"

git -C "$good_source" update-index --assume-unchanged model.txt
print -- 'concealed assume-unchanged content' > "$good_source/model.txt"
if flag_output=$("$fixture_root/scripts/runtime-sync.zsh" fixture-good 2>&1); then
    git -C "$good_source" update-index --no-assume-unchanged model.txt
    git -C "$good_source" checkout -q -- model.txt
    fail 'runtime sync accepted a concealed assume-unchanged modification'
fi
assert_contains "$flag_output" 'unsafe tracked-file index flag'
git -C "$good_source" update-index --no-assume-unchanged model.txt
git -C "$good_source" checkout -q -- model.txt

git -C "$good_source" update-index --skip-worktree model.txt
print -- 'concealed skip-worktree content' > "$good_source/model.txt"
if flag_output=$("$fixture_root/scripts/runtime-sync.zsh" fixture-good 2>&1); then
    git -C "$good_source" update-index --no-skip-worktree model.txt
    git -C "$good_source" checkout -q -- model.txt
    fail 'runtime sync accepted a concealed skip-worktree modification'
fi
assert_contains "$flag_output" 'unsafe tracked-file index flag'
git -C "$good_source" update-index --no-skip-worktree model.txt
git -C "$good_source" checkout -q -- model.txt

print -- 'user file' > "$good_source/user-untracked.txt"
dirty_head=$(git -C "$good_source" rev-parse HEAD)
dirty_status=$(git -C "$good_source" status --porcelain=v1 --untracked-files=all)
if dirty_output=$("$fixture_root/scripts/runtime-sync.zsh" fixture-good 2>&1); then
    fail "runtime sync accepted a dirty existing checkout"
fi
assert_contains "$dirty_output" 'refusing dirty runtime checkout'
[[ $(git -C "$good_source" rev-parse HEAD) == "$dirty_head" ]] || \
    fail "dirty-checkout refusal changed HEAD"
[[ $(git -C "$good_source" status --porcelain=v1 --untracked-files=all) == "$dirty_status" ]] || \
    fail "dirty-checkout refusal changed user files"

bad_patch_file=0001-fixture-unappliable.patch
sed 's/^-base$/-not-the-base/' \
    "$fixture_root/patches/llama.cpp/fixture-good/0001-fixture-patch-model.patch" > \
    "$fixture_root/patches/llama.cpp/fixture-bad/$bad_patch_file"
print -- "$bad_patch_file" > "$fixture_root/patches/llama.cpp/fixture-bad/series"
bad_patches_json=$(jq -cn \
    --arg revision "$first_patch_revision" \
    --arg file "$bad_patch_file" \
    '[{revision: $revision, file: $file}]')
write_manifest \
    "$fixture_root/manifests/runtimes/fixture-bad.json" \
    fixture-bad "$repository_url" "$base_revision" "$bad_patches_json" \
    "$first_patch_revision" "$first_patch_tree"

bad_source="$fixture_root/.lab/runtimes/fixture-bad/source"
mkdir -p "$bad_source:h"
git clone -q "$origin" "$bad_source"
git -C "$bad_source" config user.name 'Runtime Fixture'
git -C "$bad_source" config user.email 'runtime-fixture@example.invalid'
print -- 'preserve me' > "$bad_source/local.txt"
git -C "$bad_source" add local.txt
git -C "$bad_source" commit -q -m 'fixture: preserve local commit'
bad_head=$(git -C "$bad_source" rev-parse HEAD)
bad_branch=$(git -C "$bad_source" symbolic-ref --short HEAD)
bad_status=$(git -C "$bad_source" status --porcelain=v1 --untracked-files=all)

if patch_output=$("$fixture_root/scripts/runtime-sync.zsh" fixture-bad 2>&1); then
    fail "runtime sync accepted an unappliable patch"
fi
assert_contains "$patch_output" "failed to apply patch: $bad_patch_file"
[[ $(git -C "$bad_source" rev-parse HEAD) == "$bad_head" ]] || \
    fail "failed patch application changed HEAD"
[[ $(git -C "$bad_source" symbolic-ref --short HEAD) == "$bad_branch" ]] || \
    fail "failed patch application changed the checked-out branch"
[[ $(git -C "$bad_source" status --porcelain=v1 --untracked-files=all) == "$bad_status" ]] || \
    fail "failed patch application changed checkout contents"
[[ -f "$bad_source/local.txt" ]] || fail "failed patch application deleted a user file"
[[ ! -d "$(git -C "$bad_source" rev-parse --git-path rebase-apply)" ]] || \
    fail "failed patch application left git am state behind"

print -- 'runtime sync checks: PASS'
