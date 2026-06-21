# Networking on Win98: status, deferrals, and the path to re-enabling

If you're here because you tried to flip a `CONFIG_*` flag back on in [`repro/configs/busybox-w32.config`](../configs/busybox-w32.config) and want to understand the cost first, read this whole doc. The disable list is intentional, the bugs are real, and the fixes aren't cheap.

## TL;DR

| Status | Applets |
| --- | --- |
| **Ships and works** | `nc` (netcat), `httpd` (static-file/CGI server), `ping` *(if enabled — currently off but no bug)* |
| **Disabled because broken on real Win98** | `wget`, `whois`, `ftpget`, `ftpput` |
| **Disabled because dependents of above** | `ssl_client`, `tls` |
| **Disabled because cosmetic + not worth the dep weight** | `ipcalc` |
| **NOT disabled but landmined — do NOT enable without reading §"latent footguns"** | `ftpd`, `nslookup`, `telnet`, `telnetd`, `tftp`, `tftpd`, `traceroute`, `udhcpc/d`, `dnsd` |

**Why:** real Win98 SE's `msvcrt.dll!_open_osfhandle` rejects SOCKET handles entirely (`errno=22`, EINVAL). busybox-w32's whole networking model is "create a SOCKET, wrap it as a POSIX fd via `_open_osfhandle`, then use stdio (`fdopen`/`fgets`/`fprintf`) on the fd". That model can't work on Win9x without infrastructure we haven't built. Wine emulates NT and doesn't reproduce the bug — every networking applet passes the smoke tests in CI; they fail only on real hardware.

**Verify:** [`repro/diag/sockdiag.c`](../diag/sockdiag.c) is the standalone diagnostic. Run `sockdiag.exe` on Win98 — see Section 4 "Socket-creation variants" in the log; every `_open_osfhandle` line says `FAILED fd=-1 errno=22 (Invalid argument)`. Reference log: [`consdiag/SOCKDIAG_2.LOG`](../../consdiag/SOCKDIAG_2.LOG) (2026-06-21 on real Win98 SE).

## The root bug

```c
// busybox-w32/win32/net.c — mingw_socket()
s = WSASocket(domain, type, protocol, NULL, 0, 0);   // OK on Win9x
sockfd = _open_osfhandle((intptr_t)s, O_RDWR|O_BINARY);  // FAILS on Win9x
```

Win9x msvcrt's fd table simply doesn't accept socket handles. On NT it's worked for decades as an undocumented behavior; on Win98 SE it doesn't.

Concretely from sockdiag on Win98 SE:

- All 6 socket-creation variants (BSD `socket()` and `WSASocket` with every combination of `protocol={0,IPPROTO_TCP}` × `dwFlags={0,WSA_FLAG_OVERLAPPED}`) **succeed** — the raw SOCKET works fine.
- `_open_osfhandle((intptr_t)s, O_RDWR|O_BINARY)` returns `-1 errno=22` for every one of them.
- A subsequent `connect()` + `send()` + `recv()` on the raw SOCKET completes an HTTP 1.1 round-trip against `1.1.1.1:80` and gets back `HTTP/1.1 301 Moved Permanently`.

So the network layer works. The fd-wrapping layer doesn't. Everything downstream that uses the fd via stdio (`fdopen`/`fgets`/`fputs`/`fprintf`) is dead in the water.

Same class as [AGENTS.md §5.8](../../AGENTS.md) "Win9x is permissive in the wrong ways", just inverted: NT msvcrt has an undocumented permissive behavior; Win9x msvcrt doesn't.

## What it would take to fix HTTP (one tier)

Three sketched approaches, in increasing scope (see [`BACKLOG.md`](../../BACKLOG.md) for the full version):

### Strategy A — pipe-bridge in `mingw_socket` on Win9x
`mingw_socket` creates SOCKET + anonymous pipe pair + helper thread per socket. Thread does `recv(socket) → _write(pipe_w)` and `_read(pipe_r) → send(socket)` in both directions. Returns the pipe fd (which msvcrt accepts because pipes are first-class). `fdopen` works normally because the fd really is a pipe.

- **Fixes**: every socket-using applet, including currently-disabled ones and any future ones, transparently.
- **Cost**: ~100–150 lines including bridge thread, fd lifecycle, error/EOF mapping. Win9x pipe semantics need verification. Per-socket: 1 thread + 1 pipe pair.
- **Precedent**: this is how Cygwin handles socket-fd integration internally.

### Strategy B — side-table fd map + `mingw_read`/`write`/`close` extensions + per-applet `fdopen` patches
`mingw_socket` allocates fake-fd from a side-table (e.g. fd ≥ 4096 to avoid msvcrt's range) → SOCKET. Extend `mingw_read`/`mingw_write`/`mingw_close` to detect side-table fds and route to `recv`/`send`/`closesocket`. Then patch every applet that calls `fdopen` on a socket fd (because msvcrt's FILE\* internals call its own `_read`/`_write` directly on the fake-fd, bypassing our wrappers).

- **Fixes**: applet-by-applet — only the ones you patch.
- **Cost**: smaller per-applet diff, but linear in #applets you care about. Doesn't help future enabled-by-default applets without re-auditing.

### Strategy C — patch wget (or whichever) to skip the FILE\* abstraction on Win9x
Replace `fdopen(fd, "r+")` + `fgets`/`fprintf`/`fputs` with direct `mingw_send`/`mingw_recv` in `#ifdef _WIN98_PORT` branches.

- **Fixes**: only the one applet you touch.
- **Cost**: smallest blast radius, biggest in-file churn. wget uses FILE\* in ~16 sites.

**None of these are wrong, but none are < a day of work + multi-round real-hardware testing** (Wine can't validate any of this — see "why we punted" below).

## What HTTPS additionally needs (a second tier)

If you want `wget https://...` to work after fixing HTTP, three more things have to happen:

### 1. Same fd-wrap bug at the wget→ssl_client handoff
[ssl_client.c:60](../src/busybox-w32/networking/ssl_client.c) does the exact same `_open_osfhandle((intptr_t)h, _O_RDWR|_O_BINARY)` on the socket HANDLE that wget passes via `-h`. **Strategy A fixes this transparently; Strategy B/C need a parallel patch.**

### 2. Entropy source for TLS keys
busybox-w32's pure-C TLS implementation (`CONFIG_FEATURE_TLS_INTERNAL=y`, no schannel dep — the cryptography itself is self-contained) gets entropy from `/dev/urandom`, which is intercepted by `mingw_open` → `mingw_popen_special` → `get_random_bytes` → `RtlGenRandom` (advapi32!SystemFunction036). On Win9x:

- Win9x's `advapi32.dll` doesn't export `SystemFunction036`.
- busybox uses **runtime** `GetProcAddress`, not a static link.
- Our [win98-compat](../win98-compat/) shim covers `SystemFunction036` for **static-linked** callers via macro redirection, but it's a `.a` not a `.dll` — GetProcAddress can't find it.
- The probe fails, `get_random_bytes` returns -1, TLS handshake aborts.

Even if we made the probe succeed by lazy-linking against our shim somehow, the GetTickCount-seeded `rand()` fallback the shim uses (and the same fallback in bcrypt-shim's `BCryptGenRandom`) is **catastrophic for TLS**. Session keys derived from a predictable PRNG can be brute-forced in seconds by anyone who observes the encrypted session and knows the connection started within ±60s of some time T (≈10 bits of effective security). For gdb's `std::random_device` this is fine (gdb uses it for hashing breakpoint addresses, not crypto); for TLS it's worse than no encryption because users would *think* they have HTTPS.

### 3. Proper Win9x entropy pool
The only honest answer for TLS keys on Win9x is a Yarrow-style entropy pool mixing weak-but-diverse sources: `RDTSC` cycle counter (Pentium+ — Win98 requires that), `QueryPerformanceCounter`, `GetTickCount`, `GetCurrentProcessId`, uninitialized stack contents, `GetSystemTime`, cursor position, thread timing, etc. PuTTY and old OpenSSL took this approach for their Win9x backends. Probably 200–500 lines of careful, reviewable cryptographic engineering — and the test methodology is the hardest part (you can't measure "secret enough" with normal tools).

**Combined cost**: HTTP-only wget is one tier; HTTPS is a separate, much larger tier. The HTTPS work is real-project-scale (weeks, not days), and the audience that needs Win98 TLS in 2026 is the audience for whom "use a modern machine" is the correct answer.

## Latent footguns — what NOT to enable without revisiting

These applets are currently `# is not set` and there's no PE-check / smoke-test that would catch the bug if you flipped them to `=y`. They share the same broken pattern.

| Applet | Where the bug hides | Refer to |
| --- | --- | --- |
| `ftpd` | `xfdopen_for_read(ls_fd)` at [ftpd.c:746](../src/busybox-w32/networking/ftpd.c) | Strategy A or per-applet B/C |
| `nslookup` | uses `xfdopen_for_read` on socket fds | Same |
| `telnet`, `telnetd` | `fdopen` on socket fd | Same |
| `tftp`, `tftpd` | uses libbb socket helpers | Same |
| `traceroute`, `traceroute6` | raw socket plus some libbb wrap | Audit first |
| `udhcpc`, `udhcpd`, `dnsd` | broadcast socket usage; likely OK on raw fds but unverified | Audit first |

**General audit rule for any new networking applet**: grep for `fdopen` and `xfdopen_for_read`/`xfdopen_for_write` in the source. If those are called on a socket fd (i.e. on the return value of `xconnect_stream`, `xsocket`, or anything that goes through `mingw_socket`), it'll fail on Win98 the moment a user runs it.

The libbb helper [`xfdopen_helper`](../src/busybox-w32/libbb/wfopen.c) is the shared chokepoint — anyone calling `xfdopen_for_read(sock_fd)` or `xfdopen_for_write(sock_fd)` is hitting the same `_open_osfhandle` call.

## Why we punted (the actual reasoning)

Three things lined up to make "disable" the right call rather than "fix":

1. **Audit scope is small but not zero.** Only `wget` and `whois` from the currently-enabled set actually trip the bug. `nc` and `httpd` already work without help (they use direct `read`/`write` on the socket fd, never wrap it as a FILE\*). So disabling the broken applets costs us only the use cases the broken applets covered.

2. **Use case for the broken applets is narrow.** `wget` matters for downloading; `whois` is cosmetic; `ftpget`/`ftpput`/`ftpd` are largely historical. Win98 boxes that need to fetch files in 2026 can use a modern machine to download and copy across the LAN via `httpd` (which works) or a USB drive. The "I need wget on Win98" workflow is real but rare.

3. **HTTPS is the cliff.** Even if we fixed HTTP wget cleanly, the next obvious user expectation is "and also HTTPS" — and the entropy-pool work to make that *honest* is weeks of crypto engineering with an essentially-empty user base. Shipping fake TLS would be unethical; shipping working HTTP but no HTTPS sets up an obvious "why won't `wget https://...` work" support burden. Cleaner to ship no wget at all.

The decision was made 2026-06-21 after rounds of `sockdiag.exe` diagnostics on real Win98 SE. See [`WIN98-MANUAL-CHECKS.md`](../../WIN98-MANUAL-CHECKS.md) for the chronological per-round writeup.

## How to revisit

If you want to take this on later:

1. Run `sockdiag.exe` from the extras toolset on real Win98 to confirm the bug still reproduces (msvcrt behavior could in theory differ across Win98 vs Win98 SE vs WinMe; we've only validated against Win98 SE).
2. Read [`BACKLOG.md`](../../BACKLOG.md) for the Strategy A/B/C trade-off framing.
3. If only doing HTTP: pick a strategy, write a busybox-w32 patch (the patch series under [`repro/patches/busybox-w32/master/`](../patches/busybox-w32/master/) is the model — see `0006`/`0008` for the `is_win9x_proc()` helper this fix can reuse).
4. If doing HTTPS too: the entropy work is the long pole. Read PuTTY's `winnoise.c` and old OpenSSL `rand_win.c` for prior art on Yarrow-style Win9x entropy collection.
5. Re-enable the relevant `CONFIG_*` flags in [`busybox-w32.config`](../configs/busybox-w32.config), add the applet name back to `SHIM_APPLETS` in [`build-bb-shims.sh`](../scripts/build-bb-shims.sh), and update this doc + BACKLOG to reflect the change.

## References

- Diagnostic source: [`repro/diag/sockdiag.c`](../diag/sockdiag.c) (Section 4 = osfhandle probe; Section 5 = raw-SOCKET I/O test)
- Diagnostic log (round 2, conclusive): [`consdiag/SOCKDIAG_2.LOG`](../../consdiag/SOCKDIAG_2.LOG)
- Backlog entry: [`BACKLOG.md`](../../BACKLOG.md) → "busybox-w32 wget: socket fd-wrapping fails on Win9x"
- Manual-checks history: [`WIN98-MANUAL-CHECKS.md`](../../WIN98-MANUAL-CHECKS.md) → "busybox-w32 `socket: invalid argument`" section
- Win9x intuition / "permissive in the wrong ways" pattern: [`AGENTS.md §5.8`](../../AGENTS.md)
- Existing weak-RNG shims (precedent for what's NOT safe to do for TLS): [`repro/bcrypt-shim/bcrypt.c`](../bcrypt-shim/bcrypt.c), [`win98_compat.c::win98_SystemFunction036`](../win98-compat/src/win98_compat.c)
