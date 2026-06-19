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
# Each step: "status_name|script_name [args...]|description"
# Phase 1: toolchain layout verification
# Phase 2: Win98 PE compatibility of native toolchain PE binaries
# Phase 3: CMake+Ninja build with cross + native toolchains, Win98 check + wine run
declare -a SMOKE_STEPS=(
  "smoke-layout|smoke-verify-layout.sh|Phase 1: toolchain layout verification"
  "smoke-native-pe|smoke-check-native-pe.sh|Phase 2: native toolchain Win98 PE compatibility"
  "smoke-extras-pe|smoke-check-extras-pe.sh|Phase 2b: extras toolset Win98 PE compatibility"
  "smoke-cmake-cross|smoke-cmake-build.sh cross ${JOBS}|Phase 3a: cross toolchain CMake build + Win98 check + wine run"
  "smoke-cmake-native|smoke-cmake-build.sh native ${JOBS}|Phase 3b: native toolchain CMake build + Win98 check + wine run"
  "smoke-extras-wine|smoke-extras-wine-version.sh|Phase 3c: extras toolset wine --version smoke"
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
  local step_log="$LOG_DIR/${status_name}-${TIMESTAMP}.log"

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
  IFS='|' read -r status_name script_and_args description <<< "$step_def"
  if ! run_smoke_step "$status_name" "$script_and_args" "$description"; then
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
