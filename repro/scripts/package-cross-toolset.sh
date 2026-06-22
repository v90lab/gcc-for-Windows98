#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# package-cross-toolset.sh - Package cross toolchain
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_step verify-cross-compiler-features "run verify-compiler-features.sh cross first"

mkdir -p "$OUT_DIR/package"
if [[ -d "$PREFIX" ]]; then
  TOTAL_FILES=$(find "$PREFIX" -type f | wc -l)
  log "writing cross-toolchain tar.xz ($TOTAL_FILES files; '.' = ~2 MB archived)..."
  # GNU tar --checkpoint fires at every Nth record (~10 KB each), independent
  # of the inline xz compression — gives a steady forward-progress signal so
  # the multi-minute xz pass doesn't look hung. stderr-only; final newline
  # below tidies up the dot run.
  tar -C "$OUT_DIR" \
      --checkpoint=200 \
      --checkpoint-action=dot \
      -caf "$OUT_DIR/package/gcc-win98-cross-toolchain.tar.xz" \
      "$(basename "$PREFIX")"
  echo >&2
  mark_done package
  log "package created at $OUT_DIR/package/gcc-win98-cross-toolchain.tar.xz"
else
  die "nothing to package: $PREFIX does not exist"
fi
