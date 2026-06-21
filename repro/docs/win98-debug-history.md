# Win98 Debug History

Worked examples and root-cause writeups from past Win98-SE-specific bug investigations. Each section captures the symptom, the diagnostic approach, the root cause, the fix, and the lesson worth carrying forward. Append-only record — new investigations land at the top.

For the active "what's currently being tested on real hardware" tracker, see [WIN98-MANUAL-CHECKS.md](../../WIN98-MANUAL-CHECKS.md) at the repo root. For the Win9x debugging intuition that drove most of these (kernel-API-misbehaves vs missing-DLL vs missing-function), see [AGENTS.md §5.8](../../AGENTS.md).

## How investigations land here

When a fix moves from "Open" or "Known broken" to "Confirmed working" in the tracker, the per-round writeup it carried — diagnostic data, test plan, hypotheses, root-cause analysis — gets pulled here as a sealed entry. The active tracker keeps only a one-line confirmation pointing back at the patch. The point of this file is so the next person (or future-AI) chasing a similar bug has worked examples of the diagnostic pattern.

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

**Saved log:** [`consdiag/run_5/BBLOG.TXT`](../../consdiag/run_5/BBLOG.TXT).

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
