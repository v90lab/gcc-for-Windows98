#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-cross-mingw-w64.sh - Build mingw-w64 headers & CRT
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_dir "$SRC_DIR/mingw-w64" "missing mingw sources; run fetch-sources.sh first"

mkdir -p "$BUILD_DIR/mingw-w64-headers-run" "$BUILD_DIR/mingw-w64-crt-run"

if ! is_done build-mingw-w64-headers; then
  cd "$BUILD_DIR/mingw-w64-headers-run"
  run_logged build-mingw-w64.log "$SRC_DIR/mingw-w64/mingw-w64-headers/configure" --host="$TARGET" --prefix="$PREFIX/$TARGET" --enable-sdk=all --enable-idl --with-default-msvcrt=msvcrt
  run_logged build-mingw-w64.log make -j"$JOBS"
  run_logged build-mingw-w64.log make install
  mark_done build-mingw-w64-headers
  log "build mingw-w64 headers complete"
fi

cd "$BUILD_DIR/mingw-w64-crt-run"
export PATH="$PREFIX/bin:$PATH"
run_logged build-mingw-w64.log "$SRC_DIR/mingw-w64/mingw-w64-crt/configure" --host="$TARGET" --prefix="$PREFIX/$TARGET" --disable-lib32 --enable-lib32 --with-sysroot="$PREFIX/$TARGET" --with-default-msvcrt=msvcrt
run_logged build-mingw-w64.log make -j"$JOBS"
run_logged build-mingw-w64.log make install
mark_done build-mingw-w64
log "build mingw-w64 crt complete"
