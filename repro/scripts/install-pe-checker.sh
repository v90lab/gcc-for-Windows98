#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# install-pe-checker.sh - Bundle pe-win98-check.sh into the cross toolchain
# ============================================================================
# Installs the standalone Win98 PE compatibility checker plus its allowlist /
# denylist data files into the cross-toolchain tree so they ride along in the
# shipped tar.xz. Downstream users get the same sanity-check tooling we use
# during the build:
#
#   $PREFIX/bin/pe-win98-check                       (symlink onto the script)
#   $PREFIX/share/win98-verify/pe-win98-check.sh
#   $PREFIX/share/win98-verify/win98se-api-allowlist.json
#   $PREFIX/share/win98-verify/win98-behavioral-denylist.json
#
# pe-win98-check.sh's default data-file lookup tries $self_dir/../../data/
# first (repo layout), then $self_dir/ (flat installed layout) — this script
# relies on the second branch, so all three files live next to each other
# under share/win98-verify/. PE_CHECK_ALLOWLIST / PE_CHECK_DENYLIST env vars
# still override.
#
# Runtime deps the bundled checker assumes the user has: bash, awk, objdump,
# and (optionally) jq. jq is required for the per-function export-table and
# behavioral-denylist checks; without it the checker degrades to OS-version +
# DLL-substring checks only.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

SRC_SCRIPT="$ROOT_DIR/scripts/verifiers/pe-win98-check.sh"
SRC_ALLOWLIST="$ROOT_DIR/data/win98se-api-allowlist.json"
SRC_DENYLIST="$ROOT_DIR/data/win98-behavioral-denylist.json"

invalidate_if_stale install-pe-checker "$SRC_SCRIPT" "$SRC_ALLOWLIST" "$SRC_DENYLIST"
skip_if_done install-pe-checker

require_file "$SRC_SCRIPT" "missing PE checker at $SRC_SCRIPT"
require_file "$SRC_ALLOWLIST" "missing allowlist at $SRC_ALLOWLIST"
require_file "$SRC_DENYLIST" "missing denylist at $SRC_DENYLIST"
require_dir "$PREFIX/bin" "cross toolchain bin/ not found at $PREFIX/bin (run build-gcc first)"

INSTALL_DIR="$PREFIX/share/win98-verify"
mkdir -p "$INSTALL_DIR"

log "installing pe-win98-check.sh and data files into $INSTALL_DIR"
install -m 0755 "$SRC_SCRIPT" "$INSTALL_DIR/pe-win98-check.sh"
install -m 0644 "$SRC_ALLOWLIST" "$INSTALL_DIR/win98se-api-allowlist.json"
install -m 0644 "$SRC_DENYLIST" "$INSTALL_DIR/win98-behavioral-denylist.json"

# bin/ wrapper as a relative symlink so the tarball is relocatable. tar.xz
# preserves symlinks; the cross archive is only consumed on Linux (consumer
# container, or downstream Linux dev box) so FAT32-stub concerns don't apply.
log "creating bin/pe-win98-check symlink"
ln -sfn "../share/win98-verify/pe-win98-check.sh" "$PREFIX/bin/pe-win98-check"

# Sanity check: confirm the script's default data-file resolution now lands
# on the bundled JSONs. Catches a future drift where someone changes the
# resolution order in pe-win98-check.sh without updating this install layout.
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
# Compare via realpath: the POSIX resolver returns paths that may include
# `bin/..` segments when invoked through the bin/ wrapper symlink (it deliberately
# doesn't follow symlinks — busybox has no readlink). Both `bin/../share/foo`
# and `share/foo` point at the same file; realpath canonicalizes both sides
# so we test file identity, not string equality.
EXPECTED_ALLOW="$(realpath "$INSTALL_DIR/win98se-api-allowlist.json")"
EXPECTED_DENY="$(realpath "$INSTALL_DIR/win98-behavioral-denylist.json")"

if [[ "$(realpath "$RESOLVED_ALLOW" 2>/dev/null)" != "$EXPECTED_ALLOW" ]]; then
    die "bundled checker resolved allowlist to $RESOLVED_ALLOW (expected to canonicalize to $EXPECTED_ALLOW)"
fi
if [[ "$(realpath "$RESOLVED_DENY" 2>/dev/null)" != "$EXPECTED_DENY" ]]; then
    die "bundled checker resolved denylist to $RESOLVED_DENY (expected to canonicalize to $EXPECTED_DENY)"
fi

# Same resolution check but via the bin/ wrapper symlink. The two prior checks
# source the script through its real path; this one exercises the third
# resolver branch (probes ../share/win98-verify/ from $self_dir). Catches the
# regression where the bin/ wrapper invocation can't find the data files —
# symptom would be a silent skip of the per-function check, falsely passing
# binaries that should FAIL (e.g. anything importing bcrypt.dll).
RESOLVED_VIA_SYMLINK=$(
    env -u PE_CHECK_ALLOWLIST -u PE_CHECK_DENYLIST bash -c '
        # shellcheck disable=SC1090
        source "$1"
        _pe_check_default_allowlist
    ' _ "$PREFIX/bin/pe-win98-check"
)
if [[ "$(realpath "$RESOLVED_VIA_SYMLINK" 2>/dev/null)" != "$EXPECTED_ALLOW" ]]; then
    die "bin/pe-win98-check wrapper symlink resolved allowlist to $RESOLVED_VIA_SYMLINK (expected to canonicalize to $EXPECTED_ALLOW) — _pe_check_resolve_data ../share/win98-verify/ branch is broken"
fi

# And confirm the bin/ wrapper executes end-to-end. Feed it a non-PE file so
# the run returns rc=0 with a [SKIP] line — exercises argv parsing, the
# pe_check_win98 codepath, and the wrapper resolution without depending on a
# Win98-compatible binary being available at this stage of the build.
log "smoke-testing bin/pe-win98-check"
if ! "$PREFIX/bin/pe-win98-check" "$SRC_ALLOWLIST" >/dev/null 2>&1; then
    die "bin/pe-win98-check smoke test failed"
fi

mark_done install-pe-checker
log "PE checker bundle installed under $INSTALL_DIR"
