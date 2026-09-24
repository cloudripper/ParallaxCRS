#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

DEFAULT_COMPOSE_FILE="$ROOT/configs/finder-parallax.yaml"
DEFAULT_WORK_DIR="$ROOT/generated/oss-crs-work"
DEFAULT_CRS_NAME="crs-finder-parallax"

usage() {
  cat <<'EOF'
Usage: scripts/run-finder.sh --fuzz-proj-path PATH --target-harness NAME [options]

Runs a local Finder through:
  oss-crs prepare -> oss-crs build-target -> oss-crs run -> oss-crs artifacts

Required:
  --fuzz-proj-path PATH       OSS-Fuzz project directory
  --target-harness NAME       Harness binary to analyze

Options:
  --target-source-path PATH   Local source override for the target image
  --source-override PATH      Alias for --target-source-path
  --diff FILE                 Delta diff; passed to both build-target and run
  --seed-dir DIR              Initial seed corpus passed to run
  --sanitizer NAME            Sanitizer (default: address)
  --timeout SECONDS           Run timeout in seconds (default: 3600)
  --build-id ID               Reuse or name a build; generated when building
  --run-id ID                 Name a run; generated when omitted
  --early-exit                Stop after the first submitted PoV
  --auth-mode MODE            litellm (default), or oauth for Claude Code
  --crs-name NAME             Compose entry name (default: crs-finder-parallax)
  --skip-prepare              Skip oss-crs prepare
  --skip-build                Reuse an existing --build-id; errors if it is omitted
  --compose-file FILE         Compose file (default: configs/finder-parallax.yaml)
  --work-dir DIR              OSS-CRS work directory (default: generated/oss-crs-work)
  -h, --help                  Show this help

An oss-crs run exit code of 124 means timeout or early exit. This script still
prints artifacts for that result and preserves the 124 exit code.
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
DIFF_PATH=""
SEED_DIR=""
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
CRS_NAME="$DEFAULT_CRS_NAME"

while (($#)); do
  case "$1" in
    --fuzz-proj-path|--target|--target-path)
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
      CRS_NAME="$2"
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
[[ -n "$CRS_NAME" ]] || die '--crs-name must not be empty'
[[ -d "$FUZZ_PROJ_PATH" ]] || die "Fuzz project directory does not exist: $FUZZ_PROJ_PATH"
[[ -f "$COMPOSE_FILE" ]] || die "Compose file does not exist: $COMPOSE_FILE"
[[ -z "$TARGET_SOURCE_PATH" || -d "$TARGET_SOURCE_PATH" ]] || die "Target source override is not a directory: $TARGET_SOURCE_PATH"
[[ -z "$DIFF_PATH" || -f "$DIFF_PATH" ]] || die "Diff file does not exist: $DIFF_PATH"
[[ -z "$SEED_DIR" || -d "$SEED_DIR" ]] || die "Seed directory does not exist: $SEED_DIR"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die '--timeout must be a positive integer'
[[ "$AUTH_MODE" == litellm || "$AUTH_MODE" == oauth ]] || die '--auth-mode must be litellm or oauth'

require_command uv
require_command docker
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
  BUILD_ID="finder-build-${timestamp}-$$"
fi
if [[ -z "$RUN_ID" ]]; then
  RUN_ID="finder-run-${timestamp}-$$"
fi

OSS_CRS=(uv run --project "$ROOT/oss-crs" oss-crs)
COMMON=(--compose-file "$COMPOSE_FILE" --work-dir "$WORK_DIR")
TARGET_ARGS=(--fuzz-proj-path "$FUZZ_PROJ_PATH")
if [[ -n "$TARGET_SOURCE_PATH" ]]; then
  TARGET_ARGS+=(--target-source-path "$TARGET_SOURCE_PATH")
fi

printf 'Finder run ID: %s\n' "$RUN_ID"
printf 'Finder build ID: %s%s\n' "$BUILD_ID" \
  "$([[ "$SKIP_BUILD" == true ]] && printf ' (skip-build)')"

if [[ "$SKIP_PREPARE" == false ]]; then
  "${OSS_CRS[@]}" prepare "${COMMON[@]}"
fi

if [[ "$SKIP_BUILD" == false ]]; then
  BUILD_ARGS=(build-target "${COMMON[@]}" "${TARGET_ARGS[@]}" --build-id "$BUILD_ID" --sanitizer "$SANITIZER")
  if [[ -n "$DIFF_PATH" ]]; then
    # Delta-mode target builds need the same diff that the run will consume.
    BUILD_ARGS+=(--diff "$DIFF_PATH")
  fi
  "${OSS_CRS[@]}" "${BUILD_ARGS[@]}"
fi

RUN_ARGS=(run "${COMMON[@]}" "${TARGET_ARGS[@]}" --target-harness "$TARGET_HARNESS" --run-id "$RUN_ID" --sanitizer "$SANITIZER" --timeout "$TIMEOUT")
if [[ -n "$BUILD_ID" ]]; then
  RUN_ARGS+=(--build-id "$BUILD_ID")
fi
if [[ -n "$DIFF_PATH" ]]; then
  RUN_ARGS+=(--diff "$DIFF_PATH")
fi
if [[ -n "$SEED_DIR" ]]; then
  RUN_ARGS+=(--seed-dir "$SEED_DIR")
fi
if [[ "$EARLY_EXIT" == true ]]; then
  RUN_ARGS+=(--early-exit)
fi

set +e
"${OSS_CRS[@]}" "${RUN_ARGS[@]}"
run_rc=$?
set -e

ARTIFACT_ARGS=(--crs-name "$CRS_NAME" --fuzz-proj-path "$FUZZ_PROJ_PATH" --target-harness "$TARGET_HARNESS" --run-id "$RUN_ID" --sanitizer "$SANITIZER" --compose-file "$COMPOSE_FILE" --work-dir "$WORK_DIR")
if [[ -n "$BUILD_ID" ]]; then
  ARTIFACT_ARGS+=(--build-id "$BUILD_ID")
fi
if [[ -n "$TARGET_SOURCE_PATH" ]]; then
  ARTIFACT_ARGS+=(--target-source-path "$TARGET_SOURCE_PATH")
fi

printf '\nResolved OSS-CRS artifacts:\n'
set +e
"$ROOT/scripts/print-artifacts.sh" "${ARTIFACT_ARGS[@]}"
artifacts_rc=$?
set -e

if ((artifacts_rc != 0)); then
  printf 'Warning: oss-crs artifacts failed with exit code %s.\n' "$artifacts_rc" >&2
fi

if ((run_rc == 124)); then
  printf 'Finder run ended by timeout or early exit (rc 124); artifacts were requested above.\n' >&2
  exit 124
fi
if ((run_rc != 0)); then
  printf 'Finder run failed with exit code %s; artifacts were requested above.\n' "$run_rc" >&2
  exit "$run_rc"
fi

exit "$artifacts_rc"
