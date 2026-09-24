#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
E2E_AGENT=codex E2E_ENTRYPOINT=scripts/run-codex-e2e.sh \
  exec "$ROOT/scripts/run-e2e.sh" "$@"
