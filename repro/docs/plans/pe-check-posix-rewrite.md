# Plan — POSIX sh rewrite of pe-win98-check.sh

**Status:** draft, pre-implementation
**Started:** 2026-06-22
**Driver issue:** ship a single PE-check script that runs in (a) the Linux build
containers, (b) downstream consumers of the cross tarball, AND (c) on real Win98
via busybox-w32 ash + busybox awk + jq. Today the script is bash-only and the
extras toolset has no PE-check tool.

---

## 1. Goal

Replace [`repro/scripts/verifiers/pe-win98-check.sh`](../../scripts/verifiers/pe-win98-check.sh)
with a POSIX-sh-only implementation that runs unmodified under:

- **bash** in the toolchain-builder Ubuntu container (build-time callers)
- **bash / dash** in any downstream Linux env that consumes the cross tarball
- **busybox-w32 ash** on Win98, with busybox awk + jq + native-toolset objdump

Single source of truth lives at `repro/scripts/verifiers/pe-win98-check.sh`;
it gets installed into three places:

1. `out/toolchain/share/win98-verify/` (cross tarball — already shipped)
2. `out/extras-toolset/share/win98-verify/` (NEW)
3. Sourced directly from `repro/scripts/verifiers/` during the build
   (16 callers today — see §6)

## 2. Non-goals

- **Not rewriting in C.** A binary tool would mean two implementations to keep
  in sync with [`win98se-api-allowlist.json`](../../data/win98se-api-allowlist.json)
  - [`win98-behavioral-denylist.json`](../../data/win98-behavioral-denylist.json)
  semantics. Stay in shell.
- **Not changing the sourceable function contract.** Every caller that does
  `source pe-win98-check.sh; pe_check_win98 foo.exe` keeps working with the
  same `PE_CHECK_*` output variables. Internal data structures can change;
  the public interface can't.
- **Not changing the JSON allowlist/denylist file formats.** Those are
  generated from a real Win98 SE install and the consumer side is what's
  flexible here.
- **Not adding new check categories** in this rewrite. Pure behavior
  preservation; new checks (if any) ship in follow-up PRs.

## 3. Acceptance criteria

The rewrite is mergeable when:

1. On every `.exe` and `.dll` shipped in the native + extras toolsets, the
   new script produces byte-identical CLI output to the old one (modulo
   reason-ordering — see §7 for the comparison harness).
2. All 16 in-tree callers (see §6 list) work unmodified.
3. The script runs end-to-end under busybox-w32 ash via Wine against at
   least one PASS binary and one FAIL binary (gdb.exe without
   `PE_CHECK_BUNDLED_DLLS`), with the expected rc.
4. The script runs end-to-end on real Win98 hardware — logged in
   [`WIN98-MANUAL-CHECKS.md`](../../../WIN98-MANUAL-CHECKS.md).
5. The extras package ships its own copy under `share/win98-verify/` +
   `bin/pe-win98-check` (`.bat` wrapper, since FAT32 has no symlinks).

## 4. Phases

### Phase 0 — Feature probe under wine+ash ✅ DONE (2026-06-22)

**Deliverable:** [`repro/scripts/diag/ash-feature-probe.sh`](../../scripts/diag/ash-feature-probe.sh) — landed.

**Coverage matrix:**

| Env                              | PASS | FAIL | WARN | SKIP |
| -------------------------------- | ---- | ---- | ---- | ---- |
| Host bash (Git Bash on Win)      | 38   | 0    | 1    | 2    |
| Host dash                        | 38   | 0    | 1    | 2    |
| wine + busybox-w32 ash           | 36   | 0    | 2    | 3    |

The 36-vs-38 delta on the wine target is the cd-P-symlink probe SKIPping
(FAT32 has no symlinks) and `readlink` being absent — both expected per
the design. WARN entries are missing `jq`/`objdump` from busybox's PATH
inside the container, fine for the probe context (those tools will be
on PATH at real pe-check runtime).

**Confirmed working under busybox-w32 ash + busybox awk:**

- POSIX shell: case patterns, `local`, parameter expansion (`${var%suffix}`,
  `${var#prefix}`, `${var:-default}`, `${var:=default}`), function return
  via `$?`, `$(...)`, heredocs (both `<<EOF` and `<<'EOF'`), `printf '%s\n'`,
  `read -r`, `tr A-Z a-z`
- Awk: associative arrays, `split()`, `match()` + `RSTART`/`RLENGTH`,
  `tolower()`, `gsub()`, `getline < file`, POSIX `[[:space:]]` class,
  multiple `-v`, `$NF`, `index()`
- objdump-row parsing: the `$NF`-on-whitespace-then-hex strategy parses
  BOTH the 3-col and 4-col layouts AND correctly skips the `vma:`
  column-header row — confirming the unified parser doesn't need
  column-count detection (a fragility in the current bash regex pair)

**Confirmed POSIX-strict behavior (rewrite must accommodate, not rely on):**

- `pipe-into-while` runs the right side in a subshell — variables set
  inside don't survive the pipe. The rewrite uses the tempfile pattern
  for any cross-pipe state, as the plan called out.

**Gotchas surfaced**

- `printf 'a\\b\n'` interprets differently in bash vs. dash (`\` + `b`
  vs. BS character). Don't use printf escapes to generate cross-shell
  test data; use literal heredocs.
- `echo "$var"` re-interprets backslash escapes in dash (and sometimes
  busybox), not in bash. Use `printf '%s\n' "$var"` for any value that
  may carry a backslash.

**Decision:** Phase 1 design is safe to lock in as originally written.
Move to Phase 2.

#### Original Phase 0 plan (for reference)

**Goal:** prove out every shell / awk feature the rewrite plans to lean on,
before we commit to a design.

**Deliverable:** `repro/scripts/diag/ash-feature-probe.sh` — a small POSIX-sh
script that exercises each feature the new pe-check needs, writes a result
table to stdout, and exits 0 only if every probe passed.

**What to probe (each one MUST work on busybox-w32 ash + busybox awk):**

| Feature                                  | Why we need it                                |
| ---------------------------------------- | --------------------------------------------- |
| `local` keyword in functions             | Avoid global-variable pollution in helpers    |
| `case "$x" in pat*) ... ;; esac` patterns | Replacement for `[[ == pat* ]]`               |
| `$(command)` substitution                | Resolve self path, run jq, run objdump        |
| `${var%suffix}`, `${var#prefix}`         | Strip CR, strip path components               |
| `${var:-default}` and `${var:=default}`  | Default the data-file paths                   |
| Function return + `$?`                   | Caller-visible pass/fail                      |
| Heredoc `<<EOF`                          | Inline awk script body                        |
| `read -r line` from pipe / file          | Read jq + objdump output                      |
| `printf '%s\n' "$x"`                     | Replace `echo -e`                             |
| `tr 'A-Z' 'a-z'` for case-fold           | Replace `${var,,}` lowercase                  |
| Awk: associative arrays (`a[k]=1`)       | Cache exports + denied sets in awk            |
| Awk: `split($0, parts, "!")`             | Parse the flattened jq stream                 |
| Awk: `match()` + `RSTART` / `RLENGTH`    | Parse objdump import rows (3-col + 4-col)     |
| Awk: `tolower()`, `gsub()`               | Normalize DLL names                           |
| Awk: `getline line < file`               | Pre-load allowlist before scanning dump       |
| Awk: multiple `-v var=val` passes        | Inject `BUNDLED_DLLS` + paths                 |
| Pipe-into-while subshell variable scope  | Confirm we know what is/isn't lost (use temp file if lost) |
| `command -v objdump`                     | objdump existence probe                       |
| `realpath` / `dirname` / `basename`      | Self-locator                                  |

**How to run it:** the probe is its own pipeline step (or invoked manually
via `docker compose exec`) that pipes the script through busybox sh under
wine. Pseudo:

```sh
$ docker compose exec toolchain-builder \
    wine /work/out/extras-toolset/bin/busybox.exe sh \
      /work/scripts/diag/ash-feature-probe.sh
```

**Output contract:** a clean table, one row per probe, `PASS` / `FAIL` /
`SKIP` per row, summary line at the end. On `FAIL`, the probe prints what
the feature was supposed to do vs. what ash/awk actually did.

**Decision point:** if ALL probes pass, proceed to Phase 1. If any
load-bearing probe fails, redesign the rewrite to avoid that feature
(e.g. if `getline < file` is broken in busybox awk, switch to streaming
the flattened JSON via stdin and load it in the awk `BEGIN` block) and
re-run the probe. Don't start the rewrite until the probe is green.

**Risk:** Wine emulates NT, not Win9x. Wine's busybox is the SAME binary
we ship, and the shell features we're probing are entirely in-process
(no CreateProcess / WaitForMultipleObjects / etc. — the §5.8 Win9x kernel
quirk surface). So Wine is a good-enough oracle for THIS probe. Real-
hardware validation still happens in Phase 5; if a feature passes here
but fails on Win98 it's logged like every other Win9x surprise.

### Phase 1 — Design lock-in

Tiny phase. Settle the awk-driven architecture sketched in
[the feasibility convo](../../scripts/verifiers/pe-win98-check.sh#L1-L73):

- Shell driver does: arg parse, self-locate, pre-flatten JSON via jq into
  a stream like `dll!<name>` / `sym!<dll>!<symbol>` / `deny!<dll>!<symbol>`,
  run `objdump -p`, pipe both into one awk script.
- Awk script does: load flattened lists in `BEGIN`, walk objdump output,
  emit `RESULT:pass|fail|skip` and `REASON:<text>` lines.
- Shell driver: read awk's output, populate `PE_CHECK_*` globals, return
  the documented rc.

**Compatibility-critical decisions:**

- **objdump probe order:** `$OBJDUMP` env override → `objdump` → fall back
  to `i686-w64-mingw32-objdump`. Fixes the latent hardcoded `objdump` bug
  in the cross-tarball-on-Linux path too.
- **Self path:** drop the symlink-resolution dance (busybox has no
  `readlink` per the config and FAT32 has no symlinks). Use
  `cd -P "$(dirname "$0")" && pwd` and accept the contract that downstream
  installs put the data files next to the script. Fine for cross + extras
  layouts; sourced-from-repo layout already has the JSONs at a known
  relative path.
- **Public interface:** keep `pe_check_win98 <exe>` returning 0/1/2 and
  setting `PE_CHECK_RESULT` / `PE_CHECK_FAIL_REASON` / `PE_CHECK_BAD_*` /
  `PE_CHECK_OS_*` / `PE_CHECK_SUBSYS_*`. Drop `PE_FORBIDDEN_IMPORT_PATTERNS`
  as a public array (only the README mentions it; no caller iterates).
- **Pipe-subshell variable scope:** if Phase 0 confirms we can't accumulate
  in-pipe, fall back to a tempfile pattern (`awk > $tmp`, then read
  `$tmp` line-by-line in shell — costs one fd dance per check, fine).

### Phase 2 — Side-by-side implementation

- New script lives at `repro/scripts/verifiers/pe-win98-check.posix.sh`.
- Existing `pe-win98-check.sh` is UNTOUCHED in this phase.
- New script's CLI surface and sourceable function contract match
  exactly (so callers could be flipped one at a time later, but they
  won't be in this phase).

### Phase 3 — Comparison harness ✅ DONE (2026-06-22)

**Deliverable:**
[`pe-check-compare.sh`](../../scripts/diag/pe-check-compare.sh) — landed.

**Result matrix:**

| Pass                            | Scanned | OK  | MISMATCH |
| ------------------------------- | ------- | --- | -------- |
| Default (production setting)    | 653     | 653 | 0        |
| `--no-bundled` (FAIL surface)   | 653     | 653 | 0        |

Default uses `PE_CHECK_BUNDLED_DLLS=bcrypt.dll` (matches what
[`verify-extras-package.sh`](../../scripts/verifiers/verify-extras-package.sh)
sets in production); `--no-bundled` exercises the gdb.exe rejection path.

The 653 binary count is the entire `out/native-toolset/`,
`out/extras-toolset/`, and `out/toolchain/` tree (including the
cross-toolchain Linux ELFs, which both checkers correctly SKIP —
confirming SKIP-path parity).

**Implications:**

- The `--ignore-reason-order` flag was implemented but didn't need to fire
  in either pass. The bash-loop vs. awk-walk traversal orders happen to
  match for every binary in the current tree. The flag stays in for
  robustness.
- No edge cases surfaced that the side-by-side script handles differently
  from the original. Phase 5 cutover is safe.

**Re-runnable any time:**

```sh
docker compose exec toolchain-builder /work/scripts/diag/pe-check-compare.sh
docker compose exec toolchain-builder /work/scripts/diag/pe-check-compare.sh --no-bundled
```

#### Original Phase 3 plan (for reference)

**Deliverable:** `repro/scripts/diag/pe-check-compare.sh`. Walks every
`.exe` and `.dll` in `out/native-toolset/`, `out/extras-toolset/`, and
`out/toolchain/` (skipping the consumer image since it would just
redundant). For each binary:

1. Run the old script, capture stdout + rc.
2. Run the new script, capture stdout + rc.
3. Diff.

**Output:** a summary table. `OK` rows where outputs match,
`MISMATCH` rows with both sides quoted. Exit non-zero if any mismatch.

**Acceptance:** zero mismatches. Allow `--ignore-reason-order` flag for
the case where the new script emits failure reasons in a different order
(awk traversal vs. bash loop) — order isn't part of the contract.

Run this against:

- Bare `./build.sh` output (cross + native + extras present)
- Both PASS and FAIL test cases (gdb.exe with/without
  `PE_CHECK_BUNDLED_DLLS=bcrypt.dll`)

This is the main "are we behaviorally equivalent" gate.

### Phase 4 — Wine + ash exercise ✅ DONE (2026-06-22)

**Deliverable:**
[`pe-check-wine-smoke.sh`](../../scripts/diag/pe-check-wine-smoke.sh) — landed.

Runs in the toolchain-builder container — uses the locally-built
`busybox.exe`, `objdump.exe`, and `jq.exe` directly (no consumer-image
unpack needed). PATH inside the busybox-under-wine subshell is set to
the Win-PE tool dirs.

**Test results:**

| #   | Test                                                          | rc   | substring   |
| --- | ------------------------------------------------------------- | ---- | ----------- |
| 1   | PASS path: `gcc.exe`                                          | 0    | `[PASS]`    |
| 2   | FAIL path: `gdb.exe` (no bundled DLLs) — bcrypt rejection     | 1    | `bcrypt`    |
| 3   | Bundled escape: `gdb.exe` + `PE_CHECK_BUNDLED_DLLS=bcrypt.dll`| 0    | `[PASS]`    |
| 4   | SKIP path: non-PE file (`/etc/hostname`)                      | 0    | `[SKIP]`    |

All four pass + 5 wiring sanity checks = 9 OK / 0 FAIL.

**Performance note:** each wine invocation takes ~4 seconds (wine startup
dominates — the script itself is fast). Four tests ≈ 16 seconds total.
On real Win98 the startup cost disappears entirely; this is a pure
Wine-emulation artifact.

**Re-runnable any time:**

```sh
docker compose exec toolchain-builder /work/scripts/diag/pe-check-wine-smoke.sh
```

Phase 5 cutover is gated green.

#### Original Phase 4 plan (for reference)

Add a new smoke step (after extras package, before final verify) that:

1. Copies `pe-win98-check.posix.sh` and the JSONs into `out/extras-toolset/`
   if not already installed
2. Runs `wine busybox.exe sh out/extras-toolset/bin/pe-win98-check.sh
   <known-good>.exe` — expect rc=0
3. Runs the same against gdb.exe — expect rc=1 with `bcrypt` in the reason
4. Runs the same with `PE_CHECK_BUNDLED_DLLS=bcrypt.dll` — expect rc=0

Mirror the test cases in
[smoke-bundled-pe-check.sh](../../scripts/smoke-bundled-pe-check.sh).

This step gates the cutover. If it fails, we know what broke before
swapping the production caller.

### Phase 5 — Cutover ✅ DONE (2026-06-22)

**Sequence as executed:**

1. **Resolver hardening** — added a third probe to
   `_pe_check_resolve_data` in the staging script: try
   `$self_dir/../share/win98-verify/$basename` after the repo- and flat-layout
   probes. Covers the cross-tarball `bin/pe-win98-check` wrapper symlink
   case (busybox has no `readlink`; we needed an explicit relative probe
   instead of symlink walking).
2. **Cutover** — `cp .posix.sh .sh && rm .posix.sh`. Single content swap
   inside the same file path, so git history of `pe-win98-check.sh` shows
   a clean "bash → POSIX" content change, and `.posix.sh` shows as
   deleted.
3. **Back-compat aliases** — added two-line wrappers
   `_pe_check_default_allowlist`/`_pe_check_default_denylist` that delegate
   to `_pe_check_resolve_data`. Lets the existing `install-pe-checker.sh`
   verification hook keep working unmodified.
4. **Install verifier hardened** — updated
   [`install-pe-checker.sh`](../../scripts/install-pe-checker.sh) to
   compare resolved paths via `realpath` instead of literal string
   equality. The resolver doesn't follow symlinks (no `readlink` in
   busybox), so via the bin/ wrapper it returns `bin/../share/foo.json`
   — same file as `share/foo.json` but a different string. Comparing
   via canonical path tests file identity, which is what the verifier
   actually wants.
5. **Extras install step** —
   [`install-pe-checker-extras.sh`](../../scripts/install-pe-checker-extras.sh)
   added. Targets `out/extras-toolset/share/win98-verify/`. Same source
   files as the cross install (single source of truth in
   `scripts/verifiers/` + `data/`). No bin/ wrapper — Win98 command.com
   lacks the `%~dp0` cmd.exe extension, so a relocatable .bat wrapper
   isn't trivial; punted to a follow-up (a small bb-shim-style EXE wrapper
   is the clean option). Bare invocation works today:
   `sh share\win98-verify\pe-win98-check.sh foo.exe`.
6. **Pipeline wiring** — [`run-toolchain-build.sh`](../../scripts/run-toolchain-build.sh)
   gained a `PE_CHECK_SOURCE` shared-input list and:
   - Added the new step to `EXTRAS_STEPS` between
     `install-win98-helpers-extras` and `strip-extras-toolset`.
   - Declared `PE_CHECK_SOURCE` as an input on `install-pe-checker`,
     `install-pe-checker-extras`, and **both** package + manifest steps on
     **both** the cross and extras sides. This is the WIN98_COMPAT_AR
     chaining pattern from AGENTS.md §3.4 — a pe-check source edit must
     re-fire all the way through package, otherwise the change ships in
     `out/<toolset>/share/win98-verify/` but the zip/tarball stays stale.
7. **AGENTS.md** — §3.3 extras phase ordering updated to reflect the
   new step, with a one-paragraph note pointing at this plan.

**Verification on the rebuilt artifacts:**

| Test                                              | Result |
| ------------------------------------------------- | ------ |
| `install-pe-checker` re-run (cross side)          | OK     |
| `install-pe-checker-extras` re-run                | OK     |
| Cross bin/ symlink: PASS path (gcc.exe)           | rc=0   |
| Cross bin/ symlink: FAIL path (gdb.exe, bcrypt)   | rc=1   |
| Extras share/-installed: PASS path (gcc.exe)      | rc=0   |
| Extras share/-installed: FAIL path (gdb.exe)      | rc=1   |
| wine+busybox-ash → extras share/ (gcc.exe PASS)   | rc=0   |
| wine+busybox-ash → extras share/ (gdb.exe bundled)| rc=0   |
| `pe-check-wine-smoke.sh` (9 assertions)           | 9/9    |

The 16 in-tree sourced callers were not touched. Function contract
(`pe_check_win98`, `PE_CHECK_*` globals) preserved; the per-binary
output is identical to the pre-cutover state as proven by Phase 3's
653/653 sweep.

**Known follow-ups (not blocking):**

- bin/ wrapper for Win98 — pick between a small bb-shim-style EXE
  (relocatable, ~30 lines of C) or a hand-curated `setenv.bat` alias.
  Bare-sh invocation works today; this is UX polish.
- Real-hardware validation (Phase 6) — log the extras-side invocation
  in [`WIN98-MANUAL-CHECKS.md`](../../../WIN98-MANUAL-CHECKS.md).
- The comparison harness (Phase 3 deliverable) was removed during
  cutover — its purpose was the bash-vs-POSIX gate, which is now
  closed. Git history preserves it.

#### Original Phase 5 plan (for reference)

Sequence:

1. **Install changes**: extend [`install-pe-checker.sh`](../../scripts/install-pe-checker.sh)
   to (a) ship the script as `pe-win98-check.sh` (no `.posix` suffix) and
   (b) drop into `out/extras-toolset/share/win98-verify/` + a
   `bin/pe-win98-check.bat` wrapper (FAT32 — no symlinks). Add a sibling
   step `install-pe-checker-extras.sh` in `EXTRAS_STEPS` if it's cleaner
   than parameterizing the cross-side step.
2. **Run script swap**: rename `pe-win98-check.posix.sh` →
   `pe-win98-check.sh`, deleting the old. The 16 sourced callers don't
   change because the function contract is preserved.
3. **Full clean build** to confirm nothing regressed.
4. **Re-run Phase 3 comparison harness**? No — we deleted the old. Phase
   3 was the proof gate; once green, we trust it.

### Phase 6 — Real-hardware validation

Log the "ran on real Win98" exercise in
[`WIN98-MANUAL-CHECKS.md`](../../../WIN98-MANUAL-CHECKS.md). Test cases:

1. PASS on a known-good extras binary (`make.exe` or similar)
2. FAIL on a deliberately-broken binary, or use `gdb.exe` without
   `PE_CHECK_BUNDLED_DLLS` (the bcrypt-shim is sitting right there in
   `bin/` and will be picked up by App Directory search — so for the
   FAIL test, may need to `MOVE` or `REN` bcrypt.dll out of the way
   temporarily, OR test against a binary built without the shim).
3. The `--version` smoke-style sweep of all shipped binaries (verify
   exits cleanly).

If this surfaces a Win9x quirk Wine missed, it gets a fix per §5.8
and a section in [`win98-debug-history.md`](../win98-debug-history.md).

## 5. File map (post-rewrite)

| Path                                                                       | Purpose                                          |
| -------------------------------------------------------------------------- | ------------------------------------------------ |
| [`repro/scripts/verifiers/pe-win98-check.sh`](../../scripts/verifiers/pe-win98-check.sh) | The single rewritten POSIX-sh script (after Phase 5) |
| [`repro/scripts/diag/ash-feature-probe.sh`](../../scripts/diag/)            | Phase 0 deliverable. Keep in tree for future ash work |
| [`repro/scripts/diag/pe-check-compare.sh`](../../scripts/diag/)             | Phase 3 deliverable. Keep for regression testing |
| [`repro/scripts/install-pe-checker.sh`](../../scripts/install-pe-checker.sh) | Updated to ship into extras too                   |
| [`repro/scripts/run-toolchain-build.sh`](../../scripts/run-toolchain-build.sh) | New step in EXTRAS_STEPS for extras-side install |

## 6. Caller inventory (sourced uses)

Reminder of the 16 files that today either `source` the old script or
shell out to it; the rewrite must leave all of them unmodified:

- [`repro/scripts/build-bb-shims.sh`](../../scripts/build-bb-shims.sh)
- [`repro/scripts/build-bcrypt-shim.sh`](../../scripts/build-bcrypt-shim.sh)
- [`repro/scripts/build-consdiag.sh`](../../scripts/build-consdiag.sh)
- [`repro/scripts/build-sockdiag.sh`](../../scripts/build-sockdiag.sh)
- [`repro/scripts/install-pe-checker.sh`](../../scripts/install-pe-checker.sh) (modified)
- [`repro/scripts/run-toolchain-build.sh`](../../scripts/run-toolchain-build.sh) (input-dep already)
- [`repro/scripts/run-smoke-pipeline.sh`](../../scripts/run-smoke-pipeline.sh)
- [`repro/scripts/smoke-bundled-pe-check.sh`](../../scripts/smoke-bundled-pe-check.sh)
- [`repro/scripts/smoke-check-extras-pe.sh`](../../scripts/smoke-check-extras-pe.sh)
- [`repro/scripts/smoke-check-native-pe.sh`](../../scripts/smoke-check-native-pe.sh)
- [`repro/scripts/smoke-cmake-build.sh`](../../scripts/smoke-cmake-build.sh)
- [`repro/scripts/verifiers/verify-extras-package.sh`](../../scripts/verifiers/verify-extras-package.sh)
- [`repro/scripts/verifiers/verify-native-package.sh`](../../scripts/verifiers/verify-native-package.sh)
- [`repro/docs/design.md`](../design.md) (doc mention; update text)
- [`repro/scripts/README.md`](../../scripts/README.md) (doc mention; update text)

## 7. Reason-order subtlety (Phase 3 footnote)

The current bash implementation walks the DLL-substring check first, then
the per-import allowlist, then the OS-version check, appending to a
`reasons` array in that order. The awk-driven rewrite naturally walks
in objdump-row order (substring + per-import interleaved by DLL), then
the OS-version check.

So for a binary with TWO failures across categories, the reason text
will be the same but the order may differ. Two options:

- **(A) Match the old order exactly** by emitting separate awk passes
  per category. Cleaner output diff in Phase 3 but two awk invocations.
- **(B) Document that reason order isn't part of the contract** and
  compare with `--ignore-reason-order` in the comparison harness.

Recommend (B). The PE_CHECK_FAIL_REASON consumers (the smoke scripts)
only grep for substrings; they don't depend on order.

## 8. Risks and unknowns

- **busybox awk gotchas**: `gsub`, `match`, multi-dim arrays. Phase 0
  proves out the specific calls we plan to make. If a probe fails, the
  rewrite design adjusts BEFORE we start writing.
- **Wine is NT, not Win9x**: Phase 4's wine-ash exercise catches
  syntax/tool errors but can't catch §5.8-class quirks. Phase 6 is the
  catcher.
- **jq performance on Win98**: each jq invocation is ~50-100ms fork
  overhead. New design: TWO jq calls total (one to flatten the
  allowlist, one to flatten the denylist), all per-DLL lookups happen
  in awk's in-memory arrays. Old design: one jq per imported DLL
  (lazy-load loop). The rewrite is faster, not slower.
- **FAT32 install layout**: no symlinks. Extras side uses a `.bat`
  wrapper or a renamed `.sh` copy. Pick during Phase 5 based on what
  makes the `bin/` PATH-resolvable from busybox ash.
- **Function-name collision**: the sourced function is `pe_check_win98`.
  If a future busybox ash tightening rejects shell-function calls from
  within sourced scripts (unlikely but possible), the rewrite should
  also expose `pe-win98-check` as a direct callable that gives the
  same exit codes — already the design.

## 9. What can be skipped if scope creeps

If the side-by-side comparison turns up edge cases that would take a
real week to chase down, fallback options ordered by preference:

1. **Ship the rewrite only on the extras side** (FAT32 / Win98 install),
   keep the bash version for the cross tarball + build-time. Two
   implementations, but the bash one is already mature.
2. **Cap the extras-side checker to the cheap checks** (DLL-substring +
   OS-version only) and document the per-function check as
   "build-time only". Reduces the awk complexity to almost nothing.
3. **Punt entirely and add a backlog entry**, like the
   `GetProcessId()` audit. The status quo (no extras-side checker) is
   not strictly broken; it's a coverage gap.

The plan above is the "do it right" path; these are the escape hatches.
