#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-cross-binutils.sh - Build cross binutils
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_dir "$SRC_DIR/binutils-gdb" "missing binutils sources; run fetch-sources.sh first"

rm -rf "$BUILD_DIR/binutils-run"
mkdir -p "$BUILD_DIR/binutils-run"
cd "$BUILD_DIR/binutils-run"
run_logged build-binutils.log "$SRC_DIR/binutils-gdb/configure" --target="$TARGET" --prefix="$PREFIX" --disable-nls --disable-werror --disable-gdb
run_logged build-binutils.log make -j"$JOBS"
run_logged build-binutils.log make install
mark_done build-binutils
log "build binutils complete"
