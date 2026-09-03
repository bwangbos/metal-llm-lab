metal_llm_doctor() {
    if (( $# != 0 )); then
        metal_llm_error 'usage: metal-llm doctor'
        return 2
    fi

    local failure_count=0
    local operating_system architecture
    operating_system=$(uname -s 2>/dev/null || print -- unknown)
    architecture=$(uname -m 2>/dev/null || print -- unknown)

    if [[ "$operating_system" == Darwin ]]; then
        print -- 'operating system: macOS'
    else
        print -u2 -- "unsupported operating system: $operating_system (requires macOS)"
        (( ++failure_count ))
    fi

    print -- "architecture: $architecture"
    if [[ "$architecture" != arm64 ]]; then
        print -u2 -- "unsupported architecture: $architecture (requires arm64)"
        (( ++failure_count ))
    fi

    local tool_name
    typeset -a required_tools missing_brew_tools
    required_tools=(git curl jq cmake ninja xcode-select shasum)
    missing_brew_tools=()
    for tool_name in "${required_tools[@]}"; do
        if command -v "$tool_name" >/dev/null 2>&1; then
            print -- "command: $tool_name (found)"
        else
            print -u2 -- "missing required command: $tool_name"
            (( ++failure_count ))
            case "$tool_name" in
                cmake|ninja|jq) missing_brew_tools+=("$tool_name") ;;
            esac
        fi
    done

    if (( ${#missing_brew_tools} > 0 )); then
        print -u2 -- 'install the missing build tools with: brew install cmake ninja jq'
    fi

    local developer_dir
    if command -v xcode-select >/dev/null 2>&1; then
        if developer_dir=$(xcode-select -p 2>/dev/null); then
            print -- "developer tools: $developer_dir"
        else
            print -u2 -- 'developer tools are not configured; run: xcode-select --install'
            (( ++failure_count ))
        fi
    fi

    local system_details=''
    if command -v system_profiler >/dev/null 2>&1; then
        system_details=$(system_profiler SPHardwareDataType SPDisplaysDataType 2>/dev/null || true)
    else
        print -u2 -- 'missing required macOS command: system_profiler'
        (( ++failure_count ))
    fi

    local line chip='' memory='' metal=''
    for line in "${(@f)system_details}"; do
        if [[ -z "$chip" && "$line" =~ '^[[:space:]]*Chip: (.+)$' ]]; then
            chip=$match[1]
        elif [[ -z "$memory" && "$line" =~ '^[[:space:]]*Memory: (.+)$' ]]; then
            memory=$match[1]
        elif [[ -z "$metal" && "$line" =~ '^[[:space:]]*Metal: (.+)$' ]]; then
            metal=$match[1]
        fi
    done

    if [[ -n "$chip" ]]; then
        print -- "chip: $chip"
    else
        print -u2 -- 'could not detect the Apple chip'
        (( ++failure_count ))
    fi
    if [[ -n "$memory" ]]; then
        print -- "memory: $memory"
    else
        print -u2 -- 'could not detect unified memory'
        (( ++failure_count ))
    fi
    if [[ "$metal" == Supported* ]]; then
        print -- "Metal: $metal"
    else
        print -u2 -- "Metal is not visible to system_profiler${metal:+: $metal}"
        (( ++failure_count ))
    fi

    local available_bytes
    if available_bytes=$(metal_llm_disk_bytes "$METAL_LLM_ROOT"); then
        print -- "disk available: $available_bytes bytes"
        if command -v jq >/dev/null 2>&1; then
            local required_bytes=0 model_manifest model_bytes
            for model_manifest in "$METAL_LLM_ROOT"/manifests/models/*.json(N); do
                model_bytes=$(jq -er '[.artifacts[].bytes] | add' "$model_manifest" 2>/dev/null || print -- 0)
                (( model_bytes > required_bytes )) && required_bytes=$model_bytes
            done
            if (( required_bytes > 0 && available_bytes < required_bytes )); then
                print -u2 -- "insufficient disk space: $available_bytes bytes available, $required_bytes bytes required for artifacts"
                (( ++failure_count ))
            fi
        fi
    else
        print -u2 -- 'could not determine free disk space'
        (( ++failure_count ))
    fi

    if (( failure_count > 0 )); then
        print -u2 -- "doctor: found $failure_count problem(s)"
        return 1
    fi

    print -- 'doctor: ready'
}
