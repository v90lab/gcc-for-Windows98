# Win98 Debug History

Worked examples and root-cause writeups from past Win98-SE-specific bug investigations. Each section captures the symptom, the diagnostic approach, the root cause, the fix, and the lesson worth carrying forward. Append-only record — new investigations land at the top.

For the Win9x debugging intuition that drove most of these (kernel-API-misbehaves vs missing-DLL vs missing-function), see [AGENTS.md §5.8](../../AGENTS.md).

## How investigations land here

When a fix moves from "Open" or "Known broken" to "Confirmed working" in the tracker, the per-round writeup it carried — diagnostic data, test plan, hypotheses, root-cause analysis — gets pulled here as a sealed entry. The active tracker keeps only a one-line confirmation pointing back at the patch. The point of this file is so the next person (or future-AI) chasing a similar bug has worked examples of the diagnostic pattern.

---

## 2026-06-21 — PATH-relative exec `permission denied` (mingw_stat strips S_IRWXO on Win9x)

**Symptom:** from inside `busybox sh`, every non-applet binary invoked by bare name (`ctags`, `make`, `gdb`, `muon`, `diff`, `cmp`, `patch`) failed with `<cmd>: Permission denied`. Full-path form (`/opt/extras/bin/ctags.exe`) worked. bb-shim applets (`ls`, `cp`, `vi`, ...) worked because they short-circuit through busybox's applet dispatch before reaching the PATH walk. The asymmetry between "bare name" and "full path" was the key clue — same binary, two different ash code paths.

**Patches that fixed it:** [`0012-mingw-stat-win9x-uid-defaults.patch`](../patches/busybox-w32/master/0012-mingw-stat-win9x-uid-defaults.patch).

### Round 8 (CONFIRMED FIXED 2026-06-21 ~15:45 UTC)

**Build:** zip `6fe9e646...`, busybox.exe `9dfd1303...`.

**Result:** ✅ confirmed fixed on real Win98. All PATH-relative non-applet binaries (`ctags`, `make`, `gdb`, etc.) now run successfully from inside `sh`.

**Root cause (one-paragraph version):** mingw_stat's `do_lstat` (gated on `ENABLE_FEATURE_EXTRA_FILE_DATA`) probes NT security info via `CreateFile(..., READ_CONTROL, ...)`. On Win9x that call always fails (no security descriptors). The existing failure-branch sets `st_uid = st_gid = 0` and strips `S_IRWXO`. But on Win9x `getuid()` returns `DEFAULT_UID = 4095` (not 0) and every file is in fact world-accessible — so both fallbacks are wrong. Net effect: every stat() returned `st_mode = 0...770` with `st_uid = 0`, which made ash's `find_command::test_exec` fall through to checking S_IXOTH (zero) and reject every PATH-resolved executable with EACCES. Full-path invocations bypassed `find_command` entirely and reached `spawnveq`, whose check is just `S_ISREG && S_IXUSR` (passes — S_IXUSR is still set in 0770), which is why they worked.

**Fix:** add an `else if (is_win9x_proc())` arm in `do_lstat`'s failure branch that sets `st_uid = st_gid = DEFAULT_UID` (matching `getuid()`) and leaves `S_IRWXO` alone. NT behavior preserved verbatim.

**Lesson:** when a file-access predicate misbehaves and the symptom is asymmetric between two code paths that "should be equivalent" (here: bare-name lookup vs absolute path), the asymmetry usually points at a third caller doing its own permission check with different semantics. The cheap-and-fast `spawnveq` check (S_ISREG && S_IXUSR) and the POSIX-faithful `ash::test_exec` check (full uid/gid/mode walk) are both reading the same st_mode, but only one of them tolerates the Win9x st_mode that mingw_stat produces. The fix went into mingw_stat (the producer) rather than ash (the consumer), so it benefits any other busybox-w32 component that calls stat() — `ls -l`, `find -perm`, the `test` builtin, etc.

This is also the second-in-a-row bug where the surface symptom was "in busybox sh, X doesn't work" and the underlying cause was a Win9x msvcrt/kernel-API behavior difference baked deep in mingw.c. Cf. the winansi_vsnprintf and waitpid_child bugs below. Win9x is permissive in the wrong ways: it returns success from APIs that would error on NT (SetConsoleMode with unknown flags, _vsnprintf truncating instead of probing) and returns errors from APIs that succeed on NT (CreateFile with READ_CONTROL). Wine emulates the NT behavior, so none of this reproduces under Wine — only on real Win9x.

### Round 7 — spawn-trace instrumentation (diagnose)

**Build:** zip `7b8046a2...`, busybox.exe `08c3b7ac...`.

**Goal:** find where in the spawn pipeline the `permission denied` is coming from. Two endpoints to discriminate between: (a) busybox's own `mingw_spawnvp` / `spawnveq` check (S_ISREG && S_IXUSR in `process.c`), or (b) something upstream of that — ash's `find_command` doing its own PATH walk before deciding to fork.

**Hypotheses to discriminate:**

1. `find_first_executable` returns NULL — PATH walk doesn't find the binary on Win9x (slash/case mismatch).
2. `find_first_executable` returns the path, `mingw_stat` then returns EACCES inside `spawnveq` (race/sharing-violation between two stat calls on the same file).
3. `mingw_stat` returns success but `spawnveq`'s mode check fails (S_IXUSR not set on .exes for some Win9x-specific reason).
4. The failure is upstream of `mingw_spawnvp` entirely — ash rejects the command before even reaching `find_first_executable`.

**Patch 0011 ([`0011-bbdbg-spawn-instrumentation.patch`](../patches/busybox-w32/master/0011-bbdbg-spawn-instrumentation.patch))** added bbdbg_log calls at three points in `win32/process.c`: `mingw_spawnvp` entry (cmd, has_path, applet hit), per-branch (paths returned by `file_is_win32_exe` and `find_first_executable`), and `spawnveq`'s stat-check (replaced the if/else block with a diagnostic version recording rc, errno, st_mode with S_ISREG and S_IXUSR broken out, plus the verdict OK / EACCES-mode / stat-failed). Unconditional logging — spawn calls are infrequent.

**Test plan:** delete `C:\BBLOG.TXT`, start sh, run `ctags --version` (bare name) and `/opt/extras/bin/ctags.exe --version` (full path), exit, retrieve the log.

**What BBLOG showed (the surprise):**

- The full-path invocation logged exactly what was expected: `SPAWN spawnveq path="/opt/extras/bin/ctags.exe" stat=0 errno=0 st_mode=0100770 S_ISREG=1 S_IXUSR=1`. spawnveq's mode check passed; ctags ran; exit code 0.
- The bare-name invocations logged **nothing at all** at any of the three instrumentation points. No `mingw_spawnvp ENTRY`, no `PATH-branch`, no `spawnveq`. Just a forkshell setup, then waitpid loops, then the child sh exited.

That ruled out hypotheses 1, 2, 3 at once: the failure was upstream of `mingw_spawnvp`. Hypothesis 4 was right. Looking at ash's `find_command` source, the EACCES literally comes from `e = EACCES; if (!test_exec(/*fullname,*/ &statb)) continue;` in the PATH walk — ash does its own POSIX-style executable check via `test_exec` BEFORE deciding to spawn.

The log line `st_mode=0100770` from the full-path case became the smoking gun: `0700 | 0070` for user+group rwx, but **`0000` for "other"**. mingw_stat had stripped S_IRWXO. ash's test_exec uses `stat.st_uid == getuid()` and `stat.st_gid == getgid()` as the matching arms — and grepping mingw.c for where st_uid gets set showed the `else { buf->st_uid = buf->st_gid = 0; buf->st_mode &= ~S_IRWXO; }` failure branch in `do_lstat`. That branch only fires when `CreateFile(..., READ_CONTROL, ...)` fails — which on Win9x is always, because there are no security descriptors to read. Diagnosis → fix is round 8 above.

**Saved log:** `consdiag/run_7/BBLOG.TXT`.

**Lesson worth carrying:** the round-7 instrumentation didn't fire on the failing path, and that "absence of log" was the most informative single data point in the trace. When instrumenting to find a bug, instrument the code path you *think* is failing AND log enough breadcrumbs at upstream entry points to detect "we never got there." Patch 0011's `mingw_spawnvp` ENTRY log was the breadcrumb that proved ash rejected the command before any spawn was attempted.

---

## 2026-06-21 — busybox `sh` raw-escape bug (winansi_vsnprintf on Win9x msvcrt)

**Symptom:** typing Backspace in `sh` printed `<-[1D` (raw CSI cursor-back) instead of erasing a character; `ls --color` printed raw `<-[0;34m` color escapes instead of colored output. Both visible to the user as garbled text on the Win98 console.

**Patch that fixed it:** [`0010-winansi-vsnprintf-fix-win9x.patch`](../patches/busybox-w32/master/0010-winansi-vsnprintf-fix-win9x.patch).

### Round 6 (CONFIRMED FIXED 2026-06-21 12:09 UTC)

**Build:** zip `9c8b428b...`, busybox.exe `d72bfc5e...`.

**Result:** ✅ confirmed fixed on real Win98. `ls --color=always` renders proper colors. Backspace at the `$` prompt visibly erases characters. Sh remained responsive (round 4 hang fix didn't regress).

**Root cause:** winansi_vsnprintf used `_vsnprintf(NULL, 0, format, list)` to probe length — a Windows 7+ msvcrt extension that returns -1 on Win98 SE. The int return was stored in `size_t len`, making the `if (len < 0)` guard unreachable, then -1 propagated back to winansi_vfprintf which `goto abort`'d to the real libc vfprintf, bypassing ansi_emulate entirely. So every escape-bearing vfprintf went out raw; plain-text writes through winansi_fputs still went through ansi_emulate correctly. Round 5 BBLOG confirmed this: every `winansi_vfprintf-entry` with a format like `\e[%u;%um` had no follow-up `winansi_vfprintf-rendered` or `ansi_emulate` log line.

**Fix:** replaces winansi_vsnprintf with an implementation that doesn't depend on the `(NULL, 0)` probe: tries the caller's buffer first, on truncation grows a scratch buffer until `_vsnprintf` fits, and returns the true length. Also adds a defensive `if (len == -1) goto abort;` in winansi_vfprintf before the signed-vs-unsigned size comparison.

**Lesson:** busybox-w32 nominally targets NT-class Windows; Win9x msvcrt has stubs and stubs-with-different-semantics that aren't caught by the export-table allowlist (the function IS exported, just behaves differently — same pattern as the NT-security stubs from [AGENTS.md §5.8](../../AGENTS.md)). When a Win9x quirk turns out to be in stdio/output, suspect the format-string/length-probe path first; the symptom of "format strings logged at vfprintf entry but never rendered" is the diagnostic signature of this class of bug.

### Round 5 — winansi instrumentation (diagnose)

**Build:** zip `afcc772e...`, busybox.exe `c1714d3c...`.

**Goal:** find out why typing Backspace in `sh` prints `<-[1D` and `ls --color` prints raw `<-[...m` color codes, even though patch 0005 forces `terminal_mode()` to `mode=0` (Console-API emulation) on Win9x.

**Hypotheses to discriminate:**

1. `ansi_emulate` / `ansi_emulate_write` is being called but is taking the `esc-via-vt-passthrough` branch because `terminal_mode() & VT_OUTPUT` is set at runtime despite patch 0005 (would mean `is_win9x()` isn't firing on the real box).
2. The escape-bearing writes are going through a path that bypasses winansi entirely (raw `mingw_write(2, ...)` or similar).
3. Something else — possibly the env-var override `BB_TERMINAL_MODE` or `BB_SKIP_ANSI_EMULATION` is being inherited from the parent shell.

**Patch 0009 ([`0009-bbdbg-wansi-instrumentation.patch`](../patches/busybox-w32/master/0009-bbdbg-wansi-instrumentation.patch))** added env-gated (`BB_WANSI_LOG=1`) tracing of every `winansi_write`/`winansi_fwrite`/`winansi_fputs`/`winansi_fputc`/`winansi_vfprintf` call plus every `ansi_emulate`/`ansi_emulate_write` branch decision (`early-out-no-special` / `esc-via-console-api` / `esc-via-vt-passthrough` / `tail-plain`). Has a recursion guard (`wansi_log_busy` flag) because `mingw.h` macro-redirects `vfprintf`/`fprintf`/`fputc`/`fwrite`/`fputs` to the winansi wrappers — bbdbg_log's own stdio calls would otherwise re-enter winansi.

**Test plan:**

```batch
REM 1. Wipe stale log
C:\> IF EXIST C:\BBLOG.TXT DEL C:\BBLOG.TXT

REM 2. Enable winansi tracing
C:\> SET BB_WANSI_LOG=1

REM 3. Run sh and reproduce both symptoms
C:\> CD \OPT\EXTRAS\BIN
C:\OPT\EXTRAS\BIN> SH
$ ls --color=always /opt
$ echo abc<BACKSPACE><BACKSPACE>
$ exit

REM 4. Floppy out C:\BBLOG.TXT
```

**What BBLOG showed:**

- Startup line: `is_win9x=1`, `cur_mode=0` — patch 0005 IS firing, terminal_mode is 0. Rules out hypothesis 3 (BB_TERMINAL_MODE/BB_SKIP_ANSI_EMULATION both null).
- For each colorized filename (e.g. "4dos"): `winansi_fputs` → `ansi_emulate branch=early-out-no-special` — text path works correctly through console API.
- For each color escape `\e[%u;%um`: `winansi_vfprintf-entry` log fires (showing the FORMAT STRING, not the rendered output) but **no follow-up `winansi_vfprintf-rendered` or `ansi_emulate` log**. The escape never reaches the translator.

That last point was the smoking gun. It ruled out hypotheses 1 and 2 simultaneously: the writes DO hit winansi_vfprintf (so not bypassing winansi) but they never reach ansi_emulate (so VT_OUTPUT branch isn't the issue). The control flow had to be exiting winansi_vfprintf before ansi_emulate was called — which led directly to inspecting the `goto abort` path and the vsnprintf shim above it. Diagnosis → fix is the round-6 entry above.

**Saved log:** `consdiag/run_5/BBLOG.TXT`.

---

## 2026-06-21 — busybox `sh` hangs after every external command (GetProcessId returns 0 on Win9x)

**Symptom:** typing any external command at the `$` prompt inside `sh` would never return — sh appeared to hang. Sometimes accompanied by 100% CPU. The command itself ran (output appeared), then sh froze. Even `:q` from inside `vi` hung.

**Patch that fixed it:** [`0008-waitpid-handle-not-pid-on-win9x.patch`](../patches/busybox-w32/master/0008-waitpid-handle-not-pid-on-win9x.patch).

### Round 4 (CONFIRMED FIXED 2026-06-21 01:01 UTC)

**Build:** zip `cfc8c002...`, busybox.exe `a4e83cee...`.

**Result:** ✅ confirmed fixed. Round 4 BBLOG.TXT (4 spawn cycles for `which sh` / `ls` / `echo hello` / `vi`+:q) is 513 lines vs round 3's 13,423 — clean cycle is `ENTRY pid_nr=1` → ~4 polling ticks → `idx=0` → `ENTRY pid_nr=0` (back to prompt). No infinite-loop signature. `$` prompt returns after every command. vi `:q` returns to prompt cleanly.

**Root cause:** `forkparent` and `waitpid_child` both called `GetProcessId(handle)`, which is Vista+; our win98-compat shim returns 0 on Win9x for any non-current-process handle. So `ps_pid=0` was stored at spawn time, `pid=0` was returned from wait, and `waitone()` bailed on `pid <= 0` BEFORE updating job state. `dowait()` then looped forever because `jp->state` never transitioned to JOBDONE — a tight CPU-pegging loop calling `WaitForMultipleObjects` on the already-signaled handle.

**Fix:** on Win9x derive a stable surrogate pid from the handle value (`(uintptr_t)handle & 0x7FFFFFFF | 1`) at both call sites. Equality matching works because both sides use the same derivation. NT path untouched. Re-uses `is_win9x_proc()` from patch 0006, exposed via `mingw.h`.

### Round 3 — bbdbg_log infrastructure + diagnosis

**Build:** zip `0d0cce9b...`.

**Patch added:** [`0007-bbdbg-log-wait-paths.patch`](../patches/busybox-w32/master/0007-bbdbg-log-wait-paths.patch) — file-based wait/spawn logging to `C:\BBLOG.TXT`. Always-on (not env-gated). Logs at `wait_for_child` entry, pre/post `WaitForSingleObject`, pre-`exit`; at `waitpid_child` entry, proclist contents, pre/post `WaitForMultipleObjects`; at `spawn_forkshell` pre/post `mingw_spawn_applet`.

**What BBLOG showed (smoking gun):**

- sh's `waitpid_child` enters with one handle (0x34), calls `WaitForMultipleObjects(1, [0x34], FALSE, 1)`. `blocking=1` is also the timeout — 1ms polling loop, returns 258 (WAIT_TIMEOUT) on each tick.
- When the forkshell child exits, `WaitForMultipleObjects` returns `idx=0` (signaled). `waitpid_child` then calls `GetProcessId(0x34)` → returns 0 (Win9x shim). Returns 0.
- `waitone()` sees `pid <= 0` and `goto out`, skipping the job-state update.
- `dowait()` checks `jp->state == JOBRUNNING` — still TRUE because waitone never updated it. Loops back, calls `waitone` again.
- `waitpid_child` re-enters with the SAME (now-already-signaled) handle. `WaitForMultipleObjects` returns `idx=0` instantly. GetProcessId again returns 0. Re-enters. Infinite loop.

That trace pointed directly at `GetProcessId`, which was Vista+ on Win98, which led to the round-4 fix.

### Rounds 1-2 — refuted hypotheses (and what they ruled out)

Three earlier patches that targeted plausible-but-wrong causes — each shipped, tested, then refuted by the round-3 BBLOG:

- **Patch 0006 v1 (`50788ef2...`, 2026-06-20 afternoon)** — first cut of "mingw_isatty Win9x stderr fallback". Hypothesis: `mingw_isatty(stderr)` was returning 0 on Win98 so winansi's "is this a console?" gate was failing, leaving sh writing raw escapes. Refuted by round-3 consdiag DIAG1.TXT showing `mingw_isatty(stderr) -> result=1` (the API works fine on Win98). Reverted.
- **Patch 0006 v2 (`cd78e846...`, 2026-06-20 evening)** — revised cut of the same idea. Same refutation.
- **Patch 0006 v3 (`a2a63678...`, 2026-06-20 evening)** — pivoted to "skip SetConsoleCtrlHandler on Win9x". Defensive but didn't fix the hang. Kept in the tree because it's correct in principle (the handler did nothing useful on Win9x anyway), but renamed and re-scoped — see [`0006-wait-for-child-skip-ctrl-handler-on-win9x.patch`](../patches/busybox-w32/master/0006-wait-for-child-skip-ctrl-handler-on-win9x.patch).

### Diagnostic data — consdiag round 1 (DIAG1/2/3)

Before patch 0007's BBLOG instrumentation existed, the only way to capture state from a sh-that-hangs was a separate `consdiag.exe` diagnostic binary writing to a fixed file path. `>` redirection from `command.com` broke the test — it made `STD_OUTPUT_HANDLE` a file handle, so any consdiag check that probed `GetConsoleScreenBufferInfo` / `SetConsoleMode` / etc. on stdout returned failure regardless of the actual console state. Fixed path output (`C:\CONSDIAG.LOG`) sidesteps that, at the cost of having to floppy the file out instead of piping it.

- **DIAG1.TXT** (consdiag run from `command.com`): `mingw_isatty(stderr) -> result=1`. → mingw_isatty isn't the bug.
- **DIAG2.TXT** (consdiag run from sh, normal exit): same stdio API values as DIAG1 → sh's forkshell doesn't corrupt stdio. **sh hung after consdiag exited.** → the hang is post-child-exit.
- **DIAG3.TXT** (consdiag run from sh, `--hard-exit` skipping all CRT cleanup): **also hung**. → the hang is not in CRT exit cleanup; it's in sh's parent-side wait on a child that has fully exited.
- **Section 6b on screen** (`SetConsoleCursorPosition` smoke test): user reported `ABCDX` (cursor moved correctly) → console-positioning API works on Win98. So the (then-believed-separate) raw-escape bug was NOT a SetConsoleCursorPosition failure either — turned out to be the round-5 winansi_vsnprintf issue, see above.

The pattern across DIAG1→2→3 was useful: each cut narrowed the failure surface by ruling out a layer that could plausibly have been at fault. By the time round 3's BBLOG instrumentation went out, we knew the bug was in sh's parent-side wait — not in mingw_isatty, not in stdio corruption from forkshell, not in CRT cleanup.

---

## Confirmed working — short reference

These are smaller fixes where the diagnostic journey was less involved. Listed for completeness.

### gdb interactive mode — fixed by `gdb_select` polling patch (2026-06-20)

`WaitForMultipleObjects` on Win9x doesn't accept console-input handles as wait objects (NT-4+ feature). gdb's event loop spun printing `select: No Error.` on the interactive prompt. Fix: add a `gdb_select_is_win9x()` startup probe (`GetVersionEx` → `VER_PLATFORM_WIN32_WINDOWS`) and a `PeekConsoleInput`-based polling path in `gdb/mingw-hdep.c` so gdb's event loop polls console input on Win9x. NT path untouched. Confirmed: typing, tab completion, backspace, and paging all work in interactive `gdb`. Help menu even renders white-bold text correctly. Patch: [`repro/patches/binutils-gdb/2.36.1/0001-mingw-hdep-poll-console-input-on-win9x.patch`](../patches/binutils-gdb/2.36.1/0001-mingw-hdep-poll-console-input-on-win9x.patch).

### busybox `vi` — launches and edits cleanly (2026-06-20 → 2026-06-21)

Initial confirmation 2026-06-20: vi launches and basic editing works from `command.com`. Round 4 (2026-06-21): `:q` from sh returns cleanly to the `$` prompt now that patch 0008 fixed the forkshell wait hang.

### 8.3 short-name dispatch in bb-shim — fixed by `GetLongPathNameA` (2026-06-20)

`command.com` on Win98 hands back the FAT 8.3 SHORT name in uppercase even when the file's LFN is mixed-case (`ls.exe` on disk → `C:\OPT\EXTRAS\BIN\LS.EXE` as seen by the running process). bb-shim's applet-from-argv0 derivation tripped on the short name. Patch: [`repro/bb-shim/bb-shim.c`](../bb-shim/bb-shim.c) — call `GetLongPathNameA` to recover the long name before deriving the applet.

### Lowercase applet dispatch in bb-shim — fixed by `_strlwr` (2026-06-20)

Continuing from the 8.3 fix: busybox's applet table is case-sensitive and all entries are lowercase. The shim lowercases its derived applet name (`_strlwr`) before dispatching. Wine preserves case, so this bug doesn't reproduce under Wine — only on real Win98. Patch: [`repro/bb-shim/bb-shim.c`](../bb-shim/bb-shim.c).

---

## Shipped artifact history (chronological)

Each line names a shipped extras zip + the patch hypothesis under test. Use this to pair past BBLOG/DIAG dumps with the binary they came from.

- **`52def3bb...`** (2026-06-20 morning) — 8.3 + lowercase bb-shim fixes; lacks patch 0006.
- **`50788ef2...`** (2026-06-20 afternoon) — patch 0006 v1 (mingw_isatty fallback). Refuted.
- **`cd78e846...`** (2026-06-20 evening) — patch 0006 v2 (mingw_isatty revised). Same refutation.
- **`a2a63678...`** (2026-06-20 evening) — patch 0006 v3 (skip-ctrl-handler-on-win9x). Defensible but didn't fix the hang.
- **`de5ab5f7...`** (2026-06-20 evening v2) — added consdiag.exe + BUILD.TXT. Diag confirmed mingw_isatty isn't the bug AND the hang is post-child-exit.
- **`0d0cce9b...`** (round 3, 2026-06-21 00:08 UTC) — patch 0007 (bbdbg logging) + consdiag v2. Successfully isolated the hang to GetProcessId-returns-0 in waitpid_child.
- **`cfc8c002...`** (round 4, 2026-06-21 01:01 UTC) — patch 0008 (waitpid handle-not-pid on Win9x). ✅ Hang fixed.
- **`afcc772e...`** (round 5, 2026-06-21 11:27 UTC) — patch 0009 (winansi instrumentation, env-gated on `BB_WANSI_LOG=1`). ✅ Diagnosis successful: pointed at `winansi_vsnprintf` returning -1 silently because of the Win7+-only `_vsnprintf(NULL, 0, ...)` length-probe. Build path also surfaced an `apply-patches.sh` bug where the "already applied?" reverse-check fails when a later patch modifies the immediate context of an earlier patch's hunk (0007 inserted bbdbg_log calls into the middle of 0004 hunk 3's context). Fixed by adding a marker-file short-circuit keyed on the per-component series-hash.
- **`9c8b428b...`** (round 6, 2026-06-21 12:09 UTC) — patch 0010 (winansi_vsnprintf fix for Win9x msvcrt). ✅ Confirmed fixed on real Win98: backspace at the `$` prompt visibly erases, `ls --color=always` renders proper colors. Patches 0007/0009 (debug logging) now safe to remove for the next stable tag.
