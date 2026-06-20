#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# run-toolchain-build.sh - Master orchestration script for gcc-for-Windows98 toolchain build
# ============================================================================
# Description: Builds the complete cross and native Win98 toolchain from source
#
# Environment: Steps execute inside the appropriate Docker container:
#   [host]    – orchestration only (argument parsing, logging, dispatch)
#   [builder] – cross/native toolchain build (docker compose exec toolchain-builder)
#
# Usage: ./scripts/run-toolchain-build.sh [--jobs N] [--target TARGET] [--resume [STEP]] [--generate-patches] [--with-extras|--without-extras] [--help|-h]
#   --jobs N      Parallel build jobs (default: auto-detect)
#   --target T    Target triplet (default: i686-w64-mingw32)
#   --resume [S]  Resume from step S (or auto-detect last completed step)
#   --generate-patches  Regenerate patch folders before prepare steps
#   --with-extras       Build the extras tarball (busybox, make, ctags, diffutils, patch, gdb, muon)
#   --without-extras    Skip the extras tarball
#   --help, -h    Show this help and exit
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source common utilities (also loads docker helpers: builder_exec, builder_script,
# is_done_in_builder, mark_done_in_builder)
source "$SCRIPT_DIR/lib/common.sh"

# --- Argument Parsing ---------------------------------------------------------
RESUME_MODE=""
RESUME_FROM=""
GENERATE_PATCHES="${GENERATE_PATCHES:-0}"
BUILD_EXTRAS="${BUILD_EXTRAS:-1}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)
      JOBS="$2"
      export JOBS
      shift 2
      ;;
    --target)
      TARGET="$2"
      export TARGET
      shift 2
      ;;
    --resume)
      RESUME_MODE="yes"
      if [[ $# -gt 1 && ! "$2" =~ ^-- ]]; then
        RESUME_FROM="$2"
        shift 2
      else
        shift
      fi
      ;;
    --generate-patches)
      GENERATE_PATCHES="1"
      export GENERATE_PATCHES
      shift
      ;;
    --with-extras)
      BUILD_EXTRAS=1
      shift
      ;;
    --without-extras)
      BUILD_EXTRAS=0
      shift
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
export BUILD_EXTRAS

# --- Pre-flight Check --------------------------------------------------------
# Use `compose ps --quiet` + `docker inspect` instead of `compose ps --filter
# "status=running"`, because the latter flag isn't supported on every
# `docker compose` version (notably older Docker Desktop builds on Windows).
check_containers() {
  local cid
  cid=$(docker compose -f "$PROJECT_DIR/docker-compose.yml" ps --quiet toolchain-builder 2>/dev/null | head -n1)

  if [[ -z "$cid" ]]; then
    echo "ERROR: toolchain-builder service has no container. Start it with:"
    echo "  docker compose -f repro/docker-compose.yml up -d toolchain-builder"
    exit 1
  fi

  local state
  state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null || echo "unknown")
  if [[ "$state" != "running" ]]; then
    echo "ERROR: toolchain-builder container exists but is not running (state=$state)."
    echo "  docker compose -f repro/docker-compose.yml up -d --force-recreate toolchain-builder"
    exit 1
  fi
}

# --- Step Definitions --------------------------------------------------------
# Each step: "status_name|script_name|description|env"
#   env = builder
declare -a CROSS_STEPS=(
  "fetch-sources|fetch-sources.sh|Fetch source trees|builder"
  "generate-patches|generate-patches.sh|Generate versioned patch series|builder"
  "prepare-mingw-w64|prepare-mingw-w64.sh|Prepare mingw-w64 sources|builder"
  "build-binutils|build-cross-binutils.sh|Build cross binutils|builder"
  "build-mingw-w64|build-cross-mingw-w64.sh|Build mingw-w64 headers & CRT|builder"
  "prepare-gcc|prepare-gcc.sh|Prepare GCC sources|builder"
  "build-gcc-stage1|build-cross-gcc-stage1.sh|Build GCC stage1 (bootstrap)|builder"
  "prepare-pthread9x|prepare-pthread9x.sh|Prepare pthread9x sources|builder"
  "build-pthread9x|build-cross-pthread9x.sh|Build pthread9x|builder"
  "build-gcc|build-cross-gcc.sh|Build GCC final|builder"
  "verify-cross-compiler-features|verify-cross-compiler-features.sh|Verify cross compiler features|builder"
  "build-win98-compat|build-win98-compat.sh|Build Win98 API compat shim (libwin98compat.a)|builder"
  "install-pe-checker|install-pe-checker.sh|Bundle pe-win98-check.sh + data into cross toolchain|builder"
  "package|package-cross-toolset.sh|Package cross toolchain|builder"
  "write-toolchain-manifest-v2|write-toolchain-manifest.sh|Write toolchain manifest|builder"
)

declare -a NATIVE_STEPS=(
  "build-native-mingw-deps|build-native-mingw-deps.sh|Build native mingw dependency libraries|builder"
  "build-native-mingw-w64|build-native-mingw-w64.sh|Build native-host mingw-w64|builder"
  "build-native-host-gcc|build-native-host-gcc.sh|Build native-host GCC|builder"
  "build-native-binutils|build-native-binutils.sh|Build native-host binutils|builder"
  "build-native-pthread9x|build-native-pthread9x.sh|Build native-host pthread9x|builder"
  "verify-native-compiler-features|verify-native-compiler-features.sh|Verify native compiler features|builder"
  "verify-native-win98-capability|verifiers/verify-native-package.sh|Verify native toolset Win98 capability|builder"
  "install-win98-compat-native|install-win98-compat-native.sh|Mirror win98-compat shim into native toolset|builder"
  "install-win98-helpers-native|install-win98-helpers-native.sh|Install setenv.bat + check-versions.bat into native toolset|builder"
  "package-native-toolset|package-native-toolset.sh|Package native toolset|builder"
  "write-native-toolchain-manifest-v2|write-toolchain-manifest.sh|Write native toolchain manifest|builder"
)

# EXTRAS_STEPS: Win98-hosted user tools packaged as gcc-win98-native-toolchain-extras.zip.
# Ordered cheapest → heaviest so a build can fail fast on simpler tools.
declare -a EXTRAS_STEPS=(
  "build-native-busybox|build-native-busybox.sh|Build busybox-w32|builder"
  "build-native-ctags|build-native-ctags.sh|Build universal-ctags|builder"
  "build-native-make|build-native-make.sh|Build GNU make|builder"
  "build-native-diffutils|build-native-diffutils.sh|Build GNU diffutils|builder"
  "build-native-patch|build-native-patch.sh|Build GNU patch|builder"
  "build-native-gdb|build-native-gdb.sh|Build gdb|builder"
  "build-native-muon|build-native-muon.sh|Build muon|builder"
  "build-bcrypt-shim|build-bcrypt-shim.sh|Build bcrypt.dll shim for gdb|builder"
  "verify-extras-package|verifiers/verify-extras-package.sh|Verify extras toolset Win98 capability|builder"
  "install-win98-helpers-extras|install-win98-helpers-extras.sh|Install setenv.bat + check-versions.bat into extras toolset|builder"
  "package-extras-toolset|package-extras-toolset.sh|Package extras toolset|builder"
  "write-extras-toolchain-manifest-v2|write-toolchain-manifest.sh|Write extras toolchain manifest|builder"
)

# --- Resume Logic -----------------------------------------------------------
find_last_completed_step() {
  local last_completed=""
  for step_def in "${CROSS_STEPS[@]}" "${NATIVE_STEPS[@]}" "${EXTRAS_STEPS[@]}"; do
    IFS='|' read -r status_name _ _ _ <<< "$step_def"
    if is_done_in_builder "$status_name"; then
      last_completed="$status_name"
    fi
  done
  echo "$last_completed"
}

if [[ "$RESUME_MODE" == "yes" ]]; then
  if [[ -z "$RESUME_FROM" ]]; then
    RESUME_FROM="$(find_last_completed_step)"
    if [[ -z "$RESUME_FROM" ]]; then
      log "No completed steps found; starting from beginning"
      RESUME_FROM=""
    else
      log "Auto-resuming after last completed step: $RESUME_FROM"
    fi
  fi
fi

# --- Logging Setup ----------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MASTER_LOG="$LOG_DIR/run-toolchain-build-${TIMESTAMP}.log"
mkdir -p "$LOG_DIR"

tee -a "$MASTER_LOG" <<EOF
========================================
gcc-for-Windows98 Toolchain Build
Started: $(date -Iseconds)
Project: $PROJECT_DIR
Jobs: $JOBS
Target: $TARGET
Resume: ${RESUME_MODE:-no} ${RESUME_FROM:+($RESUME_FROM)}
Extras: ${BUILD_EXTRAS}
========================================
EOF

# --- Step Runner ------------------------------------------------------------
run_step() {
    local status_name="$1"
    local script_name="$2"
    local description="$3"
    local env="$4"
    local step_log="$LOG_DIR/${script_name%.sh}-${TIMESTAMP}.log"

    mkdir -p "$(dirname "$step_log")"

    # Skip steps already done
    if is_done_in_builder "$status_name"; then
      echo "[$(date +%H:%M:%S)] [host] === SKIP (done): $description ===" | tee -a "$MASTER_LOG"
      return 0
    fi

    # Resume: skip steps before the resume point
    if [[ -n "$RESUME_FROM" && "$status_name" != "$RESUME_FROM" ]]; then
        for step_def in "${CROSS_STEPS[@]}" "${NATIVE_STEPS[@]}" "${EXTRAS_STEPS[@]}"; do
            IFS='|' read -r sn _ _ _ <<< "$step_def"
            if [[ "$sn" == "$RESUME_FROM" ]]; then
                break
            fi
            if [[ "$sn" == "$status_name" ]]; then
                echo "[$(date +%H:%M:%S)] [host] === SKIP (resume): $description ===" | tee -a "$MASTER_LOG"
                return 0
            fi
        done
    fi

    echo "" | tee -a "$MASTER_LOG"
    echo "[$(date +%H:%M:%S)] [${env}] === STEP: $description ($script_name) ===" | tee -a "$MASTER_LOG"
    echo "[$(date +%H:%M:%S)] [host] Executing in container: toolchain-builder" | tee -a "$MASTER_LOG"

    if builder_script "$script_name" > >(tee "$step_log") 2>&1; then
      echo "[$(date +%H:%M:%S)] [builder] === OK: $description ===" | tee -a "$MASTER_LOG"
      return 0
    else
      local exit_code=$?
      echo "[$(date +%H:%M:%S)] [builder] === FAILED: $description (exit=$exit_code) ===" | tee -a "$MASTER_LOG"
      echo "See log: $step_log" | tee -a "$MASTER_LOG"
      return $exit_code
    fi
}

# --- Pre-flight Checks -------------------------------------------------------
echo "=== Pre-flight checks ===" | tee -a "$MASTER_LOG"
check_containers

# --- Build Execution ---------------------------------------------------------
FAILED=0
FAILED_STEP=""

# Cross toolchain
echo "" | tee -a "$MASTER_LOG"
echo "[$(date +%H:%M:%S)] [host] === PHASE: CROSS toolchain ===" | tee -a "$MASTER_LOG"
for step_def in "${CROSS_STEPS[@]}"; do
    IFS='|' read -r status_name script_name description env <<< "$step_def"
    if ! run_step "$status_name" "$script_name" "$description" "$env"; then
        FAILED=1
        FAILED_STEP="$description ($script_name)"
        break
    fi
done

# Native toolchain (only if cross succeeded)
if [[ $FAILED -eq 0 ]]; then
    echo "" | tee -a "$MASTER_LOG"
    echo "[$(date +%H:%M:%S)] [host] === PHASE: NATIVE toolchain ===" | tee -a "$MASTER_LOG"
    for step_def in "${NATIVE_STEPS[@]}"; do
        IFS='|' read -r status_name script_name description env <<< "$step_def"
        if ! run_step "$status_name" "$script_name" "$description" "$env"; then
            FAILED=1
            FAILED_STEP="$description ($script_name)"
            break
        fi
    done
fi

# Extras (gated on BUILD_EXTRAS; only if native succeeded)
if [[ $FAILED -eq 0 && "$BUILD_EXTRAS" == "1" ]]; then
    echo "" | tee -a "$MASTER_LOG"
    echo "[$(date +%H:%M:%S)] [host] === PHASE: EXTRAS toolset ===" | tee -a "$MASTER_LOG"
    for step_def in "${EXTRAS_STEPS[@]}"; do
        IFS='|' read -r status_name script_name description env <<< "$step_def"
        if ! run_step "$status_name" "$script_name" "$description" "$env"; then
            FAILED=1
            FAILED_STEP="$description ($script_name)"
            break
        fi
    done
elif [[ "$BUILD_EXTRAS" != "1" ]]; then
    echo "" | tee -a "$MASTER_LOG"
    echo "[$(date +%H:%M:%S)] [host] === PHASE: EXTRAS toolset (SKIPPED via BUILD_EXTRAS=0) ===" | tee -a "$MASTER_LOG"
fi

# --- Summary ----------------------------------------------------------------
echo "" | tee -a "$MASTER_LOG"
if [[ $FAILED -eq 0 ]]; then
    echo "[$(date +%H:%M:%S)] [host] === TOOLCHAIN BUILD COMPLETED ===" | tee -a "$MASTER_LOG"
    echo "Artifacts in: $PROJECT_DIR/out/package/" | tee -a "$MASTER_LOG"
    echo "Master log: $MASTER_LOG" | tee -a "$MASTER_LOG"
    exit 0
else
    echo "[$(date +%H:%M:%S)] [host] === TOOLCHAIN BUILD FAILED ===" | tee -a "$MASTER_LOG"
    echo "Failed at: $FAILED_STEP" | tee -a "$MASTER_LOG"
    echo "To resume: ./scripts/run-toolchain-build.sh --resume" | tee -a "$MASTER_LOG"
    echo "Master log: $MASTER_LOG" | tee -a "$MASTER_LOG"
    exit 1
fi
