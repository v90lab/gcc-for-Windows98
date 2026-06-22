#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# run-smoke-pipeline.sh - Smoke test orchestrator for gcc-for-Windows98
# ============================================================================
# Description: Runs all smoke tests inside the consumer container.
#              Must be called AFTER the consumer image has been built and the
#              consumer service is running (i.e. after run-toolchain-build.sh completes).
#
#              Three phases are executed:
#                Phase 1 — Toolchain layout verification
#                Phase 2 — Win98 PE compatibility of native toolchain binaries
#                Phase 3 — CMake+Ninja build of repro/tests with cross and native
#                           toolchains, followed by Win98 PE check + Wine execution
#
# Environment: Steps execute inside the consumer container:
#   [consumer] – smoke test validation (docker compose exec consumer)
#
# Usage: ./scripts/run-smoke-pipeline.sh [--jobs N] [--help|-h]
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities (also loads docker helpers: consumer_exec, consumer_script)
source "$SCRIPT_DIR/lib/common.sh"

# --- Argument Parsing ---------------------------------------------------------
JOBS="${JOBS:-4}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs|-j)
      JOBS="${2:?--jobs requires a value}"
      shift 2
      ;;
    --help|-h)
      sed -n '/^# ===/,/^# ===/p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      die "Unknown option: $1 (try --help)"
      ;;
  esac
done

# --- Pre-flight Check --------------------------------------------------------
if ! docker compose -f "$PROJECT_DIR/docker-compose.yml" ps --services --filter "status=running" 2>/dev/null | grep -q "consumer"; then
  echo "ERROR: consumer container is not running. Start it with:"
  echo "  docker compose up -d consumer"
  exit 1
fi

# --- Step Definitions --------------------------------------------------------
# Each step: "status_name|script_name [args...]|description[|input1:input2:...]"
#   inputs (optional 4th field): paths relative to repo root. The runner's
#     invalidate_step_if_stale (in common.sh) removes the sentinel if any
#     listed input is newer than it, so the step re-runs. The smoke script
#     itself is auto-included as an implicit input. Without this, smoke
#     sentinels persist across rebuilds and the smoke pipeline silently
#     skips every step once it's passed once — making downstream regressions
#     invisible. The natural per-step input is the package manifest for
#     whichever toolset the smoke step tests, since the manifest is the
#     reliable signal that "the world this smoke step covers has changed".
CROSS_MANIFEST="out/package/gcc-win98-cross-toolchain.json"
NATIVE_MANIFEST="out/package/gcc-win98-native-toolchain.json"
EXTRAS_MANIFEST="out/package/gcc-win98-native-toolchain-extras.json"
declare -a SMOKE_STEPS=(
  "smoke-layout|smoke-verify-layout.sh|Phase 1: toolchain layout verification|${CROSS_MANIFEST}:${NATIVE_MANIFEST}:${EXTRAS_MANIFEST}"
  "smoke-bundled-pe|smoke-bundled-pe-check.sh|Phase 1b: bundled pe-win98-check end-to-end|${CROSS_MANIFEST}:scripts/verifiers/pe-win98-check.sh"
  "smoke-native-pe|smoke-check-native-pe.sh|Phase 2: native toolchain Win98 PE compatibility|${NATIVE_MANIFEST}"
  "smoke-extras-pe|smoke-check-extras-pe.sh|Phase 2b: extras toolset Win98 PE compatibility|${EXTRAS_MANIFEST}"
  "smoke-cmake-cross|smoke-cmake-build.sh cross ${JOBS}|Phase 3a: cross toolchain CMake build + Win98 check + wine run|${CROSS_MANIFEST}:tests/CMakeLists.txt:docker/cmake/cross-toolchain.cmake"
  "smoke-cmake-native|smoke-cmake-build.sh native ${JOBS}|Phase 3b: native toolchain CMake build + Win98 check + wine run|${NATIVE_MANIFEST}:tests/CMakeLists.txt:docker/cmake/native-toolchain.cmake"
  "smoke-extras-wine|smoke-extras-wine-version.sh|Phase 3c: extras toolset wine --version smoke|${EXTRAS_MANIFEST}"
)

# --- Logging Setup -----------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MASTER_LOG="$LOG_DIR/run-smoke-pipeline-${TIMESTAMP}.log"
mkdir -p "$LOG_DIR"

tee -a "$MASTER_LOG" <<EOF
========================================
gcc-for-Windows98 Smoke Test Pipeline
Started: $(date -Iseconds)
Project: $PROJECT_DIR
Jobs:    $JOBS
========================================
EOF

# --- Step Runner -------------------------------------------------------------
run_smoke_step() {
  local status_name="$1"
  local script_and_args="$2"
  local description="$3"
  local inputs="${4:-}"
  local step_log="$LOG_DIR/${status_name}-${TIMESTAMP}.log"

  # Invalidate the sentinel if any declared input is newer than it.
  # script_and_args is "script.sh [args]"; we only want the script for the
  # implicit auto-include.
  local script_only="${script_and_args%% *}"
  invalidate_step_if_stale "$status_name" "$script_only" "$inputs" | tee -a "$MASTER_LOG"

  if is_done "$status_name"; then
    echo "[$(date +%H:%M:%S)] [consumer] === SKIP (done): $description ===" | tee -a "$MASTER_LOG"
    return 0
  fi

  echo "" | tee -a "$MASTER_LOG"
  echo "[$(date +%H:%M:%S)] [consumer] === STEP: $description ===" | tee -a "$MASTER_LOG"

  # Split script name from optional arguments
  read -ra script_parts <<< "$script_and_args"
  local script_name="${script_parts[0]}"
  local extra_args=("${script_parts[@]:1}")

  if consumer_script "$script_name" "${extra_args[@]+"${extra_args[@]}"}" > >(tee "$step_log") 2>&1; then
    mark_done "$status_name"
    echo "[$(date +%H:%M:%S)] [consumer] === OK: $description ===" | tee -a "$MASTER_LOG"
    return 0
  else
    local exit_code=$?
    echo "[$(date +%H:%M:%S)] [consumer] === FAILED: $description (exit=$exit_code) ===" | tee -a "$MASTER_LOG"
    echo "See log: $step_log" | tee -a "$MASTER_LOG"
    return $exit_code
  fi
}

# --- Execute Smoke Steps -----------------------------------------------------
FAILED=0
FAILED_STEP=""

echo "" | tee -a "$MASTER_LOG"
echo "[$(date +%H:%M:%S)] [host] === SMOKE PIPELINE ===" | tee -a "$MASTER_LOG"

for step_def in "${SMOKE_STEPS[@]}"; do
  IFS='|' read -r status_name script_and_args description inputs <<< "$step_def"
  if ! run_smoke_step "$status_name" "$script_and_args" "$description" "$inputs"; then
    FAILED=1
    FAILED_STEP="$description"
    break
  fi
done

# --- Summary -----------------------------------------------------------------
echo "" | tee -a "$MASTER_LOG"
if [[ $FAILED -eq 0 ]]; then
  echo "[$(date +%H:%M:%S)] [host] === SMOKE TESTS PASSED ===" | tee -a "$MASTER_LOG"
  echo "Master log: $MASTER_LOG" | tee -a "$MASTER_LOG"
  exit 0
else
  echo "[$(date +%H:%M:%S)] [host] === SMOKE TESTS FAILED ===" | tee -a "$MASTER_LOG"
  echo "Failed at: $FAILED_STEP" | tee -a "$MASTER_LOG"
  echo "Master log: $MASTER_LOG" | tee -a "$MASTER_LOG"
  exit 1
fi
