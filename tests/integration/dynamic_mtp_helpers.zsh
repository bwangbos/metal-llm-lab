metal_llm_wait_for_process_diagnostic() {
    setopt localoptions extendedglob

    local process_pid=$1 recorded_start=$2 log_file=$3 expected_diagnostic=$4
    local timeout_seconds=$5 poll_seconds=${6:-1}
    [[ "$process_pid" == <-> && "$process_pid" -gt 1 && -n "$recorded_start" ]] || return 2
    [[ -f "$log_file" && ! -L "$log_file" && -n "$expected_diagnostic" ]] || return 2
    [[ "$timeout_seconds" == <-> && "$timeout_seconds" -gt 0 ]] || return 2
    [[ "$poll_seconds" =~ '^[0-9]+([.][0-9]+)?$' ]] || return 2
    (( poll_seconds > 0 )) || return 2

    local deadline=$(( SECONDS + timeout_seconds ))
    local current_start process_status
    while true; do
        if kill -0 "$process_pid" 2>/dev/null; then
            current_start=$(ps -p "$process_pid" -o lstart= 2>/dev/null) || return 3
            current_start=${current_start##[[:space:]]#}
            current_start=${current_start%%[[:space:]]#}
            [[ -n "$current_start" && "$current_start" == "$recorded_start" ]] || return 3
        else
            if wait "$process_pid" 2>/dev/null; then
                process_status=0
            else
                process_status=$?
            fi
            (( process_status != 0 )) || return 4
            grep -Fq -- "$expected_diagnostic" "$log_file" || return 5
            return 0
        fi

        (( SECONDS < deadline )) || return 124
        sleep "$poll_seconds"
    done
}
