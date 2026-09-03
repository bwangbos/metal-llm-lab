metal_llm_error() {
    print -u2 -- "metal-llm: $*"
}

metal_llm_die() {
    metal_llm_error "$*"
    return 1
}

metal_llm_valid_id() {
    [[ "$1" =~ '^[a-z0-9]+([.-][a-z0-9]+)*$' ]]
}

metal_llm_require_supported_host() {
    local operating_system architecture
    local unsupported=0

    operating_system=$(uname -s 2>/dev/null || print -- unknown)
    architecture=$(uname -m 2>/dev/null || print -- unknown)
    if [[ "$operating_system" != Darwin ]]; then
        metal_llm_error "unsupported operating system: $operating_system (requires macOS)"
        unsupported=1
    fi
    if [[ "$architecture" != arm64 ]]; then
        metal_llm_error "unsupported architecture: $architecture (requires arm64)"
        unsupported=1
    fi
    (( unsupported == 0 ))
}

metal_llm_file_size() {
    local file_path=$1
    local byte_count
    byte_count=$(wc -c < "$file_path") || return 1
    print -- "${byte_count//[[:space:]]/}"
}

metal_llm_sha256() {
    local file_path=$1
    local checksum_output
    typeset -a checksum_fields

    checksum_output=$(shasum -a 256 "$file_path") || return 1
    checksum_fields=(${=checksum_output})
    print -- "$checksum_fields[1]"
}

metal_llm_disk_bytes() {
    local target_path=$1
    local disk_output disk_line
    typeset -a disk_fields

    disk_output=$(df -Pk "$target_path") || return 1
    disk_line=${${(f)disk_output}[-1]}
    disk_fields=(${=disk_line})
    (( ${#disk_fields} >= 4 )) || return 1
    [[ "$disk_fields[4]" == <-> ]] || return 1
    print -- $(( disk_fields[4] * 1024 ))
}

metal_llm_print_command() {
    typeset -a command_arguments
    command_arguments=("$@")
    print -n -- 'command:'
    local argument
    for argument in "${command_arguments[@]}"; do
        print -n -- " ${(q)argument}"
    done
    print
}
