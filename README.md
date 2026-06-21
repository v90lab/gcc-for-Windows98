# gcc-for-Windows98

A port of GCC, GDB, and Muon (meson c99 reimplementation) for Windows 98

## Tools included

- gcc/g++ 11.1.0
- gdb/gdbserver 11.0.50 (devel snapshot)
- busybox-w32 (shell + coreutils)
- make 4.4.1
- universal ctags 6.2.1
- diffutils 3.10
- patch 2.7.6
- muon build system (no wrap-file support due to lack of https on win98)

Packages above that are missing version numbers use the main/master branch from June 2026.

Verified against Windows 98 SE build 2222B (final, fully patched version).

### General build requirements

Pretty much everything happens inside a docker container, so host requirements are minimal.

Verified to work on:

- Windows 11 with Git Bash and Docker Desktop
- Ubuntu 26.04 with Docker and Docker Compose

Necessary tools:

- Docker or Docker Desktop
- Docker Compose
- Bash
- Python 3
- 15GB of disk space

Expect the build to take about 1hr 30min

### Build Instructions

```sh
cd repro
./build.sh
```

`build.sh` is resumable, so if it dies or you kill it, it will roughly pick up where it left off.

For a clean rebuild:

```sh
cd repro
./clean-rebuild.sh
```

### Output Directory

- `repro/out/packages`

  - `gcc-win98-native-toolchain.zip` -- Native Windows 98 compiler
  - `gcc-win98-native-toolchain-extras.zip` -- Extra build tools added by this fork (see above)
  - `gcc-win98-cross-toolchain.tar.xz` -- Linux cross compiler for Windows 98

### Install on Windows 98

1. Copy `gcc-win98-native-toolchain.zip` (and optionally `gcc-win98-native-toolchain-extras.zip`)
   to the Win98 box.
2. Extract them to the drive root with 7-Zip 9.20 (the last 7-Zip release that runs on Win98 SE).
   This gives you `C:\gcc_win98\` and `C:\gcc_win98_extras\`.
3. Edit `C:\AUTOEXEC.BAT` and append:

   ```bat
   PATH=%PATH%;C:\gcc_win98\bin;C:\gcc_win98_extras\bin
   call C:\gcc_win98\setenv.bat
   ```

   The `setenv.bat` line is important — Win98 SE doesn't set `HOME` / `HOMEDRIVE` / `HOMEPATH` /
   `TMP` / `TEMP` by default, and without them gdb prints index-cache warnings and busybox sh /
   vi, make, ctags, muon silently lose `~` expansion, config-file lookup, and command history.
   Both zips ship an identical copy of `setenv.bat`, so calling either one works; only one call
   is needed.
4. Create `C:\Home` as a directory for programs to store their config files in
   (referenced from `setenv.bat`)
5. Reboot (or run `C:\AUTOEXEC.BAT` from a fresh DOS prompt to re-apply).
6. Verify with `C:\gcc_win98\check-versions.bat` — a one-shot `--version` sweep over every
   bundled tool. If a tool errors with a system dialog (bad PE / missing import), something
   was extracted incompletely; a tool that prints its banner is good.

### Install on Linux (cross toolchain)

Extract `gcc-win98-cross-toolchain.tar.xz` somewhere stable (e.g. `/opt`) and prepend its `bin/`
to `PATH`. The toolchain is fully relocatable — no postinstall step needed. The standalone
`pe-win98-check` script lands on `PATH` automatically and lets you sanity-check any Win98 PE
output of your own cross-builds (`pe-win98-check foo.exe`, or `find . -name '*.exe' | xargs
pe-win98-check`).

### Current Status

Early stages / in active development.

The toolchain builds and installs, but expect rough edges. It has not undergone real use yet.

#### Open Bugs

- From inside `busybox sh`, non-applet binaries (`ctags`, `make`, `gdb`, `muon`, `diff`, `patch`) fail with `permission denied` when invoked by bare name; full path (`/opt/extras/bin/ctags.exe`) works. bb-shim applets (`ls`, `cp`, `vi`, ...) are unaffected because they short-circuit through busybox's applet dispatch before reaching the PATH walk.

#### Recent Bugs Fixed

- `busybox sh` hung after every external command
- Backspace printed literal `^[[1D` and `ls --color` printed raw color escape codes to the terminal
- An error `sh: unable to spawn shell` was reported on the first command typed from within the `sh` shell

## Additions, Changes and Fixes in [ahrbe1/gcc-for-Windows98](https://github.com/ahrbe1/gcc-for-Windows98)

- Fixes to allow building with docker desktop + git bash on windows (still works on linux hosts)
- Use docker volumes instead of filesystem mounts for faster filesystem operations on windows
- Prefer downloading source release tarballs of packages instead of cloning large repos with git (gcc, binutils-gdb)
- Switched Ubuntu mirror to USA (was mainland China)
- Bugfix: `source repro/.env` from within `build.sh` so that persisted settings (`JOBS`, `MATRIX`,
  `BUILD_EXTRAS`) affect the host orchestrator and not just the container; any shell-supplied overrides will still take precedence
- Added a `.dockerignore` so some build artifacts (~hundreds of MB) aren't shipped into the Docker build context
- Added an "extras" zip file with some extra native utilities besides just gcc/g++ (see above)
- Changed the output package format for the native toolchain to be `.zip` instead of `.tar.xz`.
- Fixed an issue where hardlinks were stored in archives, resulting in some 0-byte files when unpacked on win98
- Extended the Win98 PE compatibility checker
  - Added per-function PE import checks against an allow-list generated from a real Win98 SE 4.10.2222B install
  - Added a check for `MajorSubsystemVersion` to complement the existing `MajorOSVersion` one
- Injected Win98-friendly `CPPFLAGS` / `LDFLAGS` defaults into every native build script, so
  configure picks Win9x-compatible code paths and the resulting PEs don't carry header flags
  Win98 rejects (ASLR / NX / subsystem >= 5)
  - `-D_WIN32_WINNT=0x0400 -DWINVER=0x0400`
  - `-Wl,--disable-dynamicbase -Wl,--disable-nxcompat -Wl,--major-subsystem-version=4`
- Statically linked `libgcc` / `libstdc++` into native binutils-gdb so `gdbserver.exe` doesn't
  depend on a `libgcc_s_*.dll` that won't load on Win98
- Fixed two bugs that were silently hiding real failures: a stray `exit` in the PE checker
  triggered SIGPIPE under `pipefail`, and a non-zero return from the checker tripped `set -e`
  in the verifier scripts before the offending binary could be logged
- Patched muon's tty-detection to skip its MSYS/mintty checks, which require Windows Vista-era
  Win32 APIs that aren't exposed under the Win98 SDK target.
- Added a tiny `bcrypt.dll` shim needed by `gdb.exe`. `libstdc++` 11's `std::random_device` imports
  `bcrypt!BCryptGenRandom`, which Win98 doesn't have; the shim redirects it to use `rand()` seeded
  from `GetTickCount` (this is not cryptographiclly secure, but gdb only uses it as a default seed).
- Patched gdb's `gdb_select` to add a polling fallback on Win9x hosts. Win98's
  `WaitForMultipleObjects` rejects console input handles as wait objects (an NT-4+ feature), so
  the upstream gdb event loop hits `WAIT_FAILED` on the interactive prompt and spins forever
  printing `select: No Error.`. The patch detects Win9x at startup via `GetVersionEx` and, when
  detected, replaces the `WaitForMultipleObjects` call with a 20-ms polling loop that uses
  `PeekConsoleInput` for console handles and `WaitForSingleObject(timeout=0)` for everything
  else. NT-class hosts still take the original code path.
- Patched busybox-w32's `ash` forkshell mechanism for Win9x. Each command typed at the busybox
  `sh` prompt (`ls`, `cp`, ...) goes through a fork-via-shared-memory trick: parent creates an
  unnamed `CreateFileMapping`, serializes shell state into it, sprintf's the raw HANDLE value
  into argv, spawns busybox-as-sh again with `--fs <hex-handle>`, child does
  `MapViewOfFile((HANDLE)hex)`. Works on NT because handle inheritance preserves the numeric
  value across `CreateProcess`. On Win9x, HANDLE values are per-process — every command failed
  with `sh: unable to spawn shell`. The patch switches to a *named* mapping
  (`busybox-fs-<pid>-<counter>`); the child does `OpenFileMapping(name)` on both kernels.
- Patched busybox-w32's `terminal_mode()` auto-detect for Win9x. The upstream code probes
  `ENABLE_VIRTUAL_TERMINAL_PROCESSING` via `SetConsoleMode` and demotes to Console API
  emulation if the flag is rejected. Win9x's `SetConsoleMode` doesn't validate unknown flag
  bits — it accepts the modern-Windows-only flag silently — so the demotion never fires and
  busybox passes ANSI escapes straight through. `command.com` has no ANSI interpreter, so
  every cursor move shows up literally (e.g. backspace prints `^[[1D` instead of erasing).
  Fix: detect Win9x at startup via `GetVersionEx` and force `mode=0` (Console API
  emulation) before the probe runs.
- Patched busybox-w32's `spawnveq` to backslash-form the executable path before
  `_spawnve`. busybox caches `bb_busybox_exec_path` from `GetModuleFileName` and then runs
  it through `bs_to_slash()` (cosmetic). Win9x's `CreateProcess` rejects forward slashes in
  `lpApplicationName`; NT silently normalizes. Without this fix, the forkshell spawn above
  also fails on Win9x for the unrelated reason that the *path* is wrong-shaped. The
  conversion is always-on (safe on NT too).
- Added a tiny C shim ([`bb-shim`](repro/bb-shim/bb-shim.c)) that substitutes for per-applet
  symlinks on FAT32. busybox's POSIX install creates a symlink per applet (`ls` → `busybox`,
  `cp` → `busybox`, ...) and dispatches via `argv[0]`. FAT32 has no symlinks and no
  hardlinks. The shim is a ~49 KB statically-linked .exe: at startup it derives the applet
  name from its own filename, locates `busybox.exe` in the same directory, and
  `_spawnv P_WAIT`s it with the original arguments shifted right by one. Build once,
  copy-renamed under ~57 common applet names by [`build-bb-shims.sh`](repro/scripts/build-bb-shims.sh)
  — covers the POSIX userland staples (`ls`, `cp`, `mv`, `rm`, `mkdir`, `cat`, `grep`,
  `sed`, `awk`, `find`, `xargs`, `tar`, `gzip`, `md5sum`, `vi`, `less`, `clear`, ...).
  Works from `command.com` and inside `busybox sh` alike — each shim is a real `.exe`, so
  both shells dispatch through normal `CreateProcess`.
- Added a `win98-compat` API shim layer for *functions* that are missing on Win98 but whose host
  DLL still exists (e.g. `kernel32!GetFinalPathNameByHandleA`, `ws2_32!getaddrinfo`,
  `advapi32!SystemFunction036`, `msvcrt!qsort_s`). The shim is a static library + header that
  installs into both the cross and native toolchain sysroots, so it ships in both archives —
  downstream builds (cross-compile from Linux *or* on-Win98 ports with the native compiler)
  pick it up with just `-lwin98compat` (IAT interception; the linker resolves the consumer's
  `dllimport` call sites against the shim's slots, no source changes required). Each shimmed
  function probes the real export via `GetProcAddress` at runtime (full behavior on NT) and
  falls back to a behavior-preserving stub on Win9x.
- Patched mingw-w64's CRT so `ftruncate64` skips its free-space volume-walk path when
  `_WIN32_WINNT < 0x0500` — it was dragging `FindFirstVolumeW` (Win2K+) into `make.exe`.
- Disabled busybox-w32's `drop` / `cdrop` / `pdrop` applets; they need `CheckTokenMembership`,
  which Win98's `ADVAPI32.DLL` doesn't export.
- Added `-D_USE_32BIT_TIME_T` to the `diff` and `busybox` builds so `gmtime` etc. resolve to
  msvcrt's `_gmtime32` instead of the `_gmtime64` family (which Win98's `MSVCRT.DLL` doesn't have).
- Renamed the final output archives for consistency:
  `gcc-win98-toolchain.tar.xz` → `gcc-win98-cross-toolchain.tar.xz`,
  `gcc-win98-native-toolset.zip` → `gcc-win98-native-toolchain.zip`,
  `gcc-win98-extras.zip` → `gcc-win98-native-toolchain-extras.zip`.
  Sibling `.json` manifests follow the same naming.
- The cross toolchain archive now also bundles a standalone copy of the Win98 PE compatibility
  checker (`bin/pe-win98-check` + the allowlist/denylist data files under `share/win98-verify/`).
  Lets downstream cross-compile users run the same `pe-win98-check foo.exe` sanity check we use
  during the build, without having to copy the verifier out of this repo.
- Both the native and extras archives now ship `setenv.bat` and `check-versions.bat` at the
  archive root. `setenv.bat` defensively sets `HOME` / `HOMEDRIVE` / `HOMEPATH` / `TMP` / `TEMP`
  (only when unset) so the bundled tools work as expected on Win98 SE — without it, gdb prints
  index-cache warnings and busybox sh / vi, make, ctags, and muon silently lose `~` expansion,
  config-file lookup, and command history. `check-versions.bat` is a one-shot `--version` smoke
  sweep over every shipped tool. Both files are written in the Win98 SE `command.com` subset
  (single-line `if`, no `setlocal`, no `goto :eof`).

---

## Upstream [LonghronShen/gcc-for-Windows98](https://github.com/LonghronShen/gcc-for-Windows98)

- Reproducible build and containerization
- See [repro/README.md](repro/README.md) for details

---

## Original [fsb4000/gcc-for-Windows98](https://github.com/fsb4000/gcc-for-Windows98):

I managed to build gcc 11.1.0 for Windows 98 :)

std::filesystem doesn't work. Also compiler uses ```thread model: win32``` so no ```std::thread``` and ```std::mutex``` and other stuff.

binutils, gmp, mpfr, mpc: no additional patches needed. :)

mingw-w64:
1) Apply the commit: https://github.com/mirror/mingw-w64/commit/8da1aae7a7ff5bf996878dc8fe30a0e01e210e5a#diff-6ea4503f203d411ce2acce0fa56a61643c1bd33ae96180d9cbff88b7aef5d9a5
2) Revert the commit: https://github.com/mirror/mingw-w64/commit/4d3b28a9929ea58511e7165cb7eb1bcdd01151ad#diff-9618c4c1bea3566e9e27613c3954997a9d44fef1a0dfbfc46227272d82062c2e
3) Apply the commit: https://github.com/mirror/mingw-w64/commit/660e09f3cb20f181b6d6435cb623d65a3922a063
4) Add define _USE_32BIT_TIME_T to configure:
```console
../mingw-w64/configure --disable-nls CFLAGS="-D_USE_32BIT_TIME_T -O3" --target=i686-w64-mingw32  --prefix=/c/Dev/mingw32/i686-w64-mingw32
```

gcc:
1) Revert the commit: https://github.com/gcc-mirror/gcc/commit/1ed3ba0549f544bd9dd5195d7045b20dec0354a3#diff-2e680268e47fa6cc9b09ad5344d37e2cc443b766362a01eb7f73300cd5328fe9
2) Disable LFS: https://github.com/gcc-mirror/gcc/blob/ad0a3be4df5eecc79075d899fd79179d0f61270e/libstdc%2B%2B-v3/config.h.in#L932-L933
3) Disable aligned malloc: https://github.com/gcc-mirror/gcc/blob/16e2427f50c208dfe07d07f18009969502c25dc8/libstdc%2B%2B-v3/config.h.in#L571-L572
4) Disable aligned alloc: https://github.com/gcc-mirror/gcc/blob/ad0a3be4df5eecc79075d899fd79179d0f61270e/libstdc%2B%2B-v3/config.h.in#L9-L10
5) Comment out the line: https://github.com/gcc-mirror/gcc/blob/16e2427f50c208dfe07d07f18009969502c25dc8/libstdc%2B%2B-v3/include/experimental/bits/fs_path.h#L52
6) Comment out the line: https://github.com/gcc-mirror/gcc/blob/16e2427f50c208dfe07d07f18009969502c25dc8/libstdc%2B%2B-v3/include/bits/fs_path.h#L54
7) mingw-w64 mkdir doesn't accept mode:
https://github.com/gcc-mirror/gcc/blob/b7210405ed8eb5fd723b2c99960dcc5f0aec89b4/libstdc%2B%2B-v3/src/c%2B%2B17/fs_ops.cc#L582
and
https://github.com/gcc-mirror/gcc/blob/b7210405ed8eb5fd723b2c99960dcc5f0aec89b4/libstdc%2B%2B-v3/src/filesystem/ops.cc#L482

![gcc](Images/gcc1.png)
![gcc](Images/gcc2.png)
![gcc](Images/gcc3.png)
