#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

DEFAULT_COMPOSE_FILE="$ROOT/configs/finder-claude-code.yaml"
DEFAULT_WORK_DIR="$ROOT/generated/oss-crs-work"

usage() {
  cat <<'EOF'
Usage: scripts/clean.sh [options]

Wraps `oss-crs clean` for the local Claude finder. Cleanup remains interactive
unless --yes is supplied.

Options:
  --phase all|prepare|build-target|run  Scope cleanup (default: all)
  --artifacts                          Also delete generated OSS-CRS artifacts
  --yes                                Skip the oss-crs confirmation prompt
  --fuzz-proj-path PATH                Needed to include target-image cleanup
  --target-source-path PATH            Optional source override with target cleanup
  --source-override PATH               Alias for --target-source-path
  --compose-file FILE                  Compose file (default: configs/finder-claude-code.yaml)
  --work-dir DIR                       OSS-CRS work directory (default: generated/oss-crs-work)
  -h, --help                           Show this help
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 2
}

PHASE='all'
ARTIFACTS=false
YES=false
FUZZ_PROJ_PATH=''
TARGET_SOURCE_PATH=''
COMPOSE_FILE="$DEFAULT_COMPOSE_FILE"
WORK_DIR="$DEFAULT_WORK_DIR"

while (($#)); do
  case "$1" in
    --phase)
      (($# >= 2)) || die '--phase requires a value'
      PHASE="$2"
      shift
      ;;
    --artifacts)
      ARTIFACTS=true
      ;;
    --yes|-y)
      YES=true
      ;;
    --fuzz-proj-path|--target|--target-path)
      (($# >= 2)) || die "$1 requires a path"
      FUZZ_PROJ_PATH="$2"
      shift
      ;;
    --target-source-path|--source-override)
      (($# >= 2)) || die "$1 requires a path"
      TARGET_SOURCE_PATH="$2"
      shift
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

case "$PHASE" in
  all|prepare|build-target|run)
    ;;
  *)
    die '--phase must be one of: all, prepare, build-target, run'
    ;;
esac

[[ -f "$COMPOSE_FILE" ]] || die "Compose file does not exist: $COMPOSE_FILE"
[[ -z "$FUZZ_PROJ_PATH" || -d "$FUZZ_PROJ_PATH" ]] || die "Fuzz project directory does not exist: $FUZZ_PROJ_PATH"
[[ -z "$TARGET_SOURCE_PATH" || -d "$TARGET_SOURCE_PATH" ]] || die "Target source override is not a directory: $TARGET_SOURCE_PATH"
[[ -z "$TARGET_SOURCE_PATH" || -n "$FUZZ_PROJ_PATH" ]] || die '--target-source-path requires --fuzz-proj-path'
if [[ "$PHASE" == 'prepare' && ( -n "$FUZZ_PROJ_PATH" || -n "$TARGET_SOURCE_PATH" ) ]]; then
  die '--fuzz-proj-path and --target-source-path are not accepted with --phase prepare'
fi

command -v uv >/dev/null 2>&1 || die 'uv is required. Run scripts/setup.sh for diagnostics.'

OSS_CRS=(uv run --project "$ROOT/oss-crs" oss-crs)
ARGS=(clean)
if [[ "$PHASE" != 'all' ]]; then
  ARGS+=("$PHASE")
fi
ARGS+=(--compose-file "$COMPOSE_FILE" --work-dir "$WORK_DIR")
if [[ "$ARTIFACTS" == true ]]; then
  ARGS+=(--artifacts)
fi
if [[ "$YES" == true ]]; then
  ARGS+=(--yes)
fi
if [[ -n "$FUZZ_PROJ_PATH" && "$PHASE" != 'prepare' ]]; then
  ARGS+=(--fuzz-proj-path "$FUZZ_PROJ_PATH")
fi
if [[ -n "$TARGET_SOURCE_PATH" && "$PHASE" != 'prepare' ]]; then
  ARGS+=(--target-source-path "$TARGET_SOURCE_PATH")
fi

"${OSS_CRS[@]}" "${ARGS[@]}"
