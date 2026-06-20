#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-native-patch.sh - Build GNU patch for the extras toolset
# ============================================================================
# Cross-compiles GNU patch from the upstream release tarball (pre-built
# configure, bundled gnulib m4 macros — same pattern as make/diffutils, no
# ./bootstrap needed). Installs patch.exe under out/extras-toolset.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
PATCH_SRC="$REPO_ROOT/src/patch"
BUILD_DIR="$REPO_ROOT/build/patch-native-host"
INSTALL_DIR="$REPO_ROOT/out/extras-toolset"
CROSS_BIN_DIR="$REPO_ROOT/out/toolchain/bin"

skip_if_done build-native-patch

# === STEP 1: Verify prerequisites ===
require_dir "$PATCH_SRC" "Missing patch sources at $PATCH_SRC (run fetch-sources.sh)"
require_dir "$CROSS_BIN_DIR" "Cross toolchain not found at $CROSS_BIN_DIR"
require_executable "$CROSS_BIN_DIR/${TARGET}-gcc" "Missing $TARGET-gcc in $CROSS_BIN_DIR"

export PATH="$CROSS_BIN_DIR:$PATH"

# === STEP 2: Configure (out-of-tree) ===
require_file "$PATCH_SRC/configure" "Missing pre-built configure at $PATCH_SRC/configure (release tarball should ship one)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# === STEP 2a: Mingw compatibility stubs ===
# patch 2.7.6 was never ported to mingw upstream. It unconditionally includes
# <sys/resource.h> in src/safe.c (Linux-only) and references POSIX-only symbols
# (SIG_BLOCK, SIG_UNBLOCK, getuid/getgid/geteuid/getegid, getrlimit/setrlimit,
# SIGHUP/SIGPIPE/SIGSTOP/SA_RESTART) that mingw doesn't provide. Rather than
# carrying a source-patch series, we sandbox the gaps with:
#   * a stub <sys/resource.h> in our own -I path
#   * a force-included compat header that #defines the missing symbols
# Runtime behavior is no-op: resource limits stub to 1024 fds (read-only);
# user/group IDs stub to root-like 0; signal handler installs silently fail
# for signals that don't exist on Windows.
STUBS_DIR="$BUILD_DIR/mingw-stubs"
mkdir -p "$STUBS_DIR/sys"

cat > "$STUBS_DIR/sys/resource.h" <<'STUB_RES'
/* mingw stub for <sys/resource.h> — Windows has no resource limits */
#ifndef _STUB_SYS_RESOURCE_H
#define _STUB_SYS_RESOURCE_H
typedef unsigned long rlim_t;
struct rlimit { rlim_t rlim_cur, rlim_max; };
#define RLIMIT_NOFILE 0
#define RLIM_INFINITY (~(rlim_t)0)
#define getrlimit(resource, rlim) ((rlim)->rlim_cur = (rlim)->rlim_max = 1024, 0)
#define setrlimit(resource, rlim) (0)
#endif
STUB_RES

cat > "$STUBS_DIR/compat-mingw.h" <<'STUB_COMPAT'
/* mingw compatibility shims for GNU patch 2.7.6 */
#ifndef _COMPAT_MINGW_H
#define _COMPAT_MINGW_H

/* POSIX signal numbers absent on Windows */
#ifndef SIGHUP
# define SIGHUP 1
#endif
#ifndef SIGPIPE
# define SIGPIPE 13
#endif
#ifndef SIGSTOP
# define SIGSTOP 17
#endif

/* POSIX sigaction flag (Windows has no sigaction) */
#ifndef SA_RESTART
# define SA_RESTART 0
#endif

/* POSIX sigprocmask "how" constants (Windows has no signal mask) */
#ifndef SIG_BLOCK
# define SIG_BLOCK 0
#endif
#ifndef SIG_UNBLOCK
# define SIG_UNBLOCK 1
#endif
#ifndef SIG_SETMASK
# define SIG_SETMASK 2
#endif

/* POSIX user/group ID functions — meaningless on Windows; stub to 0 (root-like) */
#define getuid()  (0)
#define getgid()  (0)
#define geteuid() (0)
#define getegid() (0)

#endif
STUB_COMPAT

cd "$BUILD_DIR"

log "configuring GNU patch for $TARGET"
run_logged build-native-patch.log "$PATCH_SRC/configure" \
    --build=x86_64-pc-linux-gnu \
    --host="$TARGET" \
    --prefix="$INSTALL_DIR" \
    --disable-nls \
    --disable-dependency-tracking \
    --disable-gcc-warnings \
    CPPFLAGS="-I$STUBS_DIR -include $STUBS_DIR/compat-mingw.h $WIN98_TARGET_CPPFLAGS $WIN98_COMPAT_CPPFLAGS" \
    LDFLAGS="-static-libgcc $WIN98_TARGET_LDFLAGS $WIN98_COMPAT_LDFLAGS"

# === STEP 3: Build & install ===
log "building GNU patch"
run_logged build-native-patch.log make -j"$JOBS" MAKEINFO=true

log "installing GNU patch to $INSTALL_DIR"
run_logged build-native-patch.log make install MAKEINFO=true

require_file "$INSTALL_DIR/bin/patch.exe" "GNU patch install produced no patch.exe"

mark_done build-native-patch
log "GNU patch build complete"
