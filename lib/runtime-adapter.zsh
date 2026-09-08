# Runtime dispatch leaves the original llama.cpp command paths unchanged.
metal_llm_mtplx() {
    local operation=$1
    shift
    local argument dry_run=0 identity
    for argument in "$@"; do
        [[ "$argument" != --dry-run ]] || dry_run=1
    done
    command -v python3 >/dev/null 2>&1 || {
        metal_llm_die 'Python 3 is required for MTPLX setup; runtime installation additionally requires Python 3.12 (METAL_LLM_PYTHON)'
        return 1
    }
    local adapter="$METAL_LLM_ROOT/lib/mtplx_adapter.py"
    if [[ "$operation" == serve && "$dry_run" == 0 ]]; then
        identity=$(python3 -I -B "$adapter" serve "$@") || return 1
        metal_llm_acquire_managed_lease "$identity" || return 1
        exec "$METAL_LLM_ROOT/.lab/runtimes/mtplx-2.11.2/venv/bin/python" -I -B \
          "$adapter" launch --identity "$METAL_LLM_MANAGED_IDENTITY_RECORD"
    elif [[ "$operation" == bench && "$dry_run" == 0 ]]; then
        metal_llm_read_live_managed_identity || return 1
        python3 -I -B "$adapter" bench "$@" --identity "$METAL_LLM_MANAGED_IDENTITY_RECORD"
    else
        python3 -I -B "$adapter" "$operation" "$@"
    fi
}
