#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# package-cross-toolset.sh - Package cross toolchain
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_step verify-cross-compiler-features "run verify-compiler-features.sh cross first"

mkdir -p "$OUT_DIR/package"
if [[ -d "$PREFIX" ]]; then
  tar -C "$OUT_DIR" -caf "$OUT_DIR/package/gcc-win98-cross-toolchain.tar.xz" "$(basename "$PREFIX")"
  mark_done package
  log "package created at $OUT_DIR/package/gcc-win98-cross-toolchain.tar.xz"
else
  die "nothing to package: $PREFIX does not exist"
fi
