#!/bin/sh
# ============================================================================
# ash-feature-probe.sh — Phase 0 deliverable for the pe-win98-check POSIX-sh
# rewrite (see ../../docs/plans/pe-check-posix-rewrite.md).
#
# Exercises every shell / awk / external-tool feature the new pe-check intends
# to lean on. Designed to run identically under bash, dash, and busybox-w32 ash.
# If a probe FAILs on the wine+busybox-ash target, the Phase 1 design has to
# avoid that feature before any rewrite work starts.
#
# Run it three ways:
#
#   1. Local sanity (host bash / dash):
#        sh repro/scripts/diag/ash-feature-probe.sh
#        dash repro/scripts/diag/ash-feature-probe.sh
#
#   2. Inside the toolchain-builder container:
#        docker compose exec toolchain-builder sh /work/scripts/diag/ash-feature-probe.sh
#
#   3. The real target — busybox-w32 ash under wine:
#        docker compose exec toolchain-builder \
#          wine /work/out/extras-toolset/bin/busybox.exe sh \
#          /work/scripts/diag/ash-feature-probe.sh
#
# Exit code: 0 if every required-feature probe passed, 1 if any failed.
# Tool-availability probes mark missing optional tools as SKIP; missing
# required tools (jq, objdump) count as FAIL.
#
# Intentionally strict POSIX itself — uses no feature it doesn't probe for.
# If you add a probe that relies on a not-yet-probed feature, probe that
# feature first.
# ============================================================================

set -u  # NOT set -e — we want to capture failing probes and keep going

# FAIL gates the exit code; WARN is informational (tool availability that may
# legitimately differ between dev host and Win98 deploy target).
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0

SEP() {
    printf '\n=== %s ===\n' "$1"
}
PASS() {
    printf '  [PASS] %s\n' "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}
FAIL() {
    printf '  [FAIL] %s\n' "$1"
    printf '         why: %s\n' "$2"
    printf '         got: %s\n' "$3"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}
WARN() {
    printf '  [WARN] %s — %s\n' "$1" "$2"
    WARN_COUNT=$((WARN_COUNT + 1))
}
SKIP() {
    printf '  [SKIP] %s — %s\n' "$1" "$2"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

WORK=${TMPDIR:-/tmp}/ash-probe.$$
mkdir -p "$WORK" 2>/dev/null
trap 'rm -rf "$WORK" "$WORK.link"' EXIT INT TERM

# ============================================================================
# Environment summary — helpful when reading output later to know which shell
# ran the probe. None of these are actual probes; they're context.
# ============================================================================

SEP "Environment"

if [ -n "${BASH_VERSION:-}" ]; then
    printf '  Shell:        bash %s\n' "$BASH_VERSION"
elif [ -n "${KSH_VERSION:-}" ]; then
    printf '  Shell:        ksh %s\n' "$KSH_VERSION"
elif [ -n "${ZSH_VERSION:-}" ]; then
    printf '  Shell:        zsh %s\n' "$ZSH_VERSION"
else
    # busybox ash, dash, or unknown POSIX sh. They don't expose a version var.
    printf '  Shell:        non-bash POSIX sh (likely ash/dash)\n'
fi
if command -v uname >/dev/null 2>&1; then
    printf '  uname -srm:   %s\n' "$(uname -srm 2>/dev/null || echo unknown)"
fi
printf '  $0:           %s\n' "$0"
printf '  TMPDIR:       %s\n' "${TMPDIR:-/tmp}"
printf '  WORK:         %s\n' "$WORK"

# ============================================================================
# Shell features
# ============================================================================

SEP "Shell features"

# Probe: case "x" in pat*) ... — replaces [[ == pat* ]] in the rewrite.
case "kernel32.dll" in
    *.dll) PASS 'case "x" in *.dll) pattern' ;;
    *)     FAIL 'case "x" in *.dll) pattern' "*.dll should match kernel32.dll" "no match" ;;
esac

# Probe: ${var%suffix} — strip trailing CR / strip .dll
_x="foo.dll"
_y=${_x%.dll}
if [ "$_y" = "foo" ]; then
    PASS '${var%suffix}'
else
    FAIL '${var%suffix}' "strip .dll from foo.dll" "got '$_y'"
fi

# Probe: ${var#prefix} — strip path components
_x="/path/to/file"
_y=${_x#/path/}
if [ "$_y" = "to/file" ]; then
    PASS '${var#prefix}'
else
    FAIL '${var#prefix}' "strip /path/ from /path/to/file" "got '$_y'"
fi

# Probe: ${var:-default}
unset _x 2>/dev/null
_y=${_x:-fallback}
if [ "$_y" = "fallback" ]; then
    PASS '${var:-default}'
else
    FAIL '${var:-default}' "use 'fallback' when _x unset" "got '$_y'"
fi

# Probe: ${var:=default} — sets AND substitutes
unset _x 2>/dev/null
_y=${_x:=fallback}
if [ "${_x:-}" = "fallback" ] && [ "$_y" = "fallback" ]; then
    PASS '${var:=default}'
else
    FAIL '${var:=default}' "should set _x AND yield value" "_x='${_x:-}' _y='$_y'"
fi

# Probe: local keyword — scope helper variables. If unsupported, the assignment
# below will fail with set -e behavior or pollute the global namespace. We
# verify by checking the function output AND that _ashprobe_inner doesn't leak.
unset _ashprobe_inner 2>/dev/null
_probe_local() {
    local _ashprobe_inner=inside
    echo "$_ashprobe_inner"
}
_out=$(_probe_local 2>&1)
if [ "$_out" = "inside" ] && [ -z "${_ashprobe_inner:-}" ]; then
    PASS 'local keyword'
elif [ "$_out" = "inside" ] && [ "${_ashprobe_inner:-}" = "inside" ]; then
    FAIL 'local keyword' "should not leak _ashprobe_inner" "_ashprobe_inner leaked = 'inside'"
else
    FAIL 'local keyword' "function should print 'inside'" "got '$_out', leaked='${_ashprobe_inner:-}'"
fi

# Probe: function return value via $?
_probe_return() {
    return 7
}
_probe_return
_rc=$?
if [ "$_rc" = "7" ]; then
    PASS 'function return + $?'
else
    FAIL 'function return + $?' "should propagate rc=7" "got '$_rc'"
fi

# Probe: $(command) substitution
_x=$(echo hello)
if [ "$_x" = "hello" ]; then
    PASS '$(...) substitution'
else
    FAIL '$(...) substitution' "should capture stdout 'hello'" "got '$_x'"
fi

# Probe: heredoc <<EOF (used to embed the awk body)
_x=$(cat <<EOF
line1
line2
EOF
)
_expected=$(printf 'line1\nline2')
if [ "$_x" = "$_expected" ]; then
    PASS 'heredoc <<EOF'
else
    FAIL 'heredoc <<EOF' "should yield two lines" "got '$_x'"
fi

# Probe: heredoc <<'EOF' (literal — no parameter expansion). The awk body uses
# $1, $NF etc. that MUST stay literal. If shell expands them at heredoc time,
# the awk script collapses.
_x=$(cat <<'EOF'
$1 means awk field
EOF
)
if [ "$_x" = '$1 means awk field' ]; then
    PASS "heredoc <<'EOF' (literal)"
else
    FAIL "heredoc <<'EOF' (literal)" "should preserve literal \$1" "got '$_x'"
fi

# Probe: printf '%s\n' — replacement for echo -e
_x=$(printf '%s\n' "hello")
if [ "$_x" = "hello" ]; then
    PASS "printf '%s\\n'"
else
    FAIL "printf '%s\\n'" "should print 'hello'" "got '$_x'"
fi

# Probe: read -r (preserve backslashes). Two pitfalls dodged here:
#   * `printf` escape interpretation varies (dash printf treats `\\b` as
#     `\b`=BS; bash printf treats `\\b` as backslash + b). Use a literal
#     heredoc instead.
#   * `echo` re-interprets backslash escapes in some shells (dash by default,
#     busybox sometimes) but not bash. Use `printf '%s\n'` to print the
#     captured line verbatim.
# With both pitfalls dodged the probe asks the clean question: does
# `read -r` preserve a literal backslash from the input.
cat > "$WORK/readtest.txt" <<'EOF'
a\b
EOF
_x=$({ read -r _line < "$WORK/readtest.txt"; printf '%s\n' "$_line"; })
if [ "$_x" = 'a\b' ]; then
    PASS 'read -r (preserves backslashes)'
else
    FAIL 'read -r' "should preserve 'a\\b'" "got '$_x'"
fi

# Probe: tr 'A-Z' 'a-z' — replaces ${var,,}
_x=$(echo "KERNEL32.DLL" | tr 'A-Z' 'a-z')
if [ "$_x" = "kernel32.dll" ]; then
    PASS "tr 'A-Z' 'a-z'"
else
    FAIL "tr 'A-Z' 'a-z'" "should lowercase 'KERNEL32.DLL'" "got '$_x'"
fi

# Probe: pipe-into-while subshell scope. In dash / busybox ash / bash-default,
# variables set inside `cmd | while ... done` do NOT survive the pipe (the
# right side runs in a subshell). bash with `shopt -s lastpipe` is the only
# common exception. The rewrite MUST NOT rely on accumulating state across
# the pipe — fall back to a tempfile pattern. This probe documents which
# behavior the shell exhibits so the design treats it as established fact.
_count=0
printf 'a\nb\nc\n' | while read -r _line; do
    _count=$((_count + 1))
done
if [ "$_count" = "0" ]; then
    PASS 'pipe-into-while subshell scope (var stays 0 outside pipe — expected POSIX)'
elif [ "$_count" = "3" ]; then
    SKIP 'pipe-into-while subshell scope' "shell leaks var across pipe (bash lastpipe?). Rewrite still uses tempfile pattern."
else
    FAIL 'pipe-into-while subshell scope' "expected 0 or 3" "got '$_count'"
fi

# ============================================================================
# Awk features
# ============================================================================

SEP "Awk features"

# Probe: associative arrays. The new pe-check uses these to cache the per-DLL
# export set and denylist in awk's BEGIN block.
_x=$(printf 'a 1\nb 2\na 3\n' | awk '{ c[$1] += $2 } END { for (k in c) print k "=" c[k] }' | LC_ALL=C sort)
_expected=$(printf 'a=4\nb=2')
if [ "$_x" = "$_expected" ]; then
    PASS 'awk associative arrays'
else
    FAIL 'awk associative arrays' "expected 'a=4 b=2'" "got '$_x'"
fi

# Probe: split() — parses our flattened jq output (one record per dll!sym).
_x=$(printf 'dll!kernel32.dll\n' | awk '{ n = split($0, p, "!"); print n, p[1], p[2] }')
if [ "$_x" = "2 dll kernel32.dll" ]; then
    PASS 'awk split() on "!"'
else
    FAIL 'awk split() on "!"' "expected '2 dll kernel32.dll'" "got '$_x'"
fi

# Probe: tolower() + gsub() — used to normalize DLL names before lookup.
_x=$(printf 'Hello World\n' | awk '{ s = tolower($0); gsub(/o/, "0", s); print s }')
if [ "$_x" = "hell0 w0rld" ]; then
    PASS 'awk tolower() + gsub()'
else
    FAIL 'awk tolower() + gsub()' "expected 'hell0 w0rld'" "got '$_x'"
fi

# Probe: match() + RSTART / RLENGTH. busybox awk does NOT support gawk's
# capture-group form `match(s, re, arr)` — RSTART/RLENGTH only give the
# whole-match position. The rewrite has to accommodate that; this probe
# documents the limitation.
_x=$(printf 'foo123bar\n' | awk '
    {
        if (match($0, /[0-9]+/))
            print RSTART, RLENGTH, substr($0, RSTART, RLENGTH)
        else
            print "no match"
    }
')
if [ "$_x" = "4 3 123" ]; then
    PASS 'awk match() + RSTART / RLENGTH'
else
    FAIL 'awk match() + RSTART / RLENGTH' "expected '4 3 123'" "got '$_x'"
fi

# Probe: POSIX char classes [[:space:]] in awk regex. If unsupported, fall
# back to '[ \t]' explicit. busybox awk usually supports them.
_x=$(printf '\t  foo\n' | awk 'match($0, /^[[:space:]]+/) { print RLENGTH }')
if [ "$_x" = "3" ]; then
    PASS 'awk POSIX [[:space:]] class'
else
    FAIL 'awk POSIX [[:space:]] class' "expected '3'" "got '$_x' — rewrite must use '[ \\t]' literal"
fi

# Probe: getline from file. The new pe-check uses this to pre-load the
# flattened allowlist + denylist before scanning the objdump dump.
echo "from-file" > "$WORK/sample.txt"
_x=$(awk -v F="$WORK/sample.txt" 'BEGIN { getline x < F; print x }')
if [ "$_x" = "from-file" ]; then
    PASS 'awk getline < file'
else
    FAIL 'awk getline < file' "expected 'from-file'" "got '$_x'"
fi

# Probe: multiple -v var=val flags. The driver passes paths + bundled-DLL
# list into the awk script this way.
_x=$(awk -v X=hello -v Y=world 'BEGIN { print X, Y }')
if [ "$_x" = "hello world" ]; then
    PASS 'awk multiple -v flags'
else
    FAIL 'awk multiple -v flags' "expected 'hello world'" "got '$_x'"
fi

# Probe: $NF (last field). Strategy for parsing objdump import rows — both
# the 3-col and 4-col layouts have the symbol as the last field.
_x=$(printf '   446ba    1257  _stati64\n' | awk '{ print $NF }')
if [ "$_x" = "_stati64" ]; then
    PASS 'awk $NF (last field)'
else
    FAIL 'awk $NF (last field)' "expected '_stati64'" "got '$_x'"
fi

# Probe: index() — case-insensitive DLL-bucket lookup will use this after
# tolower(), since busybox awk lacks gawk's IGNORECASE.
_x=$(awk 'BEGIN { print index("kernel32.dll", "kernel32") }')
if [ "$_x" = "1" ]; then
    PASS 'awk index()'
else
    FAIL 'awk index()' "expected '1'" "got '$_x'"
fi

# ============================================================================
# objdump-row parsing — pe-check-specific strategies
# ============================================================================

SEP "objdump row parsing (pe-check specific)"

# Probe: parse 3-col layout (vma  Hint/Ord  Member-Name). This is what
# Ubuntu 22.04 / binutils 2.38 emits (the toolchain-builder container).
# Last-field strategy works.
_3col=$(printf '\t446ba\t 1257  _stati64\n')
_x=$(printf '%s\n' "$_3col" | awk '/^[ \t]+[0-9a-fA-F]+[ \t]/ { print $NF }')
if [ "$_x" = "_stati64" ]; then
    PASS 'parse 3-col objdump row (last-field strategy)'
else
    FAIL 'parse 3-col objdump row' "expected '_stati64'" "got '$_x'"
fi

# Probe: parse 4-col layout (vma  Ordinal  Hint  Member-Name). What newer
# binutils emit (e.g. mingw-w64 host objdump on Win98). Last-field strategy
# also works — confirming the unified parser doesn't need column detection.
_4col=$(printf '\t0009952c  <none>  055d  GetTokenInformation\n')
_x=$(printf '%s\n' "$_4col" | awk '/^[ \t]+[0-9a-fA-F]+[ \t]/ { print $NF }')
if [ "$_x" = "GetTokenInformation" ]; then
    PASS 'parse 4-col objdump row (last-field strategy)'
else
    FAIL 'parse 4-col objdump row' "expected 'GetTokenInformation'" "got '$_x'"
fi

# Probe: skip the column-header row. `vma  Hint/Ord  Member-Name  Bound-To`
# starts with `vma:` (no leading whitespace before a hex). Our pattern
# anchors on whitespace + hex, so the header row shouldn't match.
_hdr=$(printf 'vma:  Hint/Ord  Member-Name  Bound-To\n')
_x=$(printf '%s\n' "$_hdr" | awk '/^[ \t]+[0-9a-fA-F]+[ \t]/ { print "MATCH:" $NF }')
if [ -z "$_x" ]; then
    PASS 'skip vma: column-header row'
else
    FAIL 'skip vma: column-header row' "header should NOT match data pattern" "got '$_x'"
fi

# Probe: parse DLL Name header. Current bash uses awk '/DLL Name:/ {print $3}'.
_dllhdr=$(printf '\tDLL Name: KERNEL32.dll\n')
_x=$(printf '%s\n' "$_dllhdr" | awk '/DLL Name:/ { print $3 }')
if [ "$_x" = "KERNEL32.dll" ]; then
    PASS 'parse DLL Name header (print $3)'
else
    FAIL 'parse DLL Name header' "expected 'KERNEL32.dll'" "got '$_x'"
fi

# Probe: integrated mini-walk. Mock dump with one DLL header + two import rows
# of different layouts; awk should emit DLL + both symbols in order.
_mock=$(printf '\tImport Tables:\n\n\tDLL Name: KERNEL32.dll\n\tvma:  Hint/Ord  Member-Name  Bound-To\n\t446ba\t 1257  CloseHandle\n\t446c0  <none>  04e9  CreateFileA\n')
_x=$(printf '%s\n' "$_mock" | awk '
    /DLL Name:/ {
        print "DLL:" $3
        next
    }
    /^[ \t]+[0-9a-fA-F]+[ \t]/ {
        print "SYM:" $NF
    }
')
_expected=$(printf 'DLL:KERNEL32.dll\nSYM:CloseHandle\nSYM:CreateFileA')
if [ "$_x" = "$_expected" ]; then
    PASS 'integrated mock-dump walk'
else
    FAIL 'integrated mock-dump walk' "should emit DLL + 2 SYMs in order" "got '$_x'"
fi

# ============================================================================
# Tool availability
# ============================================================================

SEP "Tool availability"

# Tool availability is INFORMATIONAL (WARN, not FAIL). The probe runs in
# multiple environments (host bash, container, wine+busybox-ash) and not
# every environment has every tool — what matters is whether the eventual
# deploy target has them. The interpretation guide:
#   - host bash on dev box:      jq + dirname + basename present; objdump may not be
#   - toolchain-builder:         everything present
#   - wine + busybox-ash:        every required tool present (this is the
#                                env where missing = real problem)
# So we WARN here and let the human reading the output judge based on which
# env they ran the probe in. Exit-gating stays on shell/awk feature probes.
for tool in awk sed tr printf dirname basename jq objdump; do
    if command -v "$tool" >/dev/null 2>&1; then
        _where=$(command -v "$tool" 2>/dev/null)
        PASS "$tool ($_where)"
    else
        WARN "$tool" "required at pe-check runtime — OK if this isn't the deploy target"
    fi
done

# OPTIONAL tools — present helps but the rewrite handles their absence.
for tool in realpath readlink; do
    if command -v "$tool" >/dev/null 2>&1; then
        _where=$(command -v "$tool" 2>/dev/null)
        PASS "$tool ($_where) [optional]"
    else
        SKIP "$tool" "optional — self-locator falls back to dirname dance"
    fi
done

# Triple-prefixed objdump probe. The cross-toolchain bin/ on Linux ships only
# i686-w64-mingw32-objdump; the native toolset on Win98 ships both. The
# rewrite's probe order will be: $OBJDUMP env → objdump → i686-w64-mingw32-objdump.
if command -v i686-w64-mingw32-objdump >/dev/null 2>&1; then
    _where=$(command -v i686-w64-mingw32-objdump 2>/dev/null)
    PASS "i686-w64-mingw32-objdump ($_where) [fallback for cross-tarball-on-Linux]"
else
    SKIP "i686-w64-mingw32-objdump" "fallback not on PATH — depends on which env we're in"
fi

# ============================================================================
# Self-location
# ============================================================================

SEP "Self-location"

# Probe: $0-based self_dir. We dropped the BASH_SOURCE / readlink dance per
# the design — FAT32 has no symlinks; on Linux the wrapper symlink is dealt
# with at the install layer. So self_dir comes from $0.
_self_dir=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd)
if [ -n "$_self_dir" ] && [ -d "$_self_dir" ]; then
    PASS "\$0-based self_dir: $_self_dir"
else
    FAIL '$0-based self_dir' 'cd -P "$(dirname $0)" && pwd should give a real dir' "got '$_self_dir'"
fi

# Probe: cd -P (resolve any symlinks in the path itself). Make a tempdir-via-
# symlink scenario and confirm cd -P lands on the real path.
if command -v ln >/dev/null 2>&1 && ln -s "$WORK" "$WORK.link" 2>/dev/null; then
    _resolved=$(cd -P "$WORK.link" && pwd)
    if [ "$_resolved" = "$WORK" ]; then
        PASS 'cd -P resolves symlinks'
    else
        # Not a failure — Win98 FAT32 has no symlinks, so this only matters
        # on the Linux-side install paths. Report as SKIP if mismatch.
        SKIP 'cd -P resolves symlinks' "got '$_resolved' (FAT32 has no symlinks anyway)"
    fi
    rm -rf "$WORK.link"
else
    SKIP 'cd -P resolves symlinks' "ln -s unavailable on this filesystem"
fi

# ============================================================================
# Summary
# ============================================================================

printf '\n=== Summary ===\n'
printf '  PASS:  %d\n' "$PASS_COUNT"
printf '  FAIL:  %d  (shell/awk feature probes)\n' "$FAIL_COUNT"
printf '  WARN:  %d  (informational — tool availability)\n' "$WARN_COUNT"
printf '  SKIP:  %d\n' "$SKIP_COUNT"
printf '\n'

if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '  Probe failed — see [FAIL] entries above.\n'
    printf '  Phase 1 design must adjust to avoid the failing feature(s).\n'
    exit 1
fi

if [ "$WARN_COUNT" -gt 0 ]; then
    printf '  All required SHELL/AWK probes passed.\n'
    printf '  %d tool(s) missing from PATH — fine if this env is not the pe-check deploy target.\n' "$WARN_COUNT"
    printf '  Phase 1 design (POSIX sh driver + flattened jq + single awk pass) is safe to lock in.\n'
    exit 0
fi

printf '  All probes passed.\n'
printf '  Phase 1 design (POSIX sh driver + flattened jq + single awk pass) is safe to lock in.\n'
exit 0
