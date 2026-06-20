#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# install-win98-helpers-extras.sh - Bundle setenv.bat + check-versions.bat
# into the extras toolset
# ============================================================================
# Same payload as install-win98-helpers-native.sh, mirrored into the extras
# toolset (gcc-win98-extras.zip). Shipped in both packages because:
#   * a user installing just the native compiler may invoke sh.exe / make.exe
#     from extras later — they still want HOME set
#   * a user installing just the extras zip still wants check-versions.bat
#     to smoke-test the bundled tools
#   * the files are tiny (~2 KB combined) so duplication is cheap
#   * removes a "which package do I install first to get the helpers" footgun
# Both copies are byte-identical; the source of truth is repro/scripts/win98/.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

skip_if_done install-win98-helpers-extras

DEST_DIR="$ROOT_DIR/out/extras-toolset"
SRC_BATCH_DIR="$ROOT_DIR/scripts/win98"

require_dir "$DEST_DIR" "extras toolset not found at $DEST_DIR (run extras build steps first)"
require_file "$SRC_BATCH_DIR/setenv.bat" "missing $SRC_BATCH_DIR/setenv.bat"
require_file "$SRC_BATCH_DIR/check-versions.bat" "missing $SRC_BATCH_DIR/check-versions.bat"

log "installing Win98 helper batch files into $DEST_DIR"
install -m 0644 "$SRC_BATCH_DIR/setenv.bat" "$DEST_DIR/setenv.bat"
install -m 0644 "$SRC_BATCH_DIR/check-versions.bat" "$DEST_DIR/check-versions.bat"

mark_done install-win98-helpers-extras
log "Win98 helper batch files installed"
