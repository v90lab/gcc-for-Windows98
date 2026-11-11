# gcc-win98 consumer kit

Drop this folder into any project to give yourself (or a coding agent) a
turnkey way to compile code with the Windows 98 GCC toolchain. Designed to
be copied wholesale — nothing here references the
[gcc-for-Windows98](https://github.com/ahrbe1/gcc-for-Windows98) repo at
runtime.

## Prerequisite

The Docker image `gcc-win98-consumer:latest` must exist locally. Build it
once by running `./repro/build.sh` in a clone of the gcc-for-Windows98
repo; the image then survives reboots in your local Docker daemon.

Verify with `docker images gcc-win98-consumer`.

## Two integration modes

| Mode | File | When to use |
| ---- | ---- | ----------- |
| One-shot wrapper | `gcc-win98` | Sporadic compiles. `docker run` per call (~700ms cold start). |
| Long-running container | `docker-compose.yml` | Many compiles in a session. `compose exec` per call (~50ms). |

Pick one — they're not exclusive, but you usually only want one per project.

## Wrapper usage

```sh
./gcc-win98                                      # drop into a shell
./gcc-win98 i686-w64-mingw32-gcc hello.c -o hello.exe
./gcc-win98 cmake -S . -B build                  # cross toolchain preset
./gcc-win98 cmake --build build
./gcc-win98 wine ./hello.exe                     # smoke-run a produced .exe
./gcc-win98 pe-win98-check ./hello.exe           # PE compatibility check
```

Drop on your PATH (`cp gcc-win98 ~/bin/`) to call it from anywhere without
the `./`. The wrapper mounts `$PWD` at `/workspace` inside the container,
so all your project files are visible at their normal relative paths.

Env knobs:

- `GCC_WIN98_IMAGE` — override image tag (default `gcc-win98-consumer:latest`).
- `GCC_WIN98_USER_MAP=1` — run as host UID/GID so build artifacts in `$PWD`
  aren't root-owned. **Breaks wine** because `/opt/.wine` is root-owned in
  the image; only set when you don't need to run produced binaries.
- `GCC_WIN98_CCACHE_VOLUME` — ccache Docker volume name (default
  `gcc-win98-consumer-ccache`, shared across projects).
- `GCC_WIN98_DOCKER_ARGS` — extra args spliced into `docker run` (e.g.
  `--network=host`, extra `-v` mounts).

## Compose usage

```sh
docker compose up -d                             # start once per session
docker compose exec consumer bash                # interactive shell
docker compose exec consumer i686-w64-mingw32-gcc hello.c -o hello.exe
docker compose exec consumer wine ./hello.exe
docker compose down                              # stop and remove
```

The compose container also mounts `./:/workspace` and shares the same
`gcc-win98-consumer-ccache` named volume the wrapper uses, so the two modes
get cache hits against each other.

## What's in the container

- **Cross toolchain** at `/opt/cross-toolset` — Linux host, Win98 target,
  triple `i686-w64-mingw32`. On PATH.
- **Native toolchain** at `/opt/native-toolset` — Win98 host, Win98 target.
  The Windows `.exe`s here are runnable via `wine`.
- **Extras** at `/opt/extras` — see inventory below.
- `CMAKE_TOOLCHAIN_FILE=/opt/cmake-toolchain/cross-toolchain.cmake` is set,
  so `cmake -S . -B build` cross-compiles by default.
- Wine is installed for smoke-running produced binaries.
- Workspace bind: your project root is at `/workspace`.

### Extras inventory

Standalone Win98-hosted tools at `/opt/extras/bin/`:

| Binary | What it is |
| ------ | ---------- |
| `busybox.exe`, `sh.exe` | busybox-w32 — ash shell + ~150 enabled applets |
| `make.exe` | GNU make 4.4.1 |
| `gdb.exe`, `gdbserver.exe` | gdb 11.0.50 (devel snapshot from binutils-gdb) |
| `muon.exe` | meson-like build system in C99 (no wrap-file support) |
| `jq.exe` | jq 1.8.2 |
| `tcc.exe` | TinyCC — second, smaller C compiler runnable on Win98 |
| `ctags.exe`, `readtags.exe`, `optscript.exe` | universal-ctags 6.2.1 |
| `diff.exe`, `diff3.exe`, `cmp.exe`, `sdiff.exe` | diffutils 3.10 |
| `patch.exe` | patch 2.7.6 |
| `bcrypt.dll` | ~10-line shim DLL — satisfies gdb's libstdc++ `std::random_device` import (Win98 has no `bcrypt.dll`) |
| `consdiag.exe`, `sockdiag.exe`, `httpdiag.exe` | Win9x diagnostics: stdio/console probes, Winsock socket-creation probes, TCP/HTTP probes |

Plus `bb-shim.exe` and ~112 byte-identical copies of it renamed per applet
(`ls.exe`, `cp.exe`, `grep.exe`, `tar.exe`, `awk.exe`, `sed.exe`, ...) —
FAT32 has no symlinks/hardlinks, so each shim re-execs `busybox.exe` with
the applet name derived from `argv[0]`.

### PE-check and pe-ldd tools

On PATH inside the container (cross toolchain wrappers):

| Command | Purpose |
| ------- | ------- |
| `pe-win98-check` | Verifies a PE binary against the Win98 SE export allowlist + behavioral denylist. Pass/fail per file with the failure reason. |
| `pe-ldd` | `ldd`-like — lists each DLL imported by a PE, marking system DLLs and resolving the rest via App Directory + PATH. |
| `pe-lddtree` | Same as `pe-ldd -r`: recursive with cycle detection. |

The underlying POSIX-sh scripts (runnable on Win98 itself under
`busybox-w32 ash`) live at `/opt/cross-toolset/share/win98-verify/`:
`pe-win98-check.sh`, `pe-ldd.sh`, `win98se-api-allowlist.json`,
`win98-behavioral-denylist.json`. The extras toolset ships a second copy
at `/opt/extras/share/win98-verify/` for use on actual Win98 boxes.

### win98-compat shim library

Static archive `libwin98compat.a` + header `win98_compat.h` in the cross
sysroot — installed at `/opt/cross-toolset/i686-w64-mingw32/{lib,include}/`.
Each wrapper does `GetProcAddress` against the real system DLL at runtime:
full behavior on NT-class hosts, behavior-preserving fallback on Win9x.

Link with:

```sh
i686-w64-mingw32-gcc foo.c \
  -Wl,--whole-archive -lwin98compat -Wl,--no-whole-archive \
  -o foo.exe
```

`--whole-archive` is required: it forces the IAT-slot interception symbols
into the link so calls to e.g. `getaddrinfo` resolve to the shim's
`win98_getaddrinfo` instead of binding to `ws2_32!getaddrinfo` (which Win98
doesn't export). Optionally `#include <win98_compat.h>` to additionally get
source-level macro redirects to the `win98_*` names.

Functions covered:

| DLL bucket | Symbols |
| ---------- | ------- |
| `kernel32` | `GetFinalPathNameByHandleA`, `GetSystemWow64DirectoryA`, `GetLogicalProcessorInformation`, `GetSystemTimePreciseAsFileTime`, `IsWow64Process`, `GetProcessId`, `GetConsoleWindow`, `GetFileSizeEx` |
| `ws2_32` | `getaddrinfo`, `freeaddrinfo`, `getnameinfo` — real `gethostbyname`-backed emulation on Win9x (single IPv4 A-record; honors `AI_PASSIVE` / `AI_NUMERICHOST` / `AI_NUMERICSERV`; `AI_CANONNAME` ignored) |
| `advapi32` | `SystemFunction036` (a.k.a. `RtlGenRandom`) |
| `msvcrt` | `qsort_s`, `_fstat64`, `_mkgmtime32`, `_mkgmtime64` |

Not a kitchen-sink shim: behavior-preserving fallbacks only. Functions
whose Win9x fallback would have to misrepresent their API aren't included
(drop the consumer or patch the call site instead — see the project's
`AGENTS.md` §5.6 for the policy).
