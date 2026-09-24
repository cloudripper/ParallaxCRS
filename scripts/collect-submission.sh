#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

DEFAULT_COMPOSE_FILE="$ROOT/configs/finder-claude-code.yaml"
DEFAULT_WORK_DIR="$ROOT/generated/oss-crs-work"
DEFAULT_CRS_NAME="crs-finder-claude-code"

usage() {
  cat <<'EOF'
Usage: scripts/collect-submission.sh --fuzz-proj-path PATH --target-harness NAME (--run-id ID | --latest) [options]

Copies selected CRS artifacts resolved by `oss-crs artifacts` into submissions/
and creates an oss-crs archive from that run's original submit directories.

Options:
  --crs-name NAME             Compose entry name (default: crs-finder-claude-code)
  --out-dir DIR                Export directory (default: submissions/<target>/<crs-name>/<run-id>)
  --include-all                Include exchange data and logs in the oss-crs archive
  --build-id ID                Build ID used while resolving artifacts
  --sanitizer NAME             Sanitizer (default: address)
  --target-source-path PATH    Optional target source override
  --source-override PATH       Alias for --target-source-path
  --compose-file FILE          Compose file (default: configs/finder-claude-code.yaml)
  --work-dir DIR               OSS-CRS work directory (default: generated/oss-crs-work)
  -h, --help                   Show this help
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 2
}

FUZZ_PROJ_PATH=""
TARGET_HARNESS=""
TARGET_SOURCE_PATH=""
RUN_ID=""
BUILD_ID=""
SANITIZER="address"
COMPOSE_FILE="$DEFAULT_COMPOSE_FILE"
WORK_DIR="$DEFAULT_WORK_DIR"
CRS_NAME="$DEFAULT_CRS_NAME"
OUT_DIR=""
LATEST=false
INCLUDE_ALL=false
OUT_DIR_EXPLICIT=false

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
    --run-id)
      (($# >= 2)) || die '--run-id requires an ID'
      RUN_ID="$2"
      shift
      ;;
    --crs-name)
      (($# >= 2)) || die '--crs-name requires a name'
      CRS_NAME="$2"
      shift
      ;;
    --latest)
      LATEST=true
      ;;
    --build-id)
      (($# >= 2)) || die '--build-id requires an ID'
      BUILD_ID="$2"
      shift
      ;;
    --sanitizer)
      (($# >= 2)) || die '--sanitizer requires a value'
      SANITIZER="$2"
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
    --out-dir)
      (($# >= 2)) || die '--out-dir requires a directory'
      OUT_DIR="$2"
      OUT_DIR_EXPLICIT=true
      shift
      ;;
    --include-all)
      INCLUDE_ALL=true
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
[[ -z "$RUN_ID" || "$LATEST" == false ]] || die 'Use either --run-id or --latest, not both'
[[ -n "$RUN_ID" || "$LATEST" == true ]] || die 'Provide --run-id or --latest to avoid an interactive selection'

command -v uv >/dev/null 2>&1 || die 'uv is required. Run scripts/setup.sh for diagnostics.'
command -v python3 >/dev/null 2>&1 || die 'python3 is required to parse artifact JSON.'

artifact_json="$(mktemp)"
artifact_fields="$(mktemp)"
trap 'rm -f "$artifact_json" "$artifact_fields"' EXIT

PRINT_ARGS=(--fuzz-proj-path "$FUZZ_PROJ_PATH" --target-harness "$TARGET_HARNESS" --sanitizer "$SANITIZER" --compose-file "$COMPOSE_FILE" --work-dir "$WORK_DIR")
if [[ -n "$TARGET_SOURCE_PATH" ]]; then
  PRINT_ARGS+=(--target-source-path "$TARGET_SOURCE_PATH")
fi
if [[ -n "$BUILD_ID" ]]; then
  PRINT_ARGS+=(--build-id "$BUILD_ID")
fi
if [[ -n "$RUN_ID" ]]; then
  PRINT_ARGS+=(--run-id "$RUN_ID")
else
  PRINT_ARGS+=(--latest)
fi

"$ROOT/scripts/print-artifacts.sh" --crs-name "$CRS_NAME" "${PRINT_ARGS[@]}" > "$artifact_json"

python3 - "$artifact_json" "$CRS_NAME" > "$artifact_fields" <<'PY'
import json
import sys

json_path = sys.argv[1]
crs_name = sys.argv[2]

with open(json_path, encoding="utf-8") as f:
    data = json.load(f)

crs = data.get("crs", {}).get(crs_name)
if not isinstance(crs, dict):
    raise SystemExit(
        f"Artifact JSON has no crs[{crs_name!r}] entry. "
        "Check the compose entry name."
    )

for value in (
    data.get("run_id"),
    crs.get("submit_dir"),
    crs.get("pov"),
    crs.get("seed"),
    crs.get("bug_candidate"),
    crs.get("patch"),
):
    print("" if value is None else str(value))
PY

mapfile -t fields < "$artifact_fields"
[[ ${#fields[@]} -eq 6 ]] || die 'Could not parse the expected CRS artifact paths.'

RESOLVED_RUN_ID="${fields[0]}"
SUBMIT_DIR="${fields[1]}"
POV_DIR="${fields[2]}"
SEED_DIR="${fields[3]}"
BUG_CANDIDATE_DIR="${fields[4]}"
PATCH_DIR="${fields[5]}"
[[ -n "$RESOLVED_RUN_ID" ]] || die 'Artifact JSON did not contain a run_id.'

if [[ -z "$OUT_DIR" ]]; then
  target_name="$(basename "${FUZZ_PROJ_PATH%/}")"
  [[ -n "$target_name" ]] || target_name='target'
  OUT_DIR="$ROOT/submissions/$target_name/$CRS_NAME/$RESOLVED_RUN_ID"
fi
if [[ -e "$OUT_DIR" && "$OUT_DIR_EXPLICIT" == false ]]; then
  die "Default export directory already exists: $OUT_DIR (pass --out-dir to choose an existing directory)"
fi
mkdir -p "$OUT_DIR"
cp "$artifact_json" "$OUT_DIR/artifacts.json"

copy_artifact_dir() {
  local source_dir="$1"
  local output_name="$2"

  if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
    printf 'No %s directory exists for this run.\n' "$output_name"
    return 0
  fi

  local destination="$OUT_DIR/$output_name"
  mkdir -p "$destination"
  cp -a "$source_dir/." "$destination/"
  file_count="$(find "$destination" -type f | wc -l | tr -d ' ')"
  printf 'Exported %s file(s) to %s\n' "$file_count" "$destination"
}

copy_artifact_dir "$POV_DIR" povs
copy_artifact_dir "$SEED_DIR" seeds
copy_artifact_dir "$BUG_CANDIDATE_DIR" bug-candidates
copy_artifact_dir "$PATCH_DIR" patches

{
  printf 'crs_name=%s\n' "$CRS_NAME"
  printf 'run_id=%s\n' "$RESOLVED_RUN_ID"
  printf 'submit_dir=%s\n' "$SUBMIT_DIR"
  printf 'pov_dir=%s\n' "$POV_DIR"
  printf 'seed_dir=%s\n' "$SEED_DIR"
  printf 'bug_candidate_dir=%s\n' "$BUG_CANDIDATE_DIR"
  printf 'patch_dir=%s\n' "$PATCH_DIR"
} > "$OUT_DIR/collection-metadata.txt"

OSS_CRS=(uv run --project "$ROOT/oss-crs" oss-crs)
ARCHIVE_PATH="$OUT_DIR/oss-crs-submission.tar.gz"
ARCHIVE_ARGS=(archive --compose-file "$COMPOSE_FILE" --work-dir "$WORK_DIR" --fuzz-proj-path "$FUZZ_PROJ_PATH" --target-harness "$TARGET_HARNESS" --run-id "$RESOLVED_RUN_ID" --sanitizer "$SANITIZER" --out "$ARCHIVE_PATH")
if [[ -n "$TARGET_SOURCE_PATH" ]]; then
  ARCHIVE_ARGS+=(--target-source-path "$TARGET_SOURCE_PATH")
fi
if [[ "$INCLUDE_ALL" == true ]]; then
  ARCHIVE_ARGS+=(--all)
fi

"${OSS_CRS[@]}" "${ARCHIVE_ARGS[@]}"
printf 'Collected %s submission at %s\n' "$CRS_NAME" "$OUT_DIR"
