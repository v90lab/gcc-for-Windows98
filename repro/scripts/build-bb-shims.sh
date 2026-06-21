#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-bb-shims.sh - Build + install bb-shim copies for common applets
# ============================================================================
# Compiles repro/bb-shim/bb-shim.c once, then drops a copy-renamed .exe into
# out/extras-toolset/bin/ for each curated applet name.  This is the FAT32
# substitute for the per-applet symlinks-to-busybox that busybox uses on
# POSIX filesystems.  See AGENTS.md §5.10 for the design rationale.
#
# Each shipped <applet>.exe is a byte-identical copy of bb-shim.exe; the
# shim resolves its own basename at runtime and spawns
# "$(dirname argv[0])/busybox.exe <applet> <args>".  Works in command.com
# and inside busybox sh.
#
# Skip list (not shimmed because we ship a standalone .exe by the same name):
#  - sh.exe                  (busybox copy from build-native-busybox)
#  - cmp.exe, diff.exe       (diffutils)
#  - patch.exe               (gnu patch)
#  - make.exe                (gnu make)
#  - ctags.exe               (universal-ctags)
#  - gdb.exe                 (gdb)
#  - muon.exe                (muon)
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
SHIM_SRC="$REPO_ROOT/bb-shim/bb-shim.c"
INSTALL_DIR="$REPO_ROOT/out/extras-toolset/bin"
CROSS_BIN="$REPO_ROOT/out/toolchain/bin"

# Applets to shim.  Each name MUST correspond to a busybox applet that's
# enabled in repro/configs/busybox-w32.config (CONFIG_<NAME>=y).  When
# adding/removing entries, verify with:
#   grep -E "^CONFIG_<NAME>=y" repro/configs/busybox-w32.config
declare -a SHIM_APPLETS=(
    # POSIX file / process basics
    ls cp mv rm mkdir rmdir cat echo true false test pwd env
    basename dirname sleep date expr kill ps
    # Text processing
    grep sed awk head tail sort uniq wc cut tr find xargs paste tee
    tac rev seq
    # File ops / metadata
    touch du df stat which printf
    # Shell helpers
    yes clear
    # Editors / viewers
    vi less
    # Binary / dump tools
    hexdump od dd
    # Checksums
    md5sum sha1sum sha256sum sha512sum
    # Archives / compression
    tar gzip gunzip
)

# Caller script (this file) is implicit input, so SHIM_APPLETS edits also
# invalidate. SHIM_SRC explicit so edits to bb-shim.c invalidate too.
invalidate_if_stale build-bb-shims "$SHIM_SRC"
skip_if_done build-bb-shims

require_file "$SHIM_SRC" "missing bb-shim source at $SHIM_SRC"
require_dir "$INSTALL_DIR" "extras-toolset/bin/ must exist (run build-native-busybox first)"
require_executable "$CROSS_BIN/${TARGET}-gcc" "cross gcc not at $CROSS_BIN/${TARGET}-gcc"
require_file "$INSTALL_DIR/busybox.exe" "busybox.exe missing from $INSTALL_DIR (run build-native-busybox first)"

export PATH="$CROSS_BIN:$PATH"

SHIM_EXE="$INSTALL_DIR/bb-shim.exe"

log "compiling bb-shim.exe (target=$TARGET)"
# -Os: every shim ships ~50× — keep it small.  -s: strip after link.
# WIN98_TARGET_*: -D_WIN32_WINNT=0x0400 + Win98-safe DllCharacteristics.
# Intentionally NOT linking -lwin98compat — the shim only calls
# GetModuleFileNameA / GetLastError / _spawnv / libc string-IO, none of
# which are in libwin98compat.a's coverage list, and WIN98_COMPAT_LDFLAGS
# uses --whole-archive which would force every .o from the compat archive
# into the link (~30 KB of dead code × 57 copies = wasted disk).  If a
# future change adds a shimmed-API call site, the link will fail clean
# with "undefined reference to win98_foo" — opt back in then.
# shellcheck disable=SC2086  # CPPFLAGS / LDFLAGS need word-splitting
run_logged build-bb-shims.log \
    "${TARGET}-gcc" -Os -s -static -static-libgcc \
        $WIN98_TARGET_CPPFLAGS \
        $WIN98_TARGET_LDFLAGS \
        -o "$SHIM_EXE" "$SHIM_SRC"

require_file "$SHIM_EXE" "compile produced no bb-shim.exe"

# PE-verify the master copy; per-applet copies are byte-identical so a green
# light here covers them all (verify-extras-package will re-scan everything,
# but this catches a busted shim before the install loop runs).
log "PE-verifying bb-shim.exe"
# shellcheck source=verifiers/pe-win98-check.sh
source "$REPO_ROOT/scripts/verifiers/pe-win98-check.sh"
pe_check_win98 "$SHIM_EXE" || true
if [[ "$PE_CHECK_RESULT" != "pass" ]]; then
    die "bb-shim.exe failed PE check: ${PE_CHECK_FAIL_REASON:-unknown}"
fi

# Install one copy per applet.  Guard: refuse to clobber a standalone tool
# we ship under the same filename — defense in depth, since SHIM_APPLETS
# is already curated to be disjoint from these.  Using a name-based deny
# list (not a byte-compare against the new shim) so a flag change that
# legitimately changes the shim size doesn't lock us out of updating the
# previously-installed copies.
declare -A STANDALONE_TOOL=(
    [busybox.exe]=1 [sh.exe]=1 [make.exe]=1 [ctags.exe]=1
    [diff.exe]=1 [diff3.exe]=1 [cmp.exe]=1 [patch.exe]=1
    [gdb.exe]=1 [gdbserver.exe]=1 [gdb-add-index]=1
    [muon.exe]=1 [bcrypt.dll]=1 [bb-shim.exe]=1
)

installed=0
skipped=0
log "installing ${#SHIM_APPLETS[@]} shim copies into $INSTALL_DIR"
for applet in "${SHIM_APPLETS[@]}"; do
    target_name="${applet}.exe"
    if [[ -n "${STANDALONE_TOOL[$target_name]:-}" ]]; then
        log "  ! refusing to shim ${target_name} — collides with a standalone tool"
        skipped=$((skipped + 1))
        continue
    fi
    cp -f "$SHIM_EXE" "$INSTALL_DIR/$target_name"
    installed=$((installed + 1))
done
log "installed $installed shim copies, skipped $skipped"

mark_done build-bb-shims
log "bb-shim build + install complete"
