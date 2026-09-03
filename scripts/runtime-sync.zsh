#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}

usage() {
    print -u2 -- "usage: ${0:t} RUNTIME_ID [--dry-run]"
    exit 2
}

die() {
    print -u2 -- "runtime-sync: $1"
    exit 1
}

runtime_id=''
dry_run=0

for argument in "$@"; do
    case "$argument" in
        --dry-run)
            (( dry_run == 0 )) || usage
            dry_run=1
            ;;
        -* ) usage ;;
        *)
            [[ -z "$runtime_id" ]] || usage
            runtime_id=$argument
            ;;
    esac
done

[[ -n "$runtime_id" ]] || usage
[[ "$runtime_id" =~ '^[a-z0-9]+([.-][a-z0-9]+)*$' ]] || die "invalid runtime id: $runtime_id"
command -v jq >/dev/null 2>&1 || die 'jq is required'

manifest="$root/manifests/runtimes/$runtime_id.json"
[[ -f "$manifest" ]] || die "runtime manifest not found: $runtime_id"

if ! jq -er --arg runtime_id "$runtime_id" '
    (.schema_version == 1) and
    (.id == $runtime_id) and
    (.repository | type == "string" and length > 0) and
    (.base_revision | type == "string" and test("^[0-9a-f]{40}$")) and
    (.patches | type == "array" and all(.[];
        (.revision | type == "string" and test("^[0-9a-f]{40}$")) and
        (.file | type == "string" and test("^[0-9]{4}-[a-z0-9-]+\\.patch$"))
    )) and
    (.tested_revision | type == "string" and test("^[0-9a-f]{40}$")) and
    (.tested_tree_sha | type == "string" and test("^[0-9a-f]{40}$"))
' "$manifest" >/dev/null; then
    die "invalid runtime manifest: $manifest"
fi

repository=$(jq -er '.repository' "$manifest")
base_revision=$(jq -er '.base_revision' "$manifest")
tested_tree=$(jq -er '.tested_tree_sha' "$manifest")

typeset -a patch_files patch_revisions
patch_files=()
patch_revisions=()
while IFS=$'\t' read -r patch_revision patch_file; do
    patch_revisions+=("$patch_revision")
    patch_files+=("$patch_file")
done < <(jq -er '.patches[] | [.revision, .file] | @tsv' "$manifest")

patch_dir=''
if (( ${#patch_files} > 0 )); then
    expected_series=${(F)patch_files}
    typeset -a matching_patch_dirs
    matching_patch_dirs=()

    for series_file in "$root"/patches/llama.cpp/*/series(N); do
        if [[ "$(<"$series_file")" == "$expected_series" ]]; then
            matching_patch_dirs+=("${series_file:h}")
        fi
    done

    (( ${#matching_patch_dirs} == 1 )) || \
        die "expected one patch series matching manifest, found ${#matching_patch_dirs}"
    patch_dir=${matching_patch_dirs[1]}

    for (( index = 1; index <= ${#patch_files}; index++ )); do
        patch_path="$patch_dir/${patch_files[$index]}"
        [[ -f "$patch_path" ]] || die "patch not found: ${patch_files[$index]}"
        patch_header=$(sed -n '1p' "$patch_path")
        [[ "$patch_header" == "From ${patch_revisions[$index]} "* ]] || \
            die "patch revision does not match manifest: ${patch_files[$index]}"
    done
fi

print -- "runtime: $runtime_id"
print -- "repository: $repository"
print -- "base revision: $base_revision"
for patch_file in "${patch_files[@]}"; do
    print -- "patch: $patch_file"
done
print -- "tested tree: $tested_tree"

(( dry_run == 1 )) && exit 0
command -v git >/dev/null 2>&1 || die 'git is required'

runtime_dir="$root/.lab/runtimes/$runtime_id"
source_dir="$runtime_dir/source"
source_existed=0

if [[ -e "$source_dir" ]]; then
    [[ -d "$source_dir" ]] || die "runtime source is not a directory: $source_dir"
    git -C "$source_dir" rev-parse --git-dir >/dev/null 2>&1 || \
        die "runtime source is not a Git checkout: $source_dir"
    source_existed=1

    am_state="$(git -C "$source_dir" rev-parse --absolute-git-dir)/rebase-apply"
    [[ ! -e "$am_state" ]] || die "runtime checkout already has an in-progress git am: $source_dir"

    checkout_status=$(git -C "$source_dir" status --porcelain=v1 --untracked-files=all)
    ignored_files=$(git -C "$source_dir" ls-files --others --ignored --exclude-standard)
    if [[ -n "$checkout_status" || -n "$ignored_files" ]]; then
        die "refusing dirty runtime checkout: $source_dir"
    fi

    current_tree=$(git -C "$source_dir" rev-parse 'HEAD^{tree}' 2>/dev/null || true)
    if [[ "$current_tree" == "$tested_tree" ]]; then
        print -- "runtime source already matches tested tree: $source_dir"
        exit 0
    fi
else
    mkdir -p "$runtime_dir"
    git clone --filter=blob:none --no-checkout "$repository" "$source_dir" || \
        die "failed to clone runtime repository: $repository"
    am_state="$(git -C "$source_dir" rev-parse --absolute-git-dir)/rebase-apply"
fi

original_head=''
original_branch=''
if (( source_existed == 1 )); then
    original_head=$(git -C "$source_dir" rev-parse HEAD)
    original_branch=$(git -C "$source_dir" symbolic-ref -q --short HEAD || true)
fi

restore_needed=0
cleanup_failed_sync() {
    local exit_status=$?

    if (( restore_needed == 1 )); then
        if [[ -d "$am_state" ]]; then
            git -C "$source_dir" am --abort >/dev/null 2>&1 || \
                print -u2 -- "runtime-sync: warning: could not abort its git am operation"
        fi

        if (( source_existed == 1 )); then
            if [[ -n "$original_branch" ]]; then
                git -C "$source_dir" checkout -q "$original_branch" >/dev/null 2>&1 || \
                    print -u2 -- "runtime-sync: warning: could not restore branch $original_branch"
            else
                git -C "$source_dir" checkout -q --detach "$original_head" >/dev/null 2>&1 || \
                    print -u2 -- "runtime-sync: warning: could not restore original HEAD"
            fi
        fi
    fi

    return $exit_status
}
trap cleanup_failed_sync EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

git -C "$source_dir" fetch --no-tags origin "$base_revision" || \
    die "failed to fetch base revision: $base_revision"
fetched_revision=$(git -C "$source_dir" rev-parse 'FETCH_HEAD^{commit}')
[[ "$fetched_revision" == "$base_revision" ]] || \
    die "fetched revision does not match requested base: $base_revision"

restore_needed=1
git -C "$source_dir" checkout -q --detach "$base_revision" || \
    die "failed to detach runtime checkout at base revision: $base_revision"

for patch_file in "${patch_files[@]}"; do
    if ! git -C "$source_dir" \
        -c user.name='Metal LLM Lab Runtime Sync' \
        -c user.email='runtime-sync@localhost' \
        am "$patch_dir/$patch_file"; then
        print -u2 -- "runtime-sync: failed to apply patch: $patch_file"
        exit 1
    fi
done

actual_tree=$(git -C "$source_dir" rev-parse 'HEAD^{tree}')
[[ "$actual_tree" == "$tested_tree" ]] || \
    die "tested tree mismatch: expected $tested_tree, got $actual_tree"

restore_needed=0
print -- "runtime source synchronized: $source_dir"
