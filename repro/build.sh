#!/usr/bin/env bash

set -euo pipefail

# ============================================================================
# build.sh - One-shot build orchestrator for gcc-for-Windows98 toolchain
# ============================================================================
# Usage: ./build.sh [--jobs N] [--matrix ID_OR_LABEL] [--generate-patches] [--no-cache]
#        [--clean] [--retry] [--with-extras|--without-extras] [--help|-h]
#   --jobs N      Parallel build jobs (default: auto-detect or 2)
#   --matrix M    Matrix selector (numeric index or matrix.version label, default: 0)
#   --generate-patches  Regenerate versioned patch folders from current clean sources
#   --no-cache    Force rebuild Docker images without cache
#   --clean       Clean out/ build/ logs/ AND src/ directories before build
#   --retry       Smart retry: git-reset sources (preserve clones), clean artifacts only
#   --with-extras       Build the extras tarball (busybox, make, ctags, diffutils, patch, gdb, muon) [default]
#   --without-extras    Skip the extras tarball
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="gcc-win98"

# Precedence for JOBS / MATRIX / BUILD_EXTRAS:
#   1. Variable already set in the calling shell ("JOBS=8 ./build.sh")
#   2. Value persisted in repro/.env
#   3. Built-in default (nproc for JOBS, 0 for MATRIX, 1 for BUILD_EXTRAS)
# Capture any shell-supplied overrides BEFORE sourcing .env so the file
# can't clobber them.
JOBS_OVERRIDE="${JOBS:-}"
MATRIX_OVERRIDE="${MATRIX:-}"
BUILD_EXTRAS_OVERRIDE="${BUILD_EXTRAS:-}"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
  set +a
fi

JOBS="${JOBS_OVERRIDE:-${JOBS:-$(nproc 2>/dev/null || echo 2)}}"
NO_CACHE=""
CLEAN=""
RETRY=""
MATRIX="${MATRIX_OVERRIDE:-${MATRIX:-0}}"
GENERATE_PATCHES="${GENERATE_PATCHES:-0}"
BUILD_EXTRAS="${BUILD_EXTRAS_OVERRIDE:-${BUILD_EXTRAS:-1}}"

# --- Parse arguments ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --matrix)
      MATRIX="$2"
      shift 2
      ;;
    --generate-patches)
      GENERATE_PATCHES="1"
      shift
      ;;
    --no-cache)
      NO_CACHE="--no-cache"
      shift
      ;;
    --clean)
      CLEAN="yes"
      shift
      ;;
    --retry)
      RETRY="yes"
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
      echo "Unknown option: $1 (try --help)" >&2
      exit 1
      ;;
  esac
done

# --- Validate matrix selector -------------------------------------------------
CONFIG_JSON="$SCRIPT_DIR/config.json"
if [[ -f "$CONFIG_JSON" ]]; then
  python3 "$SCRIPT_DIR/scripts/lib/validate_matrix_selector.py" "$CONFIG_JSON" "$MATRIX"
fi

# --- Clean if requested -------------------------------------------------------
if [[ "$CLEAN" == "yes" ]]; then
  echo "[*] Cleaning out/ directory..."
  rm -rf "$SCRIPT_DIR/out"/*
  mkdir -p "$SCRIPT_DIR/out"
  touch "$SCRIPT_DIR/out/.gitkeep"
  # Also clean build/ and logs/ directories inside the container volume
  rm -rf "$SCRIPT_DIR/build"/* "$SCRIPT_DIR/logs"/* 2>/dev/null || true
fi

# --- Smart retry: git-reset sources, keep clones intact -----------------------
if [[ "$RETRY" == "yes" ]]; then
  echo "[*] Smart retry: git-resetting source repos (preserving clones)..."
  "$SCRIPT_DIR/scripts/retry-clean.sh"
fi

# --- Ensure .env exists -----------------------------------------------------
if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
  if [[ -f "$SCRIPT_DIR/.env.example" ]]; then
    echo "[*] Creating .env from .env.example..."
    cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
  else
    echo "[*] Creating default .env..."
    cat > "$SCRIPT_DIR/.env" <<EOF
JOBS=$JOBS
TARGET=i686-w64-mingw32
PREFIX=/work/out/toolchain
EOF
  fi
fi

# --- Build Docker images (toolchain-builder only; consumer built after artifacts exist) ---
echo "[*] Building toolchain-builder Docker image..."

docker compose -f "$SCRIPT_DIR/docker-compose.yml" build $NO_CACHE --pull toolchain-builder

# --- Start compose services required by run-all -------------------------------
echo "[*] Starting compose services..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d toolchain-builder

# --- Run full pipeline on host (run-toolchain-build uses docker compose exec) ----
echo "[*] Running build pipeline via scripts/run-toolchain-build.sh..."
EXTRAS_FLAG=""
if [[ "$BUILD_EXTRAS" == "1" ]]; then
  EXTRAS_FLAG="--with-extras"
else
  EXTRAS_FLAG="--without-extras"
fi

if [[ "$GENERATE_PATCHES" == "1" ]]; then
  (
    cd "$SCRIPT_DIR"
    JOBS="$JOBS" MATRIX="$MATRIX" GENERATE_PATCHES="$GENERATE_PATCHES" BUILD_EXTRAS="$BUILD_EXTRAS" \
      ./scripts/run-toolchain-build.sh --jobs "$JOBS" --generate-patches "$EXTRAS_FLAG"
  )
else
  (
    cd "$SCRIPT_DIR"
    JOBS="$JOBS" MATRIX="$MATRIX" GENERATE_PATCHES="$GENERATE_PATCHES" BUILD_EXTRAS="$BUILD_EXTRAS" \
      ./scripts/run-toolchain-build.sh --jobs "$JOBS" "$EXTRAS_FLAG"
  )
fi

BUILD_EXIT=$?
if [[ $BUILD_EXIT -ne 0 ]]; then
  echo "[X] Builder failed with exit code $BUILD_EXIT" >&2
  exit $BUILD_EXIT
fi

# --- Verify artifacts exist ---------------------------------------------------
CROSS_PKG="$SCRIPT_DIR/out/package/gcc-win98-toolchain.tar.xz"
NATIVE_PKG="$SCRIPT_DIR/out/package/gcc-win98-native-toolset.zip"
EXTRAS_PKG="$SCRIPT_DIR/out/package/gcc-win98-extras.zip"

if [[ ! -f "$CROSS_PKG" ]]; then
  echo "[X] Cross toolchain package not found: $CROSS_PKG" >&2
  exit 1
fi

if [[ ! -f "$NATIVE_PKG" ]]; then
  echo "[X] Native toolset package not found: $NATIVE_PKG" >&2
  exit 1
fi

if [[ "$BUILD_EXTRAS" == "1" && ! -f "$EXTRAS_PKG" ]]; then
  echo "[X] Extras package not found: $EXTRAS_PKG" >&2
  exit 1
fi

echo "[*] Artifacts verified:"
ls -lh "$SCRIPT_DIR/out/package/"

# --- Build consumer image (now that toolchain artifacts are available) --------
echo "[*] Building consumer Docker image..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" build $NO_CACHE consumer

# --- Start consumer service ---------------------------------------------------
echo "[*] Starting consumer service..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d consumer

# --- Run smoke tests in consumer container ------------------------------------
echo "[*] Running smoke test pipeline via scripts/run-smoke-pipeline.sh..."
(
  cd "$SCRIPT_DIR"
  MATRIX="$MATRIX" ./scripts/run-smoke-pipeline.sh
)

SMOKE_EXIT=$?
if [[ $SMOKE_EXIT -ne 0 ]]; then
  echo "[X] Smoke tests failed with exit code $SMOKE_EXIT" >&2
  exit $SMOKE_EXIT
fi

# --- Summary ------------------------------------------------------------------
echo ""
echo "========================================"
echo "Build Complete!"
echo "========================================"
echo "Cross toolchain:  $CROSS_PKG"
echo "Native toolset:   $NATIVE_PKG"
if [[ "$BUILD_EXTRAS" == "1" ]]; then
  echo "Extras toolset:   $EXTRAS_PKG"
fi
echo "Consumer image:   ${PROJECT_NAME}-consumer:latest"
echo ""
echo "Quick start:"
echo "  docker run --rm -it ${PROJECT_NAME}-consumer:latest bash"
echo "  # Inside container:"
echo "  i686-w64-mingw32-gcc --version"
echo "  cmake -DCMAKE_TOOLCHAIN_FILE=/opt/cmake-toolchain/mingw-w32.cmake ..."
echo "========================================"
