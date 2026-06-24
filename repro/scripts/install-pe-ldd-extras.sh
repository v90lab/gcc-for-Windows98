#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# install-pe-ldd-extras.sh - Bundle pe-ldd.sh into the extras zip
# ============================================================================
# Mirrors install-pe-ldd.sh but installs into out/extras-toolset/ instead of
# the cross sysroot. Same source script.
#
# Win98-side layout (after extraction of the extras zip):
#   <prefix>/share/win98-verify/pe-ldd.sh
#
# Invocation on Win98 (with extras bin/ on PATH so sh.exe + jq.exe are
# findable, and native-toolset bin/ on PATH for objdump.exe):
#   sh share\win98-verify\pe-ldd.sh foo.exe
#   sh share\win98-verify\pe-ldd.sh -r foo.exe        # transitive
#
# No bin/ wrapper for the same reason install-pe-checker-extras.sh skips one
# (Win98 command.com has no %~dp0 to find the sibling script). The bare-sh
# invocation works today; a small EXE wrapper or setenv.bat alias would be
# the right follow-up.
#
# Ordered AFTER install-pe-checker-extras in EXTRAS_STEPS so the allowlist
# JSON is already in share/win98-verify/ when this step runs.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

SRC_SCRIPT="$ROOT_DIR/scripts/verifiers/pe-ldd.sh"

invalidate_if_stale install-pe-ldd-extras "$SRC_SCRIPT"
skip_if_done install-pe-ldd-extras

require_file "$SRC_SCRIPT" "missing pe-ldd.sh at $SRC_SCRIPT"

EXTRAS_PREFIX="$ROOT_DIR/out/extras-toolset"
require_dir "$EXTRAS_PREFIX/bin" "extras toolset bin/ not found at $EXTRAS_PREFIX/bin (run extras phase first)"

INSTALL_DIR="$EXTRAS_PREFIX/share/win98-verify"
mkdir -p "$INSTALL_DIR"

if [[ ! -f "$INSTALL_DIR/win98se-api-allowlist.json" ]]; then
    log "WARNING: allowlist JSON not present at $INSTALL_DIR — bundled pe-ldd will run in degraded mode"
fi

log "installing pe-ldd.sh into $INSTALL_DIR"
install -m 0755 "$SRC_SCRIPT" "$INSTALL_DIR/pe-ldd.sh"

# Smoke: --help.
log "smoke-testing pe-ldd.sh --help"
if ! "$INSTALL_DIR/pe-ldd.sh" --help >/dev/null 2>&1; then
    die "$INSTALL_DIR/pe-ldd.sh --help smoke test failed"
fi

# End-to-end smoke: run against a real PE we just built. gdb.exe is the
# canonical bundled-DLL consumer (imports BCRYPT.DLL which the shim ships
# alongside it), so a passing run also exercises the App Directory branch.
TEST_EXE="$EXTRAS_PREFIX/bin/gdb.exe"
if [[ -f "$TEST_EXE" ]]; then
    log "smoke-testing pe-ldd.sh against bin/gdb.exe"
    smoke_out=$("$INSTALL_DIR/pe-ldd.sh" "$TEST_EXE" 2>&1) || {
        printf '%s\n' "$smoke_out" >&2
        die "pe-ldd.sh smoke run against gdb.exe failed"
    }
    # Sanity check: must report bcrypt.dll resolved to the extras bin/ dir
    # (App Directory branch). Case-insensitive grep — the import table may
    # spell it lowercase or uppercase depending on the import lib generator.
    if ! printf '%s\n' "$smoke_out" | grep -qi 'bcrypt\.dll *=> *.*bin'; then
        printf '%s\n' "$smoke_out" >&2
        die "pe-ldd.sh did not resolve bcrypt.dll out of bin/ (App Directory search broken?)"
    fi
    # And: KERNEL32.DLL should be reported as a system DLL.
    if ! printf '%s\n' "$smoke_out" | grep -qi 'kernel32\.dll *=> *(Win98 system DLL)'; then
        printf '%s\n' "$smoke_out" >&2
        die "pe-ldd.sh did not classify kernel32.dll as a system DLL (allowlist load broken?)"
    fi
else
    log "WARNING: $TEST_EXE not present — skipping end-to-end smoke (gdb build may have been skipped)"
fi

mark_done install-pe-ldd-extras
log "pe-ldd installed under $INSTALL_DIR"
