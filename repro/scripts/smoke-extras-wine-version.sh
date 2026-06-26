#!/usr/bin/env bash
# smoke-extras-wine-version.sh — runs each extras tool under wine and confirms
# the binary at least starts up enough to print its version string. Catches
# binaries that pass the PE check but break at runtime (e.g. missing imports,
# crash on entry).
#
# Runs inside the consumer container. Skips cleanly when extras isn't present.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

EXTRAS="${EXTRAS_PREFIX:-/opt/extras}"

if [[ ! -d "$EXTRAS/bin" ]] || [[ -z "$(find "$EXTRAS/bin" -maxdepth 1 -type f -iname '*.exe' -print -quit)" ]]; then
    log "[SKIP] no extras binaries present at $EXTRAS/bin — pipeline likely ran with BUILD_EXTRAS=0"
    exit 0
fi

require_executable wine "wine is required for the extras smoke step"

# tool name -> version-printing argv
declare -A TOOLS=(
    [busybox.exe]="--help"
    [make.exe]="--version"
    [ctags.exe]="--version"
    [diff.exe]="--version"
    [patch.exe]="--version"
    [gdb.exe]="--version"
    [muon.exe]="version"
    [jq.exe]="--version"
    [tcc.exe]="-v"
)

PASS=0
FAIL=0
SKIP=0

log "=== Extras toolset wine --version smoke ==="

for tool in "${!TOOLS[@]}"; do
    exe="$EXTRAS/bin/$tool"
    arg="${TOOLS[$tool]}"

    if [[ ! -f "$exe" ]]; then
        log "[SKIP] $tool (not installed)"
        (( SKIP++ )) || true
        continue
    fi

    if WINEDEBUG=-all wine "$exe" "$arg" >/dev/null 2>&1; then
        log "[OK]   $tool $arg"
        (( PASS++ )) || true
    else
        rc=$?
        log "[FAIL] $tool $arg  (exit=$rc)"
        (( FAIL++ )) || true
    fi
done

log "=== wine smoke: $PASS passed, $FAIL failed, $SKIP skipped ==="

if [[ "$FAIL" -gt 0 ]]; then
    die "Extras toolset wine smoke FAILED ($FAIL tools)"
fi
