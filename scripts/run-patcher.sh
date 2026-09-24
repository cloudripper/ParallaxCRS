#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

PATCHER_NAME="crs-patcher-parallax"
DEFAULT_COMPOSE_FILE="$ROOT/configs/patcher-parallax.yaml"
DEFAULT_WORK_DIR="$ROOT/generated/oss-crs-work"

usage() {
  cat <<'EOF'
Usage: scripts/run-patcher.sh --fuzz-proj-path PATH --target-harness NAME [evidence options]

Runs a local Patcher through:
  oss-crs prepare -> oss-crs build-target -> oss-crs run -> oss-crs artifacts

Required:
  --fuzz-proj-path PATH       OSS-Fuzz project directory
  --target-harness NAME       Harness binary to patch
  One evidence option: --pov, --pov-dir, --diff, --seed-dir,
                       --bug-candidate, or --bug-candidate-dir

Evidence options:
  --pov FILE                  A single proof-of-vulnerability input
  --pov-dir DIR               Directory containing PoV inputs
  --diff FILE                 Delta diff; passed to both build-target and run
  --seed-dir DIR              Initial seed corpus passed to run
  --bug-candidate FILE        A bug-candidate report passed to build-target and run
  --bug-candidate-dir DIR     Directory of bug-candidate reports (exclusive with --bug-candidate)

Other options:
  --target-source-path PATH   Local source override for the target image
  --source-override PATH      Alias for --target-source-path
  --sanitizer NAME            Sanitizer (default: address)
  --timeout SECONDS           Run timeout in seconds (default: 3600)
  --build-id ID               Reuse or name a build; generated when building
  --run-id ID                 Name a run; generated when omitted
  --early-exit                Stop after the first submitted patch
  --auth-mode MODE            litellm (default), or oauth for Claude Code
  --crs-name NAME             Compose entry name (default: crs-patcher-parallax)
  --skip-prepare              Skip oss-crs prepare
  --skip-build                Reuse an existing --build-id; errors if it is omitted
  --compose-file FILE         Compose file (default: configs/patcher-parallax.yaml)
  --work-dir DIR              OSS-CRS work directory (default: generated/oss-crs-work)
  -h, --help                  Show this help

The patcher consumes all supplied evidence once at startup. A run that exits
successfully without a submitted patch is reported as failure by this wrapper.
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

FUZZ_PROJ_PATH=""
TARGET_HARNESS=""
TARGET_SOURCE_PATH=""
POV_PATH=""
POV_DIR=""
DIFF_PATH=""
SEED_DIR=""
BUG_CANDIDATE_PATH=""
BUG_CANDIDATE_DIR=""
SANITIZER="address"
TIMEOUT="3600"
BUILD_ID=""
RUN_ID=""
EARLY_EXIT=false
AUTH_MODE="litellm"
SKIP_PREPARE=false
SKIP_BUILD=false
COMPOSE_FILE="$DEFAULT_COMPOSE_FILE"
WORK_DIR="$DEFAULT_WORK_DIR"

while (($#)); do
  case "$1" in
    --fuzz-proj-path|--target|--target-path|--target-proj-path)
      (($# >= 2)) || die "$1 requires a path"
      FUZZ_PROJ_PATH="$2"
      shift
      ;;
    --target-harness|--harness)
      (($# >= 2)) || die "$1 requires a harness name"
      TARGET_HARNESS="$2"
      shift
      ;;
    --target-source-path|--source-override)
      (($# >= 2)) || die "$1 requires a path"
      TARGET_SOURCE_PATH="$2"
      shift
      ;;
    --pov)
      (($# >= 2)) || die '--pov requires a file'
      POV_PATH="$2"
      shift
      ;;
    --pov-dir)
      (($# >= 2)) || die '--pov-dir requires a directory'
      POV_DIR="$2"
      shift
      ;;
    --diff)
      (($# >= 2)) || die '--diff requires a file'
      DIFF_PATH="$2"
      shift
      ;;
    --seed-dir)
      (($# >= 2)) || die '--seed-dir requires a directory'
      SEED_DIR="$2"
      shift
      ;;
    --bug-candidate)
      (($# >= 2)) || die '--bug-candidate requires a file'
      BUG_CANDIDATE_PATH="$2"
      shift
      ;;
    --bug-candidate-dir)
      (($# >= 2)) || die '--bug-candidate-dir requires a directory'
      BUG_CANDIDATE_DIR="$2"
      shift
      ;;
    --sanitizer)
      (($# >= 2)) || die '--sanitizer requires a value'
      SANITIZER="$2"
      shift
      ;;
    --timeout)
      (($# >= 2)) || die '--timeout requires seconds'
      TIMEOUT="$2"
      shift
      ;;
    --build-id)
      (($# >= 2)) || die '--build-id requires an ID'
      BUILD_ID="$2"
      shift
      ;;
    --run-id)
      (($# >= 2)) || die '--run-id requires an ID'
      RUN_ID="$2"
      shift
      ;;
    --early-exit)
      EARLY_EXIT=true
      ;;
    --auth-mode)
      (($# >= 2)) || die '--auth-mode requires litellm or oauth'
      AUTH_MODE="$2"
      shift
      ;;
    --crs-name)
      (($# >= 2)) || die '--crs-name requires a name'
      PATCHER_NAME="$2"
      shift
      ;;
    --skip-prepare)
      SKIP_PREPARE=true
      ;;
    --skip-build)
      SKIP_BUILD=true
      ;;
    --compose-file)
      (($# >= 2)) || die '--compose-file requires a file'
      COMPOSE_FILE="$2"
      shift
      ;;
    --work-dir)
      (($# >= 2)) || die '--work-dir requires a directory'
      WORK_DIR="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
  shift
done

[[ -n "$FUZZ_PROJ_PATH" ]] || die '--fuzz-proj-path is required'
[[ -n "$TARGET_HARNESS" ]] || die '--target-harness is required'
[[ -n "$PATCHER_NAME" ]] || die '--crs-name must not be empty'
[[ -n "$POV_PATH" || -n "$POV_DIR" || -n "$DIFF_PATH" || -n "$SEED_DIR" || -n "$BUG_CANDIDATE_PATH" || -n "$BUG_CANDIDATE_DIR" ]] || die 'Provide at least one evidence input.'
[[ -d "$FUZZ_PROJ_PATH" ]] || die "Fuzz project directory does not exist: $FUZZ_PROJ_PATH"
[[ -f "$COMPOSE_FILE" ]] || die "Compose file does not exist: $COMPOSE_FILE"
[[ -z "$TARGET_SOURCE_PATH" || -d "$TARGET_SOURCE_PATH" ]] || die "Target source override is not a directory: $TARGET_SOURCE_PATH"
[[ -z "$POV_PATH" || -f "$POV_PATH" ]] || die "PoV file does not exist: $POV_PATH"
[[ -z "$POV_DIR" || -d "$POV_DIR" ]] || die "PoV directory does not exist: $POV_DIR"
[[ -z "$DIFF_PATH" || -f "$DIFF_PATH" ]] || die "Diff file does not exist: $DIFF_PATH"
[[ -z "$SEED_DIR" || -d "$SEED_DIR" ]] || die "Seed directory does not exist: $SEED_DIR"
[[ -z "$BUG_CANDIDATE_PATH" || -f "$BUG_CANDIDATE_PATH" ]] || die "Bug-candidate file does not exist: $BUG_CANDIDATE_PATH"
[[ -z "$BUG_CANDIDATE_DIR" || -d "$BUG_CANDIDATE_DIR" ]] || die "Bug-candidate directory does not exist: $BUG_CANDIDATE_DIR"
[[ -z "$BUG_CANDIDATE_PATH" || -z "$BUG_CANDIDATE_DIR" ]] || die 'Use either --bug-candidate or --bug-candidate-dir, not both'
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die '--timeout must be a positive integer'
[[ "$AUTH_MODE" == litellm || "$AUTH_MODE" == oauth ]] || die '--auth-mode must be litellm or oauth'

require_command uv
require_command docker
require_command python3
docker info >/dev/null 2>&1 || die 'Docker daemon is not reachable. Run scripts/setup.sh for diagnostics.'
docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 is required.'

source "$ROOT/scripts/load-local-env.sh"
case "$AUTH_MODE" in
  litellm)
    # Claude Code prefers OAuth whenever this is non-empty. Prevent an
    # inherited legacy token from bypassing the configured proxy.
    unset CLAUDE_CODE_OAUTH_TOKEN
    load_litellm_upstream_env "$ROOT"
    [[ -n "${LITELLM_UPSTREAM_BASE_URL:-}" ]] || die 'LITELLM_UPSTREAM_BASE_URL is required for LiteLLM mode'
    [[ -n "${LITELLM_UPSTREAM_API_KEY:-}" ]] || die 'LITELLM_UPSTREAM_API_KEY is required for LiteLLM mode'
    ;;
  oauth)
    load_claude_oauth_env "$ROOT"
    [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] || die 'CLAUDE_CODE_OAUTH_TOKEN is required for OAuth mode'
    ;;
esac
if [[ "$SKIP_BUILD" == true && -z "$BUILD_ID" ]]; then
  die '--skip-build requires --build-id; oss-crs run otherwise auto-builds.'
fi

mkdir -p "$WORK_DIR"

# Keep IDs deterministic across the build/run/artifacts phases without relying
# on oss-crs selecting a latest build from a different local campaign.
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ "$SKIP_BUILD" == false && -z "$BUILD_ID" ]]; then
  BUILD_ID="patcher-build-${timestamp}-$$"
fi
if [[ -z "$RUN_ID" ]]; then
  RUN_ID="patcher-run-${timestamp}-$$"
fi

OSS_CRS=(uv run --project "$ROOT/oss-crs" oss-crs)
COMMON=(--compose-file "$COMPOSE_FILE" --work-dir "$WORK_DIR")
TARGET_ARGS=(--fuzz-proj-path "$FUZZ_PROJ_PATH")
if [[ -n "$TARGET_SOURCE_PATH" ]]; then
  TARGET_ARGS+=(--target-source-path "$TARGET_SOURCE_PATH")
fi

printf 'Patcher run ID: %s\n' "$RUN_ID"
printf 'Patcher build ID: %s%s\n' "$BUILD_ID" \
  "$( [[ "$SKIP_BUILD" == true ]] && printf ' (skip-build)')"

if [[ "$SKIP_PREPARE" == false ]]; then
  "${OSS_CRS[@]}" prepare "${COMMON[@]}"
fi

if [[ "$SKIP_BUILD" == false ]]; then
  BUILD_ARGS=(build-target "${COMMON[@]}" "${TARGET_ARGS[@]}" --build-id "$BUILD_ID" --sanitizer "$SANITIZER")
  if [[ -n "$DIFF_PATH" ]]; then
    # Delta-mode target builds need the same diff that the run will consume.
    BUILD_ARGS+=(--diff "$DIFF_PATH")
  fi
  if [[ -n "$BUG_CANDIDATE_PATH" ]]; then
    BUILD_ARGS+=(--bug-candidate "$BUG_CANDIDATE_PATH")
  elif [[ -n "$BUG_CANDIDATE_DIR" ]]; then
    BUILD_ARGS+=(--bug-candidate-dir "$BUG_CANDIDATE_DIR")
  fi
  "${OSS_CRS[@]}" "${BUILD_ARGS[@]}"
fi

RUN_ARGS=(run "${COMMON[@]}" "${TARGET_ARGS[@]}" --target-harness "$TARGET_HARNESS" --run-id "$RUN_ID" --sanitizer "$SANITIZER" --timeout "$TIMEOUT")
if [[ -n "$BUILD_ID" ]]; then
  RUN_ARGS+=(--build-id "$BUILD_ID")
fi
if [[ -n "$POV_PATH" ]]; then
  RUN_ARGS+=(--pov "$POV_PATH")
fi
if [[ -n "$POV_DIR" ]]; then
  RUN_ARGS+=(--pov-dir "$POV_DIR")
fi
if [[ -n "$DIFF_PATH" ]]; then
  RUN_ARGS+=(--diff "$DIFF_PATH")
fi
if [[ -n "$SEED_DIR" ]]; then
  RUN_ARGS+=(--seed-dir "$SEED_DIR")
fi
if [[ -n "$BUG_CANDIDATE_PATH" ]]; then
  RUN_ARGS+=(--bug-candidate "$BUG_CANDIDATE_PATH")
elif [[ -n "$BUG_CANDIDATE_DIR" ]]; then
  RUN_ARGS+=(--bug-candidate-dir "$BUG_CANDIDATE_DIR")
fi
if [[ "$EARLY_EXIT" == true ]]; then
  RUN_ARGS+=(--early-exit)
fi

set +e
"${OSS_CRS[@]}" "${RUN_ARGS[@]}"
run_rc=$?
set -e

ARTIFACT_JSON="$(mktemp)"
trap 'rm -f "$ARTIFACT_JSON"' EXIT
ARTIFACT_ARGS=(artifacts "${COMMON[@]}" "${TARGET_ARGS[@]}" --target-harness "$TARGET_HARNESS" --run-id "$RUN_ID" --sanitizer "$SANITIZER")
if [[ -n "$BUILD_ID" ]]; then
  ARTIFACT_ARGS+=(--build-id "$BUILD_ID")
fi

printf '\nResolved OSS-CRS artifacts:\n'
set +e
"${OSS_CRS[@]}" "${ARTIFACT_ARGS[@]}" > "$ARTIFACT_JSON"
artifacts_rc=$?
set -e
cat "$ARTIFACT_JSON"

if ((artifacts_rc != 0)); then
  printf 'Warning: oss-crs artifacts failed with exit code %s.\n' "$artifacts_rc" >&2
  if ((run_rc != 0)); then
    exit "$run_rc"
  fi
  exit "$artifacts_rc"
fi

set +e
patch_count="$(python3 - "$ARTIFACT_JSON" "$PATCHER_NAME" <<'PY'
import json
import sys
from pathlib import Path

with open(sys.argv[1], encoding="utf-8") as f:
    artifacts = json.load(f)

crs_artifacts = artifacts.get("crs", {}).get(sys.argv[2])
if not isinstance(crs_artifacts, dict):
    raise SystemExit(f"Artifact JSON has no crs[{sys.argv[2]!r}] entry.")

patch_dir = crs_artifacts.get("patch")
if not isinstance(patch_dir, str):
    print(0)
    raise SystemExit(0)

count = sum(
    1
    for path in Path(patch_dir).rglob("*")
    if path.is_file() and path.suffix == ".diff" and path.stat().st_size > 0
)
print(count)
PY
)"
patch_parse_rc=$?
set -e

if ((patch_parse_rc != 0)); then
  printf 'Warning: could not determine whether the patcher submitted a patch.\n' >&2
  if ((run_rc != 0)); then
    exit "$run_rc"
  fi
  exit 1
fi

if ((patch_count == 0)); then
  printf 'Patcher submitted no patch artifacts.\n' >&2
  if ((run_rc == 0)); then
    exit 1
  fi
  exit "$run_rc"
fi

printf 'Patcher submitted %s patch artifact(s).\n' "$patch_count"
if ((run_rc == 0)); then
  exit 0
fi
if ((run_rc == 124)); then
  printf 'Patcher run ended by timeout or early exit (rc 124), but a patch was submitted.\n' >&2
  exit 0
fi

printf 'Patcher run failed with exit code %s after submitting a patch.\n' "$run_rc" >&2
exit "$run_rc"
