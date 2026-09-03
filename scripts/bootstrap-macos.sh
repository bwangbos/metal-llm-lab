#!/bin/sh
set -u

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$script_dir/.." && pwd)

"$root/bin/metal-llm" doctor
doctor_status=$?

printf '%s\n' 'Next setup command:'
printf '%s\n' './bin/metal-llm setup qwen3.8-flash-next'

exit "$doctor_status"
