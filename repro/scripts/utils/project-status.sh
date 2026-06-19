#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/status-common.sh"

status_section "project summary"
status_say "root=$ROOT_DIR"
status_say "matrix=${MATRIX_SELECTED_LABEL:-$MATRIX}"
status_say "target=$TARGET"
status_say "jobs=$JOBS"

status_section "status markers"
find "$OUT_DIR" -maxdepth 1 -type f -name '.status-*' -printf '%f\n' 2>/dev/null | sort || true

status_section "cross toolset report"
bash "$SCRIPT_DIR/cross-toolset-status.sh"

status_section "native toolset report"
bash "$SCRIPT_DIR/native-toolset-status.sh"

status_section "extras toolset report"
bash "$SCRIPT_DIR/extras-toolset-status.sh"

status_section "smoke report"
bash "$SCRIPT_DIR/smoke-tests-status.sh"

status_section "latest master logs"
status_tail_latest "$LOG_DIR" "run-toolchain-build-*.log" 20
status_tail_latest "$LOG_DIR" "run-smoke-pipeline-*.log" 20
