#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

DEFAULT_WORK_ROOT="$ROOT/generated/oss-crs-work"
ENTRYPOINT="${E2E_ENTRYPOINT:-scripts/run-e2e.sh}"

usage() {
  printf 'Usage: %s --fuzz-proj-path PATH --target-harness NAME [options]\n\n' "$ENTRYPOINT"
  cat <<'EOF'
Runs a local CRS workflow in two isolated stages:
  Finder -> submitted PoVs -> Patcher -> submitted .diff patch

Finder PoV files are staged before the Patcher starts.

Required:
  --fuzz-proj-path PATH       OSS-Fuzz project directory
  --target-harness NAME       Harness binary to analyze and patch

Common target options:
  --target-source-path PATH   Local source override for the target image
  --source-override PATH      Alias for --target-source-path
  --diff FILE                 Delta diff supplied to both stages
  --seed-dir DIR              Initial seed corpus supplied to both stages
  --bug-candidate FILE        Optional patcher bug-candidate report
  --bug-candidate-dir DIR     Optional patcher bug-candidate directory
  --sanitizer NAME            Sanitizer (default: address)

Stage options:
  --finder-timeout SECONDS    Finder timeout (default: 3600)
  --patcher-timeout SECONDS   Patcher timeout (default: 3600)
  --finder-early-exit         Stop Finder after its first submitted PoV
  --patcher-early-exit        Stop Patcher after its first submitted patch
  --auth-mode MODE            litellm (default), or oauth for Claude Code
  --finder-run-id ID          Finder run ID (generated when omitted)
  --finder-build-id ID        Finder build ID (generated when omitted)
  --patcher-run-id ID         Patcher run ID (generated when omitted)
  --patcher-build-id ID       Patcher build ID (generated when omitted)
  --finder-compose-file FILE  Override the Finder compose file
  --patcher-compose-file FILE Override the Patcher compose file
  --finder-work-dir DIR       Override the Finder work directory
  --patcher-work-dir DIR      Override the Patcher work directory
  --e2e-id ID                 Local run label (generated when omitted)
  --out-dir DIR               Local bundle directory (default: submissions/<target>/e2e-<e2e-id>)
  -h, --help                  Show this help

The local bundle contains finder-artifacts.json, patcher-artifacts.json, povs/, patches/, and metadata.
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

safe_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "Invalid ID: $1"
}

canonical_dir() {
  local path="$1"
  mkdir -p "$path"
  (cd "$path" && pwd -P)
}

AGENT="${E2E_AGENT:-}"
AGENT_LABEL=""
AGENT_SLUG=""
FINDER_NAME=""
PATCHER_NAME=""
FUZZ_PROJ_PATH=""
TARGET_HARNESS=""
TARGET_SOURCE_PATH=""
DIFF_PATH=""
SEED_DIR=""
BUG_CANDIDATE_PATH=""
BUG_CANDIDATE_DIR=""
SANITIZER="address"
FINDER_TIMEOUT="3600"
PATCHER_TIMEOUT="3600"
FINDER_EARLY_EXIT=false
PATCHER_EARLY_EXIT=false
AUTH_MODE="litellm"
FINDER_COMPOSE_FILE=""
PATCHER_COMPOSE_FILE=""
FINDER_WORK_DIR=""
PATCHER_WORK_DIR=""
E2E_ID=""
FINDER_RUN_ID=""
FINDER_BUILD_ID=""
PATCHER_RUN_ID=""
PATCHER_BUILD_ID=""
OUT_DIR=""

while (($#)); do
  case "$1" in
    --agent)
      (($# >= 2)) || die '--agent requires claude-code or codex'
      AGENT="$2"
      shift
      ;;
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
    --finder-timeout)
      (($# >= 2)) || die '--finder-timeout requires seconds'
      FINDER_TIMEOUT="$2"
      shift
      ;;
    --patcher-timeout)
      (($# >= 2)) || die '--patcher-timeout requires seconds'
      PATCHER_TIMEOUT="$2"
      shift
      ;;
    --finder-early-exit)
      FINDER_EARLY_EXIT=true
      ;;
    --patcher-early-exit)
      PATCHER_EARLY_EXIT=true
      ;;
    --auth-mode)
      (($# >= 2)) || die '--auth-mode requires litellm or oauth'
      AUTH_MODE="$2"
      shift
      ;;
    --finder-run-id)
      (($# >= 2)) || die '--finder-run-id requires an ID'
      FINDER_RUN_ID="$2"
      shift
      ;;
    --finder-build-id)
      (($# >= 2)) || die '--finder-build-id requires an ID'
      FINDER_BUILD_ID="$2"
      shift
      ;;
    --patcher-run-id)
      (($# >= 2)) || die '--patcher-run-id requires an ID'
      PATCHER_RUN_ID="$2"
      shift
      ;;
    --patcher-build-id)
      (($# >= 2)) || die '--patcher-build-id requires an ID'
      PATCHER_BUILD_ID="$2"
      shift
      ;;
    --finder-compose-file)
      (($# >= 2)) || die '--finder-compose-file requires a file'
      FINDER_COMPOSE_FILE="$2"
      shift
      ;;
    --patcher-compose-file)
      (($# >= 2)) || die '--patcher-compose-file requires a file'
      PATCHER_COMPOSE_FILE="$2"
      shift
      ;;
    --finder-work-dir)
      (($# >= 2)) || die '--finder-work-dir requires a directory'
      FINDER_WORK_DIR="$2"
      shift
      ;;
    --patcher-work-dir)
      (($# >= 2)) || die '--patcher-work-dir requires a directory'
      PATCHER_WORK_DIR="$2"
      shift
      ;;
    --e2e-id)
      (($# >= 2)) || die '--e2e-id requires an ID'
      E2E_ID="$2"
      shift
      ;;
    --out-dir)
      (($# >= 2)) || die '--out-dir requires a directory'
      OUT_DIR="$2"
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

case "$AGENT" in
  claude-code)
    AGENT_LABEL="Claude Code"
    AGENT_SLUG="claude"
    FINDER_NAME="crs-finder-claude-code"
    PATCHER_NAME="crs-patcher-claude-code"
    [[ -n "$FINDER_COMPOSE_FILE" ]] || FINDER_COMPOSE_FILE="$ROOT/configs/finder-claude-code.yaml"
    [[ -n "$PATCHER_COMPOSE_FILE" ]] || PATCHER_COMPOSE_FILE="$ROOT/configs/patcher-claude-code.yaml"
    [[ -n "$FINDER_WORK_DIR" ]] || FINDER_WORK_DIR="$DEFAULT_WORK_ROOT/finder-claude-code"
    [[ -n "$PATCHER_WORK_DIR" ]] || PATCHER_WORK_DIR="$DEFAULT_WORK_ROOT/patcher-claude-code"
    ;;
  codex)
    AGENT_LABEL="Codex"
    AGENT_SLUG="codex"
    FINDER_NAME="crs-finder-codex"
    PATCHER_NAME="crs-patcher-codex"
    [[ -n "$FINDER_COMPOSE_FILE" ]] || FINDER_COMPOSE_FILE="$ROOT/configs/finder-codex.yaml"
    [[ -n "$PATCHER_COMPOSE_FILE" ]] || PATCHER_COMPOSE_FILE="$ROOT/configs/patcher-codex.yaml"
    [[ -n "$FINDER_WORK_DIR" ]] || FINDER_WORK_DIR="$DEFAULT_WORK_ROOT/finder-codex"
    [[ -n "$PATCHER_WORK_DIR" ]] || PATCHER_WORK_DIR="$DEFAULT_WORK_ROOT/patcher-codex"
    ;;
  *)
    die '--agent must be claude-code or codex'
    ;;
esac

[[ -n "$FUZZ_PROJ_PATH" ]] || die '--fuzz-proj-path is required'
[[ -n "$TARGET_HARNESS" ]] || die '--target-harness is required'
[[ -d "$FUZZ_PROJ_PATH" ]] || die "Fuzz project directory does not exist: $FUZZ_PROJ_PATH"
[[ -f "$FINDER_COMPOSE_FILE" ]] || die "Finder compose file does not exist: $FINDER_COMPOSE_FILE"
[[ -f "$PATCHER_COMPOSE_FILE" ]] || die "Patcher compose file does not exist: $PATCHER_COMPOSE_FILE"
[[ -z "$TARGET_SOURCE_PATH" || -d "$TARGET_SOURCE_PATH" ]] || die "Target source override is not a directory: $TARGET_SOURCE_PATH"
[[ -z "$DIFF_PATH" || -f "$DIFF_PATH" ]] || die "Diff file does not exist: $DIFF_PATH"
[[ -z "$SEED_DIR" || -d "$SEED_DIR" ]] || die "Seed directory does not exist: $SEED_DIR"
[[ -z "$BUG_CANDIDATE_PATH" || -f "$BUG_CANDIDATE_PATH" ]] || die "Bug-candidate file does not exist: $BUG_CANDIDATE_PATH"
[[ -z "$BUG_CANDIDATE_DIR" || -d "$BUG_CANDIDATE_DIR" ]] || die "Bug-candidate directory does not exist: $BUG_CANDIDATE_DIR"
[[ -z "$BUG_CANDIDATE_PATH" || -z "$BUG_CANDIDATE_DIR" ]] || die 'Use either --bug-candidate or --bug-candidate-dir, not both'
[[ "$FINDER_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die '--finder-timeout must be a positive integer'
[[ "$PATCHER_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die '--patcher-timeout must be a positive integer'
[[ "$AUTH_MODE" == litellm || "$AUTH_MODE" == oauth ]] || die '--auth-mode must be litellm or oauth'
[[ "$AGENT" == claude-code || "$AUTH_MODE" == litellm ]] || die '--auth-mode oauth is supported only for Claude Code'

require_command python3

if [[ -z "$E2E_ID" ]]; then
  E2E_ID="${AGENT_SLUG}-e2e-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
safe_id "$E2E_ID"

if [[ -z "$FINDER_BUILD_ID" ]]; then
  FINDER_BUILD_ID="finder-build-$E2E_ID"
fi
if [[ -z "$FINDER_RUN_ID" ]]; then
  FINDER_RUN_ID="finder-run-$E2E_ID"
fi
if [[ -z "$PATCHER_BUILD_ID" ]]; then
  PATCHER_BUILD_ID="patcher-build-$E2E_ID"
fi
if [[ -z "$PATCHER_RUN_ID" ]]; then
  PATCHER_RUN_ID="patcher-run-$E2E_ID"
fi
safe_id "$FINDER_BUILD_ID"
safe_id "$FINDER_RUN_ID"
safe_id "$PATCHER_BUILD_ID"
safe_id "$PATCHER_RUN_ID"

FINDER_WORK_DIR="$(canonical_dir "$FINDER_WORK_DIR")"
PATCHER_WORK_DIR="$(canonical_dir "$PATCHER_WORK_DIR")"
[[ "$FINDER_WORK_DIR" != "$PATCHER_WORK_DIR" ]] || die 'Finder and patcher must use separate --*-work-dir values.'

STAGING_DIR="$ROOT/generated/${AGENT_SLUG}-e2e/$E2E_ID"
[[ ! -e "$STAGING_DIR" ]] || die "E2E staging directory already exists: $STAGING_DIR"
mkdir -p "$STAGING_DIR"

if [[ -z "$OUT_DIR" ]]; then
  target_name="$(basename "${FUZZ_PROJ_PATH%/}")"
  [[ -n "$target_name" ]] || target_name='target'
  OUT_DIR="$ROOT/submissions/$target_name/e2e-$E2E_ID"
fi
[[ ! -e "$OUT_DIR" ]] || die "Output directory already exists: $OUT_DIR"

COMMON_TARGET_ARGS=(--fuzz-proj-path "$FUZZ_PROJ_PATH" --target-harness "$TARGET_HARNESS" --sanitizer "$SANITIZER")
if [[ -n "$TARGET_SOURCE_PATH" ]]; then
  COMMON_TARGET_ARGS+=(--target-source-path "$TARGET_SOURCE_PATH")
fi
if [[ -n "$DIFF_PATH" ]]; then
  COMMON_TARGET_ARGS+=(--diff "$DIFF_PATH")
fi
printf 'E2E ID: %s\n' "$E2E_ID"
printf 'Finder work dir: %s\n' "$FINDER_WORK_DIR"
printf 'Patcher work dir: %s\n' "$PATCHER_WORK_DIR"

FINDER_ARGS=("${COMMON_TARGET_ARGS[@]}" --timeout "$FINDER_TIMEOUT" --build-id "$FINDER_BUILD_ID" --run-id "$FINDER_RUN_ID" --auth-mode "$AUTH_MODE" --crs-name "$FINDER_NAME" --compose-file "$FINDER_COMPOSE_FILE" --work-dir "$FINDER_WORK_DIR")
if [[ -n "$SEED_DIR" ]]; then
  FINDER_ARGS+=(--seed-dir "$SEED_DIR")
fi
if [[ "$FINDER_EARLY_EXIT" == true ]]; then
  FINDER_ARGS+=(--early-exit)
fi

set +e
"$ROOT/scripts/run-finder.sh" "${FINDER_ARGS[@]}"
finder_rc=$?
set -e

if ((finder_rc != 0 && finder_rc != 124)); then
  printf 'Finder stage failed with exit code %s. Patcher will not start.\n' "$finder_rc" >&2
  exit "$finder_rc"
fi

FINDER_ARTIFACTS_JSON="$STAGING_DIR/finder-artifacts.json"
FINDER_ARTIFACT_ARGS=(
  --crs-name "$FINDER_NAME"
  --fuzz-proj-path "$FUZZ_PROJ_PATH"
  --target-harness "$TARGET_HARNESS"
  --run-id "$FINDER_RUN_ID"
  --build-id "$FINDER_BUILD_ID"
  --sanitizer "$SANITIZER"
  --compose-file "$FINDER_COMPOSE_FILE"
  --work-dir "$FINDER_WORK_DIR"
)
if [[ -n "$TARGET_SOURCE_PATH" ]]; then
  FINDER_ARTIFACT_ARGS+=(--target-source-path "$TARGET_SOURCE_PATH")
fi
"$ROOT/scripts/print-artifacts.sh" "${FINDER_ARTIFACT_ARGS[@]}" > "$FINDER_ARTIFACTS_JSON"

POV_STAGING_DIR="$STAGING_DIR/povs"
pov_count="$(python3 - "$FINDER_ARTIFACTS_JSON" "$FINDER_NAME" "$POV_STAGING_DIR" <<'PY'
import json
import re
import shutil
import sys
from pathlib import Path

artifacts_path = Path(sys.argv[1])
crs_name = sys.argv[2]
destination = Path(sys.argv[3])

with artifacts_path.open(encoding="utf-8") as f:
    artifacts = json.load(f)

crs = artifacts.get("crs", {}).get(crs_name)
if not isinstance(crs, dict):
    raise SystemExit(f"Artifact JSON has no crs[{crs_name!r}] entry.")

source_value = crs.get("pov")
if not isinstance(source_value, str):
    raise SystemExit("Finder artifact JSON has no PoV directory.")
source = Path(source_value)
if not source.is_dir():
    raise SystemExit(f"Finder PoV directory does not exist: {source}")

destination.mkdir(parents=True, exist_ok=False)
manifest = []
for path in sorted(source.rglob("*")):
    if path.is_symlink() or not path.is_file() or path.name.startswith("."):
        continue
    index = len(manifest) + 1
    safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", path.name).lstrip(".") or "pov"
    staged_name = f"pov-{index:04d}-{safe_name}"
    staged = destination / staged_name
    shutil.copyfile(path, staged)
    manifest.append({"source": str(path.relative_to(source)), "staged": staged_name})

(destination.parent / "pov-manifest.json").write_text(
    json.dumps(manifest, indent=2) + "\n"
)
print(len(manifest))
PY
)"

if ((pov_count == 0)); then
  printf 'Finder produced no PoV artifacts. Patcher will not start.\n' >&2
  exit 1
fi
printf 'Staged %s Finder PoV artifact(s) for Patcher input.\n' "$pov_count"

PATCHER_ARGS=(--fuzz-proj-path "$FUZZ_PROJ_PATH" --target-harness "$TARGET_HARNESS" --sanitizer "$SANITIZER" --pov-dir "$POV_STAGING_DIR" --timeout "$PATCHER_TIMEOUT" --build-id "$PATCHER_BUILD_ID" --run-id "$PATCHER_RUN_ID" --auth-mode "$AUTH_MODE" --crs-name "$PATCHER_NAME" --compose-file "$PATCHER_COMPOSE_FILE" --work-dir "$PATCHER_WORK_DIR")
if [[ -n "$TARGET_SOURCE_PATH" ]]; then
  PATCHER_ARGS+=(--target-source-path "$TARGET_SOURCE_PATH")
fi
if [[ -n "$DIFF_PATH" ]]; then
  PATCHER_ARGS+=(--diff "$DIFF_PATH")
fi
if [[ -n "$SEED_DIR" ]]; then
  PATCHER_ARGS+=(--seed-dir "$SEED_DIR")
fi
if [[ -n "$BUG_CANDIDATE_PATH" ]]; then
  PATCHER_ARGS+=(--bug-candidate "$BUG_CANDIDATE_PATH")
elif [[ -n "$BUG_CANDIDATE_DIR" ]]; then
  PATCHER_ARGS+=(--bug-candidate-dir "$BUG_CANDIDATE_DIR")
fi
if [[ "$PATCHER_EARLY_EXIT" == true ]]; then
  PATCHER_ARGS+=(--early-exit)
fi

"$ROOT/scripts/run-patcher.sh" "${PATCHER_ARGS[@]}"

PATCHER_ARTIFACTS_JSON="$STAGING_DIR/patcher-artifacts.json"
PATCHER_ARTIFACT_ARGS=(
  --crs-name "$PATCHER_NAME"
  --fuzz-proj-path "$FUZZ_PROJ_PATH"
  --target-harness "$TARGET_HARNESS"
  --run-id "$PATCHER_RUN_ID"
  --build-id "$PATCHER_BUILD_ID"
  --sanitizer "$SANITIZER"
  --compose-file "$PATCHER_COMPOSE_FILE"
  --work-dir "$PATCHER_WORK_DIR"
)
if [[ -n "$TARGET_SOURCE_PATH" ]]; then
  PATCHER_ARTIFACT_ARGS+=(--target-source-path "$TARGET_SOURCE_PATH")
fi
"$ROOT/scripts/print-artifacts.sh" "${PATCHER_ARTIFACT_ARGS[@]}" > "$PATCHER_ARTIFACTS_JSON"

mkdir -p "$OUT_DIR"
cp "$FINDER_ARTIFACTS_JSON" "$OUT_DIR/finder-artifacts.json"
cp "$PATCHER_ARTIFACTS_JSON" "$OUT_DIR/patcher-artifacts.json"
cp -a "$POV_STAGING_DIR" "$OUT_DIR/povs"
cp "$STAGING_DIR/pov-manifest.json" "$OUT_DIR/pov-manifest.json"

patch_count="$(python3 - "$PATCHER_ARTIFACTS_JSON" "$PATCHER_NAME" "$OUT_DIR/patches" <<'PY'
import json
import re
import shutil
import sys
from pathlib import Path

artifacts_path = Path(sys.argv[1])
crs_name = sys.argv[2]
destination = Path(sys.argv[3])

with artifacts_path.open(encoding="utf-8") as f:
    artifacts = json.load(f)

crs = artifacts.get("crs", {}).get(crs_name)
if not isinstance(crs, dict):
    raise SystemExit(f"Artifact JSON has no crs[{crs_name!r}] entry.")

source_value = crs.get("patch")
if not isinstance(source_value, str):
    raise SystemExit("Patcher artifact JSON has no patch directory.")
source = Path(source_value)
if not source.is_dir():
    raise SystemExit(f"Patcher patch directory does not exist: {source}")

destination.mkdir(parents=True, exist_ok=False)
manifest = []
for path in sorted(source.rglob("*")):
    if (
        path.is_symlink()
        or not path.is_file()
        or path.name.startswith(".")
        or path.suffix != ".diff"
    ):
        continue
    if path.stat().st_size == 0:
        continue
    index = len(manifest) + 1
    safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", path.name).lstrip(".") or "patch.diff"
    staged_name = f"patch-{index:04d}-{safe_name}"
    staged = destination / staged_name
    shutil.copyfile(path, staged)
    manifest.append({"source": str(path.relative_to(source)), "staged": staged_name})

(destination.parent / "patch-manifest.json").write_text(
    json.dumps(manifest, indent=2) + "\n"
)
print(len(manifest))
PY
)"

if ((patch_count == 0)); then
  printf 'Patcher completed but no non-empty .diff artifacts were exported.\n' >&2
  exit 1
fi

python3 - "$FINDER_ARTIFACTS_JSON" "$PATCHER_ARTIFACTS_JSON" "$OUT_DIR/handoff-metadata.json" "$E2E_ID" "$FINDER_NAME" "$PATCHER_NAME" "$pov_count" "$patch_count" <<'PY'
import json
import sys
from pathlib import Path

finder_path = Path(sys.argv[1])
patcher_path = Path(sys.argv[2])
out_path = Path(sys.argv[3])

with finder_path.open(encoding="utf-8") as f:
    finder = json.load(f)
with patcher_path.open(encoding="utf-8") as f:
    patcher = json.load(f)

metadata = {
    "e2e_id": sys.argv[4],
    "finder": {
        "run_id": finder.get("run_id"),
        "build_id": finder.get("build_id"),
        "crs_name": sys.argv[5],
    },
    "patcher": {
        "run_id": patcher.get("run_id"),
        "build_id": patcher.get("build_id"),
        "crs_name": sys.argv[6],
    },
    "staged_pov_count": int(sys.argv[7]),
    "exported_patch_count": int(sys.argv[8]),
}
out_path.write_text(json.dumps(metadata, indent=2) + "\n")
PY

printf '%s E2E local bundle: %s\n' "$AGENT_LABEL" "$OUT_DIR"
printf 'PoVs: %s; patches: %s\n' "$pov_count" "$patch_count"
