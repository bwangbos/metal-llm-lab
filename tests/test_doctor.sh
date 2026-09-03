#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
cli="$root/bin/metal-llm"
system_fixture="$root/tests/fixtures/system/apple-m5-max.txt"
real_jq=$(command -v jq)
real_git=$(command -v git)
real_curl=$(command -v curl)
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

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/metal-llm-doctor.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT
fake_bin="$temporary_root/bin"
mkdir -p "$fake_bin"

for tool_pair in "jq:$real_jq" "git:$real_git" "curl:$real_curl" "shasum:$real_shasum"; do
    tool_name=${tool_pair%%:*}
    tool_path=${tool_pair#*:}
    ln -s "$tool_path" "$fake_bin/$tool_name"
done

for tool_name in cmake ninja; do
    print -r -- '#!/bin/zsh' 'exit 0' > "$fake_bin/$tool_name"
    chmod +x "$fake_bin/$tool_name"
done

cat > "$fake_bin/uname" <<'EOF'
#!/bin/zsh
case "$1" in
    -s) print -- "${DOCTOR_TEST_OS:-Darwin}" ;;
    -m) print -- "${DOCTOR_TEST_ARCH:-arm64}" ;;
    *) exit 2 ;;
esac
EOF

cat > "$fake_bin/system_profiler" <<EOF
#!/bin/zsh
/bin/cat '$system_fixture'
EOF

cat > "$fake_bin/df" <<'EOF'
#!/bin/zsh
print -- 'Filesystem 1024-blocks Used Available Capacity Mounted on'
print -- "/dev/test 250000000 1 ${DOCTOR_TEST_BLOCKS:-200000000} 1% /"
EOF

cat > "$fake_bin/xcode-select" <<'EOF'
#!/bin/zsh
[[ "$1" == '-p' ]] || exit 2
print -- '/Applications/Xcode.app/Contents/Developer'
EOF

cat > "$fake_bin/brew" <<EOF
#!/bin/zsh
print -r -- "brew was invoked: \$*" >> '$temporary_root/mutations.log'
exit 99
EOF
chmod +x "$fake_bin"/{uname,system_profiler,df,xcode-select,brew}

doctor_output=$(cd "$temporary_root" && PATH="$fake_bin" "$cli" doctor)
assert_contains "$doctor_output" 'architecture: arm64'
assert_contains "$doctor_output" 'operating system: macOS'
assert_contains "$doctor_output" 'chip: Apple M5 Max'
assert_contains "$doctor_output" 'memory: 128 GB'
assert_contains "$doctor_output" 'Metal: Supported'
assert_contains "$doctor_output" 'disk available:'
assert_contains "$doctor_output" 'doctor: ready'
[[ ! -e "$temporary_root/mutations.log" ]] || fail 'doctor invoked Homebrew'

if architecture_output=$(DOCTOR_TEST_ARCH=x86_64 PATH="$fake_bin" "$cli" doctor 2>&1); then
    fail 'doctor accepted an unsupported architecture'
fi
assert_contains "$architecture_output" 'unsupported architecture: x86_64 (requires arm64)'

rm "$fake_bin/cmake" "$fake_bin/ninja" "$fake_bin/jq"
if missing_output=$(PATH="$fake_bin" "$cli" doctor 2>&1); then
    fail 'doctor accepted missing required commands'
fi
assert_contains "$missing_output" 'missing required command: cmake'
assert_contains "$missing_output" 'missing required command: ninja'
assert_contains "$missing_output" 'missing required command: jq'
suggestion_count=$(print -r -- "$missing_output" | /usr/bin/grep -Fc 'brew install cmake ninja jq')
(( suggestion_count == 1 )) || fail "expected one Homebrew suggestion, got $suggestion_count"
[[ ! -e "$temporary_root/mutations.log" ]] || fail 'doctor invoked Homebrew while reporting missing tools'

print -- 'doctor checks: PASS'
