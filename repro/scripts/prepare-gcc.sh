#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# prepare-gcc.sh - Prepare GCC sources
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_dir "$SRC_DIR/gcc" "missing gcc sources; run fetch-sources.sh first"
skip_if_done prepare-gcc

cd "$SRC_DIR/gcc"
# Tarball-extracted sources have no .git/; nothing to reset.
if [[ -d .git ]]; then
  run_logged prepare-gcc.log git reset --hard HEAD
  run_logged prepare-gcc.log git clean -fd
fi

# Apply versioned patch series for GCC.
run_logged prepare-gcc.log "$ROOT_DIR/scripts/apply-patches.sh" gcc "11.1.0"

mkdir -p "$BUILD_DIR/gcc"
cat > "$BUILD_DIR/gcc/configure-command.sh" <<EOF
"$SRC_DIR/gcc/configure" --target=\${TARGET} --prefix=\${PREFIX} \\
  --disable-nls --enable-languages=c,c++ --disable-multilib \\
  --enable-threads=posix --disable-sjlj-exceptions --with-default-msvcrt=msvcrt \\
  glibcxx_cv_LFS=no \\
  ac_cv_func_aligned_alloc=no \\
  ac_cv_func__aligned_malloc=no
EOF
chmod +x "$BUILD_DIR/gcc/configure-command.sh"

mark_done prepare-gcc
log "prepare gcc complete"
