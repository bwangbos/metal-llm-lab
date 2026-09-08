#!/bin/zsh
set -euo pipefail
root=${0:A:h:h}
python3 -B "$root/tests/test_mtplx.py"
