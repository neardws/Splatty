#!/usr/bin/env bash
# Splatty: capture folder -> COLMAP poses -> msplat splat.  See colmap_then_msplat.py --help.
# One-time setup (no sudo):
#   uv venv -p 3.12 ~/Developer/splat-env/.venv
#   uv pip install -p ~/Developer/splat-env/.venv "msplat[cli]" pycolmap numpy pillow
set -euo pipefail
PY="${SPLATTY_PY:-$HOME/Developer/splat-env/.venv/bin/python}"
[ -x "$PY" ] || { echo "python env not found: $PY (set SPLATTY_PY or see setup above)" >&2; exit 1; }
exec "$PY" "$(cd "$(dirname "$0")" && pwd)/colmap_then_msplat.py" "$@"
