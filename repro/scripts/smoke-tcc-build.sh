#!/usr/bin/env bash
# smoke-tcc-build.sh — Phase 3d: cross-check that binaries PRODUCED by tcc.exe
# are Win98-clean. Compiles a tiny hello world under wine via the extras-packaged
# tcc.exe, runs the result through pe_check_win98, then executes it under wine
# and verifies the expected output.
#
# This is the Phase-2 of the tcc port — "tcc itself runs on Win98" is covered
# by smoke-extras-wine-version.sh's `tcc.exe -v` check. THIS step catches:
#   - tccpe.c writing OS/subsystem versions > 4 (would fail the PE check)
#   - tcc's bundled CRT (win32/lib/{crt1,wincrt1,dllcrt1,...}) baking Vista+
#     imports into the produced binary
#   - libtcc1.a having Win98-unsafe runtime helpers (math/intrinsic surface)
#   - tcc's bundled include/ headers macro-redirecting to symbols absent on Win98
#
# Skips cleanly when tcc isn't installed (BUILD_EXTRAS=0 or extras built without tcc).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=verifiers/pe-win98-check.sh
source "$ROOT_DIR/scripts/verifiers/pe-win98-check.sh"

EXTRAS="${EXTRAS_PREFIX:-/opt/extras}"
TCC="$EXTRAS/bin/tcc.exe"

if [[ ! -f "$TCC" ]]; then
    log "[SKIP] tcc.exe not present at $TCC — extras package missing or built without tcc"
    exit 0
fi

require_executable wine "wine is required for the tcc-build smoke step"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Hello world hits the minimum useful surface: stdio (puts → msvcrt printf),
# command-line parsing argv (entry path through wincrt1 / crt1), and the
# normal `return 0` exit path. Anything Vista+ that tcc's CRT or libtcc1.a
# baked in shows up as a PE-check failure on this binary.
cat > "$WORK/hello.c" <<'EOF'
#include <stdio.h>
int main(int argc, char **argv) {
    printf("hello from tcc on win98\n");
    return 0;
}
EOF

EXE="$WORK/hello.exe"

log "=== tcc-built hello world smoke ==="
log "tcc compile: $WORK/hello.c -> $EXE"

# tcc.exe finds its resources at dirname(tcc.exe) on Win32 = /opt/extras/bin/,
# where the build-native-tcc install step put include/ + lib/ + libtcc1.a +
# *.def. No extra -B/-I flags needed.
TCC_STDERR="$WORK/tcc.stderr"
if ! WINEDEBUG=-all wine "$TCC" -o "$EXE" "$WORK/hello.c" 2>"$TCC_STDERR"; then
    log "[FAIL] tcc.exe failed to compile hello.c"
    log "  stderr:"
    sed 's/^/    /' "$TCC_STDERR" >&2 || true
    die "tcc-build smoke FAILED at compile"
fi

if [[ ! -f "$EXE" ]]; then
    die "tcc-build smoke: tcc returned 0 but produced no $EXE"
fi

# PE check the produced .exe.
log "Win98 PE check on $EXE"
pe_check_win98 "$EXE" || true
case "$PE_CHECK_RESULT" in
    pass)
        ver_tag=""
        [[ -n "${PE_CHECK_OS_MAJOR:-}" ]] && ver_tag="  OS=$PE_CHECK_OS_MAJOR.${PE_CHECK_OS_MINOR:-0}"
        log "[OK-PE]   hello.exe$ver_tag"
        ;;
    fail)
        die "tcc-built hello.exe failed Win98 PE check: $PE_CHECK_FAIL_REASON"
        ;;
    skip)
        die "tcc-built hello.exe was not recognized as a PE (objdump failure?)"
        ;;
esac

# Run under wine and check expected output.
log "wine run: $EXE"
RUN_OUT="$WORK/hello.stdout"
RUN_RC=0
WINEDEBUG=-all wine "$EXE" > "$RUN_OUT" 2>&1 || RUN_RC=$?
if [[ "$RUN_RC" -ne 0 ]]; then
    log "[FAIL-RUN] wine exit=$RUN_RC"
    log "  output:"
    sed 's/^/    /' "$RUN_OUT" >&2 || true
    die "tcc-built hello.exe failed to run under wine"
fi

EXPECTED="hello from tcc on win98"
if ! grep -qF "$EXPECTED" "$RUN_OUT"; then
    log "[FAIL-RUN] expected output not found"
    log "  expected: $EXPECTED"
    log "  got:"
    sed 's/^/    /' "$RUN_OUT" >&2 || true
    die "tcc-built hello.exe produced wrong output"
fi

log "[OK-RUN]  hello.exe (expected output present)"
log "=== tcc-build smoke PASSED ==="
