#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/status-common.sh"

status_section "cross status markers"
status_step_line "fetch-sources"
status_step_line "generate-patches"
status_step_line "prepare-mingw-w64"
status_step_line "build-binutils"
status_step_line "build-mingw-w64"
status_step_line "prepare-gcc"
status_step_line "build-gcc-stage1"
status_step_line "prepare-pthread9x"
status_step_line "build-pthread9x"
status_step_line "build-gcc"
status_step_line "verify-cross-compiler-features"
status_step_line "package"
status_step_line "write-toolchain-manifest-v2"

status_section "cross artifacts"
CROSS_PKG="$OUT_DIR/package/gcc-win98-cross-toolchain.tar.xz"
CROSS_MANIFEST="$OUT_DIR/package/gcc-win98-cross-toolchain.json"
CROSS_FEATURES="$OUT_DIR/compiler-features/cross.json"
status_file_meta "$CROSS_PKG"
status_sha256_if_file "$CROSS_PKG"
status_exists_line "$CROSS_MANIFEST"
status_exists_line "$CROSS_FEATURES"

status_section "cross toolchain layout"
status_exists_line "$OUT_DIR/toolchain/bin/${TARGET}-gcc"
status_exists_line "$OUT_DIR/toolchain/bin/${TARGET}-g++"
status_exists_line "$OUT_DIR/toolchain/bin/${TARGET}-objdump"
status_exists_line "$OUT_DIR/toolchain/$TARGET/include/stdio.h"
status_exists_line "$OUT_DIR/toolchain/$TARGET/lib/libpthread.a"

status_section "cross sources"
status_exists_line "$SRC_DIR/gcc/.git"
status_exists_line "$SRC_DIR/binutils-gdb/.git"
status_exists_line "$SRC_DIR/mingw-w64/.git"
status_exists_line "$SRC_DIR/pthread9x/.git"

status_section "cross logs"
status_tail_latest "$LOG_DIR" "run-toolchain-build-*.log" 25

