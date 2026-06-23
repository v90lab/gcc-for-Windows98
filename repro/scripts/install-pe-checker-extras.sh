#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# install-pe-checker-extras.sh - Bundle pe-win98-check.sh into the extras zip
# ============================================================================
# Mirrors install-pe-checker.sh but installs into out/extras-toolset/ instead
# of the cross sysroot. Single source of truth — the script and JSONs come
# from the same repo locations as the cross install.
#
# Win98-side layout (after extraction of the extras zip):
#   <prefix>/share/win98-verify/pe-win98-check.sh
#   <prefix>/share/win98-verify/win98se-api-allowlist.json
#   <prefix>/share/win98-verify/win98-behavioral-denylist.json
#
# Invocation on Win98 (with extras bin/ on PATH so sh.exe + jq.exe are
# findable, and native-toolset bin/ on PATH for objdump.exe):
#   sh share\win98-verify\pe-win98-check.sh foo.exe
#
# No bin/ wrapper. Win98 command.com lacks the cmd.exe `%~dp0` extension, so
# a generic relocatable .bat wrapper can't reliably find its sibling .sh
# from any CWD. The clean wrappers are either a small bb-shim-style EXE
# (option 1) or a setenv.bat alias (option 2). Punted to a follow-up; the
# bare-sh invocation above works today.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

SRC_SCRIPT="$ROOT_DIR/scripts/verifiers/pe-win98-check.sh"
SRC_ALLOWLIST="$ROOT_DIR/data/win98se-api-allowlist.json"
SRC_DENYLIST="$ROOT_DIR/data/win98-behavioral-denylist.json"

invalidate_if_stale install-pe-checker-extras "$SRC_SCRIPT" "$SRC_ALLOWLIST" "$SRC_DENYLIST"
skip_if_done install-pe-checker-extras

require_file "$SRC_SCRIPT"    "missing PE checker at $SRC_SCRIPT"
require_file "$SRC_ALLOWLIST" "missing allowlist at $SRC_ALLOWLIST"
require_file "$SRC_DENYLIST"  "missing denylist at $SRC_DENYLIST"

EXTRAS_PREFIX="$ROOT_DIR/out/extras-toolset"
require_dir "$EXTRAS_PREFIX/bin" "extras toolset bin/ not found at $EXTRAS_PREFIX/bin (run extras phase first)"

INSTALL_DIR="$EXTRAS_PREFIX/share/win98-verify"
mkdir -p "$INSTALL_DIR"

log "installing pe-win98-check.sh and data files into $INSTALL_DIR"
install -m 0755 "$SRC_SCRIPT"    "$INSTALL_DIR/pe-win98-check.sh"
install -m 0644 "$SRC_ALLOWLIST" "$INSTALL_DIR/win98se-api-allowlist.json"
install -m 0644 "$SRC_DENYLIST"  "$INSTALL_DIR/win98-behavioral-denylist.json"

# Verify resolution from the install dir (flat layout — script and JSONs
# sit side-by-side, so the second branch in _pe_check_resolve_data should
# hit). Use realpath to compare file identity rather than literal strings.
log "verifying bundled checker resolves its data files"
RESOLVED_ALLOW=$(
    env -u PE_CHECK_ALLOWLIST -u PE_CHECK_DENYLIST bash -c '
        # shellcheck disable=SC1090
        source "$1"
        _pe_check_default_allowlist
    ' _ "$INSTALL_DIR/pe-win98-check.sh"
)
RESOLVED_DENY=$(
    env -u PE_CHECK_ALLOWLIST -u PE_CHECK_DENYLIST bash -c '
        # shellcheck disable=SC1090
        source "$1"
        _pe_check_default_denylist
    ' _ "$INSTALL_DIR/pe-win98-check.sh"
)
EXPECTED_ALLOW="$(realpath "$INSTALL_DIR/win98se-api-allowlist.json")"
EXPECTED_DENY="$(realpath "$INSTALL_DIR/win98-behavioral-denylist.json")"
if [[ "$(realpath "$RESOLVED_ALLOW" 2>/dev/null)" != "$EXPECTED_ALLOW" ]]; then
    die "extras-side checker resolved allowlist to $RESOLVED_ALLOW (expected to canonicalize to $EXPECTED_ALLOW)"
fi
if [[ "$(realpath "$RESOLVED_DENY" 2>/dev/null)" != "$EXPECTED_DENY" ]]; then
    die "extras-side checker resolved denylist to $RESOLVED_DENY (expected to canonicalize to $EXPECTED_DENY)"
fi

# End-to-end smoke against a non-PE file — exercises argv parsing and the
# pe_check_win98 SKIP path without depending on a specific test binary.
log "smoke-testing $INSTALL_DIR/pe-win98-check.sh"
if ! "$INSTALL_DIR/pe-win98-check.sh" "$SRC_ALLOWLIST" >/dev/null 2>&1; then
    die "extras-side pe-win98-check.sh smoke test failed"
fi

mark_done install-pe-checker-extras
log "PE checker bundle installed under $INSTALL_DIR"
