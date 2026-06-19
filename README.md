# gcc-for-Windows98

## New Changes in [ahrbe1/gcc-for-Windows98](https://github.com/ahrbe1/gcc-for-Windows98)

- Fixes to allow building with docker desktop + git bash on windows (still works on linux hosts)
- Use docker volumes instead of filesystem mounts for faster filesystem operations on windows
- Prefer downloading source release tarballs of packages instead of cloning large repos with git (gcc, binutils-gdb)
- Switch ubuntu mirror to USA (was mainland China)
- Bugfix: `source repro/.env` from within `build.sh` so that persisted settings (`JOBS`, `MATRIX`,
  `BUILD_EXTRAS`) affect the host orchestrator and not just the container; any shell-supplied overrides will still take precedence
- Add a `.dockerignore` so some build artifacts (~hundreds of MB) aren't shipped into the Docker build context
- Create an "extras" tarball with some extra native utilities (built locally by default; CI builds it only on tag pushes):

  - gdb (ships alongside a tiny `bcrypt.dll` shim — see the fix notes below for why)
  - busybox-w32 (shell + coreutils)
  - make
  - universal ctags
  - diffutils
  - patch
  - muon build system (no curl/wrap-file support due to lack of https on win98)

- Ship the native toolset and extras as `.zip` instead of `.tar.xz`.
- Fix an issue where hardlinks were stored in archives, resulting in some 0-byte files when unpacked on win98
- Extend the Win98 PE compatibility checker
  - Add PE import checks against a per-function allow-list generated from a real Win98 SE 4.10.2222B install
  - Add a check against `MajorSubsystemVersion` in addition to the existing `MajorOSVersion` one.
- Inject Win98-host `CPPFLAGS` / `LDFLAGS` into every native build script
  - Add `-D_WIN32_WINNT=0x0400 -DWINVER=0x0400` to gate mingw-w64 feature-detection so that the
  configure step picks Win9x-compatible fallback functions;
  - Add `-Wl,--disable-dynamicbase -Wl,--disable-nxcompat -Wl,--major-subsystem-version=4` to
  strip PE DllCharacteristics that Win98 doesn't recognize
- Add `-static-libgcc -static-libstdc++` to the native binutils-gdb LDFLAGS so `gdbserver.exe`
  doesn't pick up `libgcc_s_dw2-1.dll` and become unloadable on Win98
- Fixed bugs in the PE verifier that were hiding real failures:
  - PE version awk pipes in the checker used `exit` on first match; under the verifier's
  `set -o pipefail`, that delivered `SIGPIPE` to the upstream `printf` and aborted the whole
  verify with exit 141. Removed the early `exit` — each PE field appears once anyway.
  - `pe_check_win98` returning 1 on a fail tripped the verifier's `set -e` before the
  `case` could log the offending binary. Now wrapped with `|| true` in all five callers
  (`verifiers/verify-{native,extras}-package.sh`, `smoke-check-{native,extras}-pe.sh`,
  `smoke-cmake-build.sh`); the verdict is read from `$PE_CHECK_RESULT` either way.
- Stage the native + extras zip on the bind-mounted `/work` filesystem (under `out/package/`)
  so the `cp -al` hardlink-copy doesn't fail with `EXDEV` against the container's `/tmp`
- Patch muon's `fs_is_a_tty_from_fd` to gate its MSYS/mintty pipe-detection block on
  `_WIN32_WINNT >= 0x0600`. The block uses `FILE_NAME_INFO` / `GetFileInformationByHandleEx`,
  which mingw-w64 only exposes for Vista+, so our `_WIN32_WINNT=0x0400` setting hid them
  and the build failed. MSYS/Cygwin can't run on Win98 anyway; the function falls through
  to `GetConsoleMode` for cmd.exe-style ttys.
- Ship a tiny `bcrypt.dll` shim (single export: `BCryptGenRandom`) alongside `gdb.exe`
  in the extras zip. libstdc++ 11's `random_device` statically imports
  `bcrypt!BCryptGenRandom` for seed material; that dependency travels into anything
  linked with libstdc++ (here, `gdb.exe`), and Win98 has no bcrypt.dll. The shim
  delegates to msvcrt's `rand` seeded from `GetTickCount` — non-cryptographic, but
  gdb only uses the entropy as a default seed source. The Win98 PE verifier learned
  a `PE_CHECK_BUNDLED_DLLS` setting so it treats the imported `bcrypt.dll` as
  satisfied by the bundled shim while still checking the shim itself on its own
  merits (msvcrt + kernel32 only).

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

  - `gcc-win98-native-toolset.zip` -- Native Windows 98 compiler
  - `gcc-win98-toolchain.tar.xz` -- Linux cross compiler for Windows 98
  - `gcc-win98-extras.zip` -- Extra build tools added by this fork (see above)

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
