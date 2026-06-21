# Win9x shim coverage audit

Pre-patch audit of every API stubbed in [`win98-compat/src/win98_compat.c`](../win98-compat/src/win98_compat.c)
plus the in-tree [`bcrypt-shim/bcrypt.c`](../bcrypt-shim/bcrypt.c), to find callers in
the cross + native + extras source trees whose behavior degrades on real Win9x.

The shim resolves each symbol via `GetProcAddress` at runtime. On NT-class hosts
(Win2000+, XP, ...) the real OS function is called and behavior is exact. On real
Win9x the function is unavailable and a fallback runs — each fallback documents
its trade-off in [`win98_compat.c`](../win98-compat/src/win98_compat.c). For
load-bearing callers the fallback may not be honest enough; this doc enumerates
those.

**Scope.** Only sources that ship inside one of the three archives: cross
toolchain (`gcc-win98-cross-toolchain`), native toolset (`gcc-win98-native-toolchain`),
extras toolset (`gcc-win98-native-toolchain-extras`). Sources that exist in `/work/src/`
but aren't compiled into shipped binaries are noted as "not shipped".

**Method.** Grep across `/work/src/{binutils-gdb, busybox-w32, ctags, diffutils,
gcc, make, mingw-w64, muon, patch, pthread9x}` for each shimmed symbol name (C
extensions, including `.cc/.cpp/.cxx`). Read context around each hit, classify
cosmetic vs load-bearing, cross-check applet enables in [`busybox-w32.config`](../configs/busybox-w32.config)
where relevant.

**Classification.**

- **cosmetic** — value flows into logging, display, or a code path whose only
  effect is informational. User on Win98 sees `0` / `FALSE` / `NULL` instead of a
  real value, no functional impact.
- **load-bearing** — value gates control flow, is used as a map key, becomes a
  syscall argument, or otherwise affects what the program does. Win98 user sees
  silent misbehavior.
- **fixed** — covered by an existing patch in [`repro/patches/`](../patches/).

---

## Summary

| Function (DLL) | Fallback returns | Static callers in shipped src | Load-bearing | Status |
| --- | --- | --- | --- | --- |
| `GetProcessId` (kernel32) | `0` (ERROR_CALL_NOT_IMPLEMENTED) | 7 busybox sites | **5** | partial (ash.c fixed by patch 0008; process.c wait_for_child fixed by 0006; 5 sites unfixed) |
| `GetFinalPathNameByHandleA` (kernel32) | `0` (ERROR_CALL_NOT_IMPLEMENTED) | 0 (all callers runtime-probe) | 0 | safe — shim never invoked; degradation is the caller's existing fallback |
| `GetSystemWow64DirectoryA` (kernel32) | `0` (ERROR_CALL_NOT_IMPLEMENTED) | 0 (all callers runtime-probe) | 0 | safe — shim never invoked |
| `GetLogicalProcessorInformation` (kernel32) | synthesized single-core mask | 1 (muon `os_ncpus`) | 0 | safe — fallback honest, muon gets correct CPU count via GetSystemInfo |
| `GetSystemTimePreciseAsFileTime` (kernel32) | `GetSystemTimeAsFileTime` (~15ms) | 0 (all callers runtime-probe) | 0 | safe — shim never invoked |
| `IsWow64Process` (kernel32) | sets `*p=FALSE`, returns TRUE | 5 (busybox process.c, gdb, gdbserver) | 0 | safe — Win9x IS not-WOW64, fallback is factually correct |
| `GetConsoleWindow` (kernel32) | `NULL` | 3 (busybox ash builtin) | 0 (cosmetic) | benign — ash `hide_console` builtin is a no-op on Win98 |
| `GetFileSizeEx` (kernel32) | composed from `GetFileSize` (exact) | 1 (mingw-w64-crt `ftruncate64`) | 0 | safe — composition is byte-exact |
| `getaddrinfo` (ws2_32) | `EAI_FAIL` | 6+ shipped (busybox networking, gdb ser-tcp) | **all of them** | unfixed — hostname-based networking broken on Win98; numeric-IP fast-path in `xconnect.c` survives |
| `freeaddrinfo` (ws2_32) | no-op | paired with getaddrinfo | n/a | safe by construction (only called on success returns we never produce) |
| `getnameinfo` (ws2_32) | `EAI_FAIL` | 1 (busybox `xmalloc_sockaddr2dotted`) | low (reverse-DNS only) | mostly benign — error-message formatting paths only |
| `SystemFunction036` (advapi32, aka RtlGenRandom) | `rand()` seeded from `GetTickCount` | 0 (busybox runtime-probes; yescrypt comment in shim is stale) | 0 | safe — shim still useful for stack_chk_guard static binding in mingw-w64 ssp; non-crypto seed is acceptable for the only consumer |
| `qsort_s` (msvcrt) | reentrant insertion sort | 1 (ctags `sort_r.h`) | 0 | safe — semantically equivalent; insertion sort O(n²) on small inputs is fine for tag tables |
| `BCryptGenRandom` (bcrypt — bundled DLL shim) | `rand()` seeded from `GetTickCount` | 0 (gnulib runtime-probes; only consumer is libstdc++ random_device at link time) | 0 | safe — non-crypto seed is documented trade-off in AGENTS.md §5.7 |

**Net summary.** Two functions have load-bearing static callers with degraded Win9x behavior:

1. `GetProcessId` — cascade-breaks most busybox `spawn`-using applets via `wait4pid(pid<=0) → -1` (detailed below).
2. `getaddrinfo` — hostname-based networking (`wget`, `ftpget/ftpput`, `httpd`, gdb TCP remote) fails on Win98 with `EAI_FAIL`. Numeric-IP fallback path in [`xconnect.c:223`](../patches/) keeps `1.2.3.4:80` style usage working.

Every other shimmed function is either safe (fallback is honest), or bypassed by callers' own runtime-probe + null-handler patterns.

---

## `GetProcessId` (kernel32) → `0` on Win9x

**Shim fallback.** [`win98_compat.c:155-168`](../win98-compat/src/win98_compat.c) —
if `proc` is the current-process pseudo-handle, returns `GetCurrentProcessId()`;
otherwise sets `ERROR_CALL_NOT_IMPLEMENTED` and returns `0`. There is no
documented inverse-lookup on Win9x.

**Call sites.**

| # | Site | Status | Classification |
| --- | ------ | -------- | ---------------- |
| 1 | `busybox-w32/win32/process.c:453` `mingw_spawn` returns `GetProcessId((HANDLE)ret)` | **unfixed** | **load-bearing — root cause of widespread breakage** |
| 2 | `busybox-w32/win32/process.c:578` `wait_for_child` | fixed ([patch 0006](../patches/busybox-w32/master/0006-wait-for-child-skip-ctrl-handler-on-win9x.patch)) | gated on `!is_win9x_proc()` |
| 3 | `busybox-w32/findutils/xargs.c:213` parallel-mode `ctrl_handler` | **unfixed** | load-bearing on Ctrl+C path only |
| 4 | `busybox-w32/coreutils/timeout.c:57` `kill_child` atexit | **unfixed** | load-bearing |
| 5 | `busybox-w32/coreutils/timeout.c:215` `timeout_main` | **unfixed** | load-bearing |
| 6 | `busybox-w32/shell/ash.c:4949` `dowait` | fixed ([patch 0008](../patches/busybox-w32/master/0008-waitpid-handle-not-pid-on-win9x.patch)) | handle-derived surrogate pid |
| 7 | `busybox-w32/shell/ash.c:6232` `forkparent` | fixed ([patch 0008](../patches/busybox-w32/master/0008-waitpid-handle-not-pid-on-win9x.patch)) | handle-derived surrogate pid |
| — | `gcc/libsanitizer/sanitizer_win.cpp:94` `GetProcessId(GetCurrentProcess())` | safe + not shipped | uses pseudo-handle (shim returns real PID); libsanitizer not built into our toolset |
| — | mingw-w64 headers (`processthreadsapi.h`, `audiopolicy.h`, widl `winbase.h`) | n/a | declarations only |
| — | binutils-gdb, ctags, make, diffutils, patch, muon, pthread9x | clean | no hits |

### Why site #1 is the dominant problem

`mingw_spawn` is `pid_t spawn(char **)` macro-redirected from the libbb-wide
`spawn()` (`include/mingw.h:616`). On Win9x it returns `0` (shim's documented
fallback) instead of a real pid. The very next thing every caller does is feed
it to `wait4pid`:

```c
// libbb/xfuncs.c:382
int FAST_FUNC wait4pid(pid_t pid) {
    if (pid <= 0) return -1;   // bails before OpenProcess / WaitForSingleObject
    ...
}
```

so **every applet using `spawn() + wait4pid()` or `spawn_and_wait()` returns -1
immediately on Win98** instead of waiting for and reading the child's exit code.

Affected applets enabled in [`busybox-w32.config`](../configs/busybox-w32.config):

- **`find -exec`** — entire `-exec` semantics broken (`find.c:829`)
- **`xargs`** single-process path (`xargs.c:351`); `spawn_and_wait` fallbacks at 289/292
- **`flock <cmd>`** — exit code lost (`flock.c:112`)
- **`install -o/-g`** — chown/chgrp invocations report failure (`install.c:240`)
- **`inotifyd`** — user-supplied event scripts (`inotifyd.c:212,300`)
- **`watch`** — every periodic invocation (`watch.c:130`)
- **`crontab`** — editor-session wait (`crontab.c:78`)
- **`time <cmd>`** — `resuse_end(pid=0, ...)` (`time.c:453,463`)

Sites #4/#5 break standalone `timeout` — the timer fires but `kill(pid=0, signo)`
no-ops, so the child runs forever. Site #3 leaks children on Ctrl+C in
`xargs --parallel`.

`xspawn` (the bail-on-failure wrapper) has zero callers in this tree.

### Reproduction note

None of this reproduces under Wine — Wine emulates NT's `GetProcessId`. The
class matches the AGENTS.md §5.8 intuition: "Win9x is permissive in the wrong
ways; modern Windows and Wine are uniformly stricter".

### Proposed fix shape

Two-site patch (mirror of patch 0008's pattern):

1. `mingw_spawn` in `win32/process.c:447`: derive a stable surrogate pid from the
   handle on Win9x (`(uintptr_t)handle & 0x7FFFFFFF | 1`) instead of calling
   `GetProcessId`. Side-table the `surrogate_pid → HANDLE` mapping so it can be
   recovered.
2. `waitpid` in `win32/process.c:25`: on Win9x, look up the side-table to get
   the HANDLE directly instead of `OpenProcess(pid)`. Fall through to the
   existing path on NT.

Sites #4/#5 (`timeout`) want a separate small patch: call `TerminateProcess(child, ...)`
directly instead of `kill(GetProcessId(child), signo)` on Win9x — the `child`
HANDLE is already in scope.

Site #3 (`xargs --parallel` Ctrl+C) can use `TerminateProcess(G.procs[i], ...)`
on Win9x with the same logic.

---

## `GetFinalPathNameByHandleA` (kernel32) → `0` on Win9x

**Shim fallback.** [`win98_compat.c:62-75`](../win98-compat/src/win98_compat.c) — sets
`ERROR_CALL_NOT_IMPLEMENTED`, returns `0`. No symlink/junction concept on Win9x.

**Call sites.**

All call sites are **runtime probes** via `GetProcAddress` — they don't statically
import the symbol, so the shim's IAT slot is never referenced and our wrapper is
not called. The callers already detect "function unavailable" and skip the
symlink-resolution path.

| Site | Pattern | Win9x behavior |
| ------ | --------- | ---------------- |
| `diffutils/lib/stat-w32.c:98` (gnulib) | `GetProcAddress(kernel32, "GetFinalPathNameByHandleA")` | probe → NULL → fallback to non-symlink path |
| `patch/lib/stat-w32.c:68` (gnulib) | same | same |
| `binutils-gdb/gnulib/import/stat-w32.c:85` | same | same |
| `busybox-w32/win32/mingw.c:1701-1723` `mingw_readlink` | `DECLARE_PROC_ADDR` + `INIT_PROC_ADDR` | probe → NULL → `errno=ENOSYS`, `readlink()` fails (correct — no symlinks on Win98) |

**Verdict.** No static callers, no load-bearing degradation. Shim is dead code
for the in-tree consumers but kept for downstream users of the cross toolchain
who might link without a probe.

---

## `GetSystemWow64DirectoryA` (kernel32) → `0` on Win9x

**Shim fallback.** [`win98_compat.c:78-90`](../win98-compat/src/win98_compat.c) — sets
`ERROR_CALL_NOT_IMPLEMENTED`, returns `0`. There is no SysWOW64 on 32-bit OSes.

**Call sites.**

Both gdb hits are explicit runtime probes — there was an earlier patch in
upstream gdb to dlsym this for exactly the pre-Vista case (the source comment
says `/* win98: resolve GetSystemWow64DirectoryA via GetProcAddress */`).

| Site | Pattern | Win9x behavior |
| ------ | --------- | ---------------- |
| `binutils-gdb/gdb/windows-nat.c:1951` | `GetProcAddress(k32, "GetSystemWow64DirectoryA")` | probe → NULL → skip WOW64 path-rewrite |
| `binutils-gdb/gdbserver/win32-low.cc:1236` | same | same |

**Verdict.** No static callers. Safe.

---

## `GetLogicalProcessorInformation` (kernel32) → synthesized single-relationship

**Shim fallback.** [`win98_compat.c:93-127`](../win98-compat/src/win98_compat.c) —
calls `GetSystemInfo`, builds a one-entry `SYSTEM_LOGICAL_PROCESSOR_INFORMATION`
record with `Relationship = RelationProcessorCore` and a `ProcessorMask` covering
all CPUs reported by `dwNumberOfProcessors`.

**Call sites.**

| Site | Usage | Win9x behavior |
| ------ | ------- | ---------------- |
| `muon/src/platform/windows/os.c:89,109` `os_ncpus` | counts mask bits to seed `-j` default | gets correct count via `GetSystemInfo` (Win9x is single-CPU in practice → `-j1`) |

**Verdict.** Static caller, but the shim's synthesis is honest. Safe.

---

## `GetSystemTimePreciseAsFileTime` (kernel32) → falls back to `GetSystemTimeAsFileTime`

**Shim fallback.** [`win98_compat.c:130-140`](../win98-compat/src/win98_compat.c) —
calls `GetSystemTimeAsFileTime` (~15ms resolution vs. ~1µs on Win8+).

**Call sites.**

All call sites are runtime probes (gnulib in diffutils/patch/binutils-gdb,
mingw-w64's own gettimeofday and winpthreads). The shim is never invoked from
static callers.

| Site | Pattern | Win9x behavior |
| ------ | --------- | ---------------- |
| `diffutils/lib/gettimeofday.c:56` (gnulib) | `GetProcAddress(kernel32, "GetSystemTimePreciseAsFileTime")` | probe → NULL → use `GetSystemTimeAsFileTime` |
| `patch/lib/gettimeofday.c:48` (gnulib) | same | same |
| `binutils-gdb/gnulib/import/gettimeofday.c:58` | same | same |
| `mingw-w64/mingw-w64-crt/misc/gettimeofday.c:54` | same | same |
| `mingw-w64/mingw-w64-libraries/winpthreads/src/misc.c:43` | same | same |
| `mingw-w64/mingw-w64-libraries/winpthreads/src/clock.c:59` | same | sets `CLOCK_REALTIME_COARSE` |

**Verdict.** No static callers; the shim is only kept for downstream consumers.
Safe.

---

## `IsWow64Process` (kernel32) → `*p=FALSE`, returns `TRUE`

**Shim fallback.** [`win98_compat.c:143-153`](../win98-compat/src/win98_compat.c) —
sets `*is_wow64 = FALSE` and returns `TRUE`. Win9x is 32-bit only and never a
WOW64 process — this is factually correct, not a degradation.

**Call sites.**

| Site | Usage | Win9x behavior |
| ------ | ------- | ---------------- |
| `busybox-w32/win32/process.c:924,928` `process_architecture_matches_current` | guards `kill_signal_by_handle`'s cross-process injection | both calls return `FALSE` → both procs deemed same-arch (correct on Win9x) |
| `binutils-gdb/gdb/windows-nat.c:2206,3040` | gdb's debuggee-architecture detection | correctly reports inferior as not-WOW64 |
| `binutils-gdb/gdbserver/win32-low.cc:391` | gdbserver same | same |

**Verdict.** Static callers, but the fallback is correct (not degraded). Safe.

---

## `GetConsoleWindow` (kernel32) → `NULL`

**Shim fallback.** [`win98_compat.c:171-181`](../win98-compat/src/win98_compat.c) —
returns `NULL`. Documented "no console attached" return value.

**Call sites.**

| Site | Usage | Win9x behavior |
| ------ | ------- | ---------------- |
| `busybox-w32/shell/ash.c:3140-3152` `console_state` / `hide_console` | ash builtin to hide/show the console window (`hidecons`/`showcons`-style) | `IsWindowVisible(NULL)` → `FALSE` so `console_state` returns 1 ("hidden"); `ShowWindow(NULL, ...)` is a no-op → toggle silently does nothing |

**Verdict.** Cosmetic-ish — one ash builtin doesn't work on Win98. The shell
itself keeps running. Single-applet impact; no audit-action required unless
someone actually needs the hide/show feature on Win98.

**If we wanted to fix.** Wrap the calls in `if (!is_win9x_proc())` and add a
simple "not supported on Win9x" message — pattern matches patch 0006.

---

## `GetFileSizeEx` (kernel32) → composed from `GetFileSize`

**Shim fallback.** [`win98_compat.c:184-201`](../win98-compat/src/win98_compat.c) —
composes the 64-bit size from `GetFileSize`'s split low/high DWORD return.
Byte-exact equivalence with the native API.

**Call sites.**

| Site | Usage | Win9x behavior |
| ------ | ------- | ---------------- |
| `mingw-w64/mingw-w64-crt/stdio/ftruncate64.c:153` | mingw-w64's `ftruncate` impl, used by `make`'s `tmpfile` cleanup et al | shim returns exact size — correct |
| `diffutils/lib/stat-w32.c:332` (gnulib comment) | reference in comment | n/a |
| `diffutils/gnulib-tests/ftruncate.c:54` | gnulib test, not shipped | n/a |
| `patch/lib/stat-w32.c:293` (gnulib comment) | reference | n/a |
| `binutils-gdb/gnulib/import/stat-w32.c:319` (gnulib comment) | reference | n/a |

**Verdict.** Safe across all consumers — composition is exact.

---

## `getaddrinfo` / `freeaddrinfo` / `getnameinfo` (ws2_32) → `EAI_FAIL`

**Shim fallback.** [`win98_compat.c:205-251`](../win98-compat/src/win98_compat.c) —
returns `EAI_FAIL`, sets `*res = NULL` (for getaddrinfo), zero-length output
strings (for getnameinfo). `freeaddrinfo` is a no-op because we never allocate.

Real Win98 has `gethostbyname` in `ws2_32.dll` but not `getaddrinfo` — emulation
is possible but not implemented (~100 LOC, memory-management cost). See the
in-source comment for the upgrade path.

**Call sites.** (static callers in shipped binaries)

**busybox networking** (only applets enabled in [`busybox-w32.config`](../configs/busybox-w32.config)):

| Site | Applet | Win9x behavior |
| ------ | -------- | ---------------- |
| `libbb/xconnect.c:261` `host2sockaddr` | helper used by every shipped networking applet | numeric-IP fast-path (`xconnect.c:223-258`) intercepts before getaddrinfo; hostnames return EAI_FAIL → `bb_error_msg_and_die` |
| `libbb/xconnect.c:476` `xmalloc_sockaddr2dotted` | reverse-DNS (getnameinfo) for error/status messages | falls back to numeric `inet_ntop` formatting (gracefully) |
| `libbb/inet_common.c:159` `INET_resolve` | older resolver wrapper (unused by enabled applets — `ifconfig`/`route` disabled) | n/a |
| `networking/wget.c:1226` (via `xhost2sockaddr`) | `wget` | broken with hostnames; works with `http://1.2.3.4/...` |
| `networking/ftpgetput.c:336` (via `xhost2sockaddr`) | `ftpget`/`ftpput` | same |
| `networking/httpd.c:2632` (via `host2sockaddr`) | `httpd` (proxy host config only — server itself binds locally) | proxy backend can't resolve hostnames |
| `networking/win32/net.c:43-48` | the busybox `getaddrinfo` wrapper that adds the `mingw_` prefix; itself calls into our shimmed symbol | passthrough |

Disabled in our config (not shipped — no concern): `nslookup`, `ntpd`, `tcpudp`,
`inetd`, `pscan`, `ifconfig`, `nc_bloaty`, `udhcpc`/`udhcpd`, `tftp`.

**gdb / gdbserver** — only the gdb client is in our extras package:

| Site | Usage | Win9x behavior |
| ------ | ------- | ---------------- |
| `binutils-gdb/gdb/ser-tcp.c:293` `net_open` | gdb `target remote tcp:host:port` | EAI_FAIL → prints `host: cannot resolve name: ...` → connect fails cleanly; numeric IP works |
| `binutils-gdb/gdb/nat/linux-osdata.c:845,853` | Linux-only `/proc/net/tcp` parser, not built on mingw32 | n/a |
| `binutils-gdb/gdbserver/remote-utils.cc:182,260,388`, `gdbreplay.cc:195,271` | gdbserver / gdbreplay binaries | not shipped (we `--disable-gdbserver` in the gdb build) |
| `gcc/libcody/netserver.cc:112`, `gcc/c++tools/server.cc:334`, `gcc/gcc/ada/socket.c:715`, `gcc/libsanitizer/tsan/...:2094` | gcc-side network code | not in our shipped build (no libcody-server, no Ada, no sanitizer) |
| `mingw-w64/mingw-w64-crt/libsrc/wspiapi/WspiapiLoad.c:34` | wspiapi static fallback library; only linked when consumer `#include <wspiapi.h>` | nobody in our tree does, so not pulled in |

### Classification

`getaddrinfo` is **load-bearing for every networking use that resolves a
hostname**. The fallbacks downstream of EAI_FAIL are tool-specific:

- busybox `wget`/`ftp*` → fatal error, applet exits with message
- busybox `httpd` proxy → proxy backend unreachable, but the server keeps serving
- gdb TCP remote → connect fails with a clear message

Numeric-IP usage continues to work for everything (`xconnect.c`'s fast-path
strips the hostname-resolution requirement when the input parses as an IPv4
literal).

### Reproduction note

Wine emulates `getaddrinfo` against the host's resolver, so this fails only on
real Win98 — same class as the `GetProcessId` bug per AGENTS.md §5.8.

### Proposed fix shape

Two options:

1. **Implement `gethostbyname`-based getaddrinfo emulation in the shim** —
   ~100 LOC against `winsock.h`'s `gethostbyname`. Returns a single IPv4 result
   for `node` as `AF_INET` + `SOCK_STREAM`. Memory-managed via a static
   single-slot or `malloc`/`free` (paired `freeaddrinfo` would need to actually
   free). Honest enough for the busybox / gdb consumers above.
2. **Leave as-is and document** — numeric IPs work, hostnames don't. Acceptable
   for a 1998-era target where most users would supply numeric IPs anyway.

Lean toward option 1 because the diff is small and unblocks `wget`/`ftpget` for
Win98 archive grabs — exactly the use case the toolset enables. Track separately
from the GetProcessId fix.

---

## `SystemFunction036` (advapi32, aka `RtlGenRandom`) → non-crypto rand

**Shim fallback.** [`win98_compat.c:256-271`](../win98-compat/src/win98_compat.c) —
seeds `srand(GetTickCount())` once, then fills the buffer with `rand() & 0xff`.
Documented non-crypto fallback (same trade-off as the bcrypt shim).

**Call sites.**

| Site | Pattern | Win9x behavior |
| ------ | --------- | ---------------- |
| `busybox-w32/win32/mingw.c:345-351` `mingw_get_random_bytes` | `DECLARE_PROC_ADDR` + `INIT_PROC_ADDR` runtime probe | probe → NULL → caller falls back to its own non-crypto path; shim never invoked |
| `mingw-w64/mingw-w64-crt/secapi/rand_s.c:32` | `GetProcAddress(LoadLibraryW(L"advapi32.dll"), "SystemFunction036")` | probe → NULL → `rand_s` returns error |
| `mingw-w64/mingw-w64-libraries/winstorecompat/src/SystemFunction036.c` | winstore-only shim, not built for mingw32 | n/a |

No static-import callers in shipped source. The `libxcrypt`-derived `yescrypt`
code mentioned in [`win98_compat.c`](../win98-compat/src/win98_compat.c)'s preamble
doesn't reference SystemFunction036 by name in our `busybox-w32/libbb/yescrypt/`
tree — that comment may be stale or referred to an earlier yescrypt version. The
shim still serves mingw-w64's `ssp/stack_chk_guard.c` static use of RtlGenRandom
for stack-canary init (called at process startup via `__main`), which is
non-crypto-critical (canary just needs to be unguessable, not cryptographically
strong).

**Verdict.** Safe. Non-crypto fallback acceptable for the only realistic
consumer (stack canary seed).

---

## `qsort_s` (msvcrt) → reentrant insertion sort

**Shim fallback.** [`win98_compat.c:281-300`](../win98-compat/src/win98_compat.c) —
small reentrant insertion sort threading `ctx` through. O(n²) but consumers sort
small arrays.

**Call sites.**

| Site | Usage | Win9x behavior |
| ------ | ------- | ---------------- |
| `ctags/main/sort_r.h:307` | `sort_r` wrapper's Windows backend (`qsort_s` is the only reentrant Windows qsort) | shim sorts correctly; insertion sort fine for ctags tag tables |

**Verdict.** Safe. Semantically equivalent to the native API; performance
overhead negligible for the call sites.

---

## `BCryptGenRandom` (bcrypt — bundled DLL shim, not the win98compat archive)

**Shim implementation.** [`bcrypt-shim/bcrypt.c`](../bcrypt-shim/bcrypt.c) —
separate from the win98-compat static archive. Ships as a real `bcrypt.dll` next
to consumers in `out/extras-toolset/bin/`. The DLL exports only
`BCryptGenRandom`, implemented as `srand(GetTickCount()) + rand()`.

**Call sites.**

| Site | Pattern | Win9x behavior |
| ------ | --------- | ---------------- |
| `diffutils/lib/getrandom.c:78` (gnulib) | `GetProcAddress(bcrypt, "BCryptGenRandom")` (runtime probe) | probes our bundled DLL successfully → calls our impl → non-crypto bytes |
| `binutils-gdb/gnulib/import/getrandom.c:79` | same | same |
| libstdc++ 11 `<random>` `std::random_device::_M_init` | **static import** baked into anything linking `-static-libstdc++` (currently `gdb.exe`) | resolves to our bundled `bcrypt.dll` via App Directory search → non-crypto bytes |

**Verdict.** Safe. Non-crypto seed is the documented trade-off (AGENTS.md §5.7).
gdb only uses the entropy as a seed source, not for keys.

---

## Symbols intentionally NOT in the shim

These would also be candidates for Win9x absence but we don't shim them — noted
here so a future audit doesn't re-investigate the same ground.

- **`BCryptOpenAlgorithmProvider` / `BCryptCloseAlgorithmProvider`** — not
  imported by anything in our toolset (gnulib `getrandom` uses the simpler
  `BCryptGenRandom` flag-based form; libstdc++ same).
- **`InitializeCriticalSectionEx`, `WaitOnAddress`, `WakeByAddressSingle`** —
  Vista+/Win8+ sync primitives. mingw-w64's winpthreads / pthread9x detect
  absence and use the older equivalents. No static callers.
- **`CreateSymbolicLinkA/W`** — not used by anything in our extras. busybox's
  `ln -s` falls back to copy on Windows regardless.

If any of these become a problem later, the §5.6 / §5.7 patterns in AGENTS.md
apply directly.

---

## Audit method note (for re-running)

Source trees are in named Docker volumes (`gcc-win98-src`) at `/work/src/`
inside the `toolchain-builder` container. To re-run any of these greps:

```sh
docker compose -f repro/docker-compose.yml exec -T toolchain-builder bash -c '
  grep -rn --include="*.c" --include="*.cc" --include="*.cpp" --include="*.cxx" \
           --include="*.h" --include="*.hpp" \
           -wE "<SYMBOL>" /work/src \
    | grep -vE "(mingw-w64/mingw-w64-(headers|tools))"
'
```

The exclude filter drops mingw-w64's own header declarations and widl IDL
sources, which are noise for "who calls X?" questions.
