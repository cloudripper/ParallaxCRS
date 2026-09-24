#!/bin/bash
#
# CRS entrypoint multiplexer.
#
# Picks the runner entrypoint from $CRS_ENTRYPOINT. The supported production
# contract is `run_crs`; upstream tutorial/probe entrypoints stay available only
# behind an explicit opt-in so a compose typo cannot select an incomplete path.
set -e

EP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ep="${CRS_ENTRYPOINT:-run_crs}"
ep="${ep%.py}"   # tolerate a trailing ".py"
script="${EP_DIR}/${ep}.py"

if [[ "$ep" != "run_crs" && "${CRS_ENABLE_EXPERIMENTAL_ENTRYPOINTS:-0}" != "1" ]]; then
  echo "[entrypoint] '${ep}' is experimental. Set CRS_ENABLE_EXPERIMENTAL_ENTRYPOINTS=1 to opt in." >&2
  exit 2
fi

if [ ! -f "$script" ]; then
  echo "[entrypoint] unknown CRS_ENTRYPOINT='${CRS_ENTRYPOINT:-}' (resolved '${ep}.py' not found)" >&2
  echo "[entrypoint] available entrypoints:" >&2
  for f in "$EP_DIR"/run_crs*.py "$EP_DIR"/test_*.py "$EP_DIR"/idle.py; do
    [ -f "$f" ] && echo "  - $(basename "${f%.py}")" >&2
  done
  exit 2
fi

echo "[entrypoint] CRS_ENTRYPOINT=${ep} -> exec python3 ${script} $*" >&2
exec python3 "$script" "$@"
