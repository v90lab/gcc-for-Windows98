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
  # Recreate the directory rather than `rm out/*`. The glob form omits
  # dotfiles by default, which silently left status sentinels (.status-*)
  # AND old-location patch markers (.patches-applied-*) behind across
  # `--clean` rebuilds. Both classes of dotfile must die for a clean
  # rebuild to actually be clean.
  rm -rf "$SCRIPT_DIR/out"
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

# --- Pre-create the external ccache volume ----------------------------------
# Declared `external: true` in docker-compose.yml so `clean-rebuild.sh`'s
# `compose down -v` leaves it intact across full rebuilds. External volumes
# must exist before `compose up`, so create it on first run. Idempotent —
# `docker volume create` is a no-op when the volume already exists.
docker volume inspect gcc-win98-ccache >/dev/null 2>&1 || \
  docker volume create gcc-win98-ccache >/dev/null

# --- Build Docker images (toolchain-builder only; consumer built after artifacts exist) ---
echo "[*] Building toolchain-builder Docker image..."

docker compose -f "$SCRIPT_DIR/docker-compose.yml" build $NO_CACHE --pull toolchain-builder

# --- Start compose services required by run-all -------------------------------
echo "[*] Starting compose services..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d toolchain-builder

# --- Capture git info for BUILD.TXT (best-effort, read on host) -------------
# write-extras-build-info.sh runs inside the container where .git isn't
# accessible (we only bind-mount repro/, not the repo root).  Pre-read here
# on the host so it can be passed through as env vars.
HOST_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_GIT_REV="$(git -C "$HOST_REPO_ROOT" rev-parse --short=10 HEAD 2>/dev/null || echo unknown)"
BUILD_GIT_REV_FULL="$(git -C "$HOST_REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
if git -C "$HOST_REPO_ROOT" diff --quiet 2>/dev/null && \
   git -C "$HOST_REPO_ROOT" diff --cached --quiet 2>/dev/null; then
  BUILD_GIT_DIRTY=""
else
  _changed="$(git -C "$HOST_REPO_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  BUILD_GIT_DIRTY=" (dirty: ${_changed} files changed)"
fi
export BUILD_GIT_REV BUILD_GIT_REV_FULL BUILD_GIT_DIRTY

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
      BUILD_GIT_REV="$BUILD_GIT_REV" BUILD_GIT_REV_FULL="$BUILD_GIT_REV_FULL" BUILD_GIT_DIRTY="$BUILD_GIT_DIRTY" \
      ./scripts/run-toolchain-build.sh --jobs "$JOBS" --generate-patches "$EXTRAS_FLAG"
  )
else
  (
    cd "$SCRIPT_DIR"
    JOBS="$JOBS" MATRIX="$MATRIX" GENERATE_PATCHES="$GENERATE_PATCHES" BUILD_EXTRAS="$BUILD_EXTRAS" \
      BUILD_GIT_REV="$BUILD_GIT_REV" BUILD_GIT_REV_FULL="$BUILD_GIT_REV_FULL" BUILD_GIT_DIRTY="$BUILD_GIT_DIRTY" \
      ./scripts/run-toolchain-build.sh --jobs "$JOBS" "$EXTRAS_FLAG"
  )
fi

BUILD_EXIT=$?
if [[ $BUILD_EXIT -ne 0 ]]; then
  echo "[X] Builder failed with exit code $BUILD_EXIT" >&2
  exit $BUILD_EXIT
fi

# --- Verify artifacts exist ---------------------------------------------------
CROSS_PKG="$SCRIPT_DIR/out/package/gcc-win98-cross-toolchain.tar.xz"
NATIVE_PKG="$SCRIPT_DIR/out/package/gcc-win98-native-toolchain.zip"
EXTRAS_PKG="$SCRIPT_DIR/out/package/gcc-win98-native-toolchain-extras.zip"

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
# Forward JOBS into the smoke pipeline. Without this, run-smoke-pipeline.sh's
# `JOBS="${JOBS:-4}"` falls back to 4 — meaning a build.sh --jobs 16 invocation
# would run the two CMake+Ninja smoke builds (cross + native) under-parallel
# regardless of what the user requested.
echo "[*] Running smoke test pipeline via scripts/run-smoke-pipeline.sh..."
(
  cd "$SCRIPT_DIR"
  JOBS="$JOBS" MATRIX="$MATRIX" ./scripts/run-smoke-pipeline.sh
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
