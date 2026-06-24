#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# install-pe-ldd.sh - Bundle pe-ldd.sh into the cross toolchain
# ============================================================================
# Sister to install-pe-checker.sh. Drops pe-ldd.sh next to pe-win98-check.sh
# under share/win98-verify/ (same dir → same allowlist resolution) plus two
# bin/ symlinks (pe-ldd, pe-lddtree — same script, basename selects mode).
#
# Layout (after install):
#   $PREFIX/bin/pe-ldd         -> ../share/win98-verify/pe-ldd.sh
#   $PREFIX/bin/pe-lddtree     -> ../share/win98-verify/pe-ldd.sh
#   $PREFIX/share/win98-verify/pe-ldd.sh
#
# install-pe-checker.sh installs the allowlist JSON into the same share dir,
# so pe-ldd.sh's flat-layout branch finds it without further plumbing. This
# step is ordered AFTER install-pe-checker in CROSS_STEPS for that reason.
#
# Runtime deps the bundled tool assumes: awk, objdump, jq (jq is optional —
# degraded to a short builtin DLL list if missing).
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

SRC_SCRIPT="$ROOT_DIR/scripts/verifiers/pe-ldd.sh"

invalidate_if_stale install-pe-ldd "$SRC_SCRIPT"
skip_if_done install-pe-ldd

require_file "$SRC_SCRIPT" "missing pe-ldd.sh at $SRC_SCRIPT"
require_dir "$PREFIX/bin" "cross toolchain bin/ not found at $PREFIX/bin (run build-gcc first)"

INSTALL_DIR="$PREFIX/share/win98-verify"
mkdir -p "$INSTALL_DIR"

# The allowlist JSON should already be here from install-pe-checker (which
# runs earlier in CROSS_STEPS). If not, pe-ldd.sh degrades to its builtin
# DLL list and warns at runtime — not fatal, but worth flagging now.
if [[ ! -f "$INSTALL_DIR/win98se-api-allowlist.json" ]]; then
    log "WARNING: allowlist JSON not present at $INSTALL_DIR — bundled pe-ldd will run in degraded mode"
fi

log "installing pe-ldd.sh into $INSTALL_DIR"
install -m 0755 "$SRC_SCRIPT" "$INSTALL_DIR/pe-ldd.sh"

# bin/ wrappers — relative symlinks (tar.xz preserves them; cross archive is
# Linux-only so FAT32 stub concerns don't apply).
log "creating bin/pe-ldd and bin/pe-lddtree symlinks"
ln -sfn "../share/win98-verify/pe-ldd.sh" "$PREFIX/bin/pe-ldd"
ln -sfn "../share/win98-verify/pe-ldd.sh" "$PREFIX/bin/pe-lddtree"

# Smoke: --help should exit 0 and produce non-empty output. Use the bin/
# wrapper so the symlink + basename-detection paths get exercised.
log "smoke-testing bin/pe-ldd --help"
if ! "$PREFIX/bin/pe-ldd" --help >/dev/null 2>&1; then
    die "bin/pe-ldd --help smoke test failed"
fi

# Confirm the recursive-by-basename detection works via bin/pe-lddtree.
# Easiest check: --help mentions "pe-lddtree" in the Usage line.
log "verifying basename-based mode detection via bin/pe-lddtree"
help_out=$("$PREFIX/bin/pe-lddtree" --help 2>/dev/null || true)
if ! printf '%s' "$help_out" | grep -q 'pe-lddtree'; then
    die "bin/pe-lddtree didn't self-identify in --help output (basename detection broken)"
fi

mark_done install-pe-ldd
log "pe-ldd installed under $INSTALL_DIR"
