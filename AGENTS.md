# Agents.md — gcc-for-Windows98

Background reference for AI assistants working on this repo. Read this before touching the build pipeline. Verify anything that looks load-bearing against the current code before acting — file paths, step names, and configure flags below were accurate at write time but the source of truth is always the scripts themselves.

## 1. What this repo is

A reproducible Docker-based build that produces a working GCC 11.1.0 toolchain for Windows 98. The upstream feat is from [fsb4000/gcc-for-Windows98](https://github.com/fsb4000/gcc-for-Windows98); this repo wraps the patch recipe in a fully scripted, pinned, containerized build.

It produces **three** archive artifacts plus per-archive manifests and a Docker image:

| Artifact            | Path under `repro/out/package/`                | Host    | Target               |
| ------------------- | ---------------------------------------------- | ------- | -------------------- |
| Cross toolchain     | `gcc-win98-toolchain.tar.xz` + `.json`         | Linux   | `i686-w64-mingw32`   |
| Native toolset      | `gcc-win98-native-toolset.zip` + `.json`       | Win98   | `i686-w64-mingw32`   |
| Extras toolset      | `gcc-win98-extras.zip` + `.json`               | Win98   | (user tools)         |
| Consumer image      | `gcc-win98-consumer:latest`                    | —       | —                    |

The two Win98-hosted archives ship as `.zip` (not `.tar.xz`) so 7zip 9.20 on Win98 SE can extract them in one pass without spilling a ~700 MB scratch tar. zip also has no hardlink/symlink concept, which sidesteps a FAT32 trap: tar archives hardlinks (e.g. `g++.exe → c++.exe`, `ld.exe → ld.bfd.exe`) as metadata-only entries, and FAT32 can't represent them — they materialize as 0-byte stubs and Win98 reports "Error in EXE file" at load time. The cross toolchain stays `.tar.xz` because it's only ever consumed inside the Linux consumer container, where xz is fast.

The **extras archive** bundles Win98-hosted user tools: `busybox.exe`/`sh.exe`, `make.exe`, `ctags.exe`, `diff.exe`/`cmp.exe`, `patch.exe`, `gdb.exe`, `muon.exe`, plus a tiny `bcrypt.dll` shim (see §5.6) that satisfies `gdb.exe`'s libstdc++-via-`std::random_device` import. It's gated behind `BUILD_EXTRAS=1` (default on locally, on for tag pushes in CI, off for branch CI runs) so iterating on the cross/native phases doesn't pay the extras cost every time.

GitHub Actions ([.github/workflows/docker.yml](.github/workflows/docker.yml)) is **manual-dispatch only** — it runs `repro/build.sh` when invoked from the Actions UI and uploads `repro/out/package/*` as workflow artifacts. Tag pushes additionally attach those archives to a GitHub release. No Docker Hub publishing. **The GitHub release is the user's release surface** — shipped archives need to land in `repro/out/package/` as either `.tar.xz` (cross) or `.zip` (native/extras).

## 2. The Win98 constraints you must respect

These constraints are the entire reason this project exists. Anything you add must obey them, or it won't run on Win98 — even if it compiles.

| Constraint              | Why                                                                                       |
| ----------------------- | ----------------------------------------------------------------------------------------- |
| CRT = `msvcrt.dll`      | UCRT requires Windows 10+. mingw-w64 is configured with `--with-default-msvcrt=msvcrt`.   |
| Threading = `pthread9x` | `_GLIBCXX_THREAD_ATEXIT_WIN32` requires Vista+. pthread9x is `JHRobotics/pthread9x`.       |
| `MajorOSVersion ≤ 4`    | Enforced by [`scripts/verifiers/pe-win98-check.sh`](repro/scripts/verifiers/pe-win98-check.sh) on every produced `.exe`. |
| `MajorSubsystemVersion ≤ 4` | Same verifier; some toolchains write `4.0` for the OS field but `5.0` (the binutils default) for the subsystem field. Force with `-Wl,--major-subsystem-version=4` — already in `WIN98_TARGET_LDFLAGS`. |
| No forbidden imports    | Same verifier rejects `*ucrt*`, `api-ms-win-*`, `vcruntime*` plus any DLL not in the Win98 SE export snapshot at [`data/win98se-api-allowlist.json`](repro/data/win98se-api-allowlist.json), and any function not in that DLL's exports. |
| Static link C++         | `-static-libgcc -static-libstdc++` is the convention. Also required on `gdbserver.exe` — without it, the link picks up `libgcc_s_dw2-1.dll` and the binary is unloadable on Win98. |
| Win98-safe CPPFLAGS/LDFLAGS | Every native build script must propagate `$WIN98_TARGET_CPPFLAGS` (`-D_WIN32_WINNT=0x0400 -DWINVER=0x0400`) and `$WIN98_TARGET_LDFLAGS` (`-Wl,--disable-dynamicbase -Wl,--disable-nxcompat -Wl,--major-subsystem-version=4`) into the configure-time env, otherwise mingw-w64 feature-detects Vista+ paths and the PE gets DllCharacteristics Win98 doesn't recognize. |
| Target triple           | `i686-w64-mingw32` (32-bit). No 64-bit anywhere.                                          |

Any new tool's build must end with PE-checking every `.exe` and `.dll` it produces and failing the build if the check fails. The verifier is sourceable — see how [`verify-extras-package.sh`](repro/scripts/verifiers/verify-extras-package.sh) uses it.

**Bundled-DLL escape hatch.** When a binary needs an import the loader will satisfy from a DLL we ship in the same package (App Directory search), set `PE_CHECK_BUNDLED_DLLS="foo.dll bar.dll"` before invoking the verifier — those names skip both the system-allowlist and per-function checks. The bundled DLL itself still goes through the full check on its own merits. Current use: the `bcrypt.dll` shim alongside `gdb.exe` (see §5.7).

**Function-level escape hatch.** When the *DLL* exists on Win98 but a *function* the consumer wants doesn't (e.g. `kernel32!GetFinalPathNameByHandleA`, `ws2_32!getaddrinfo`), the compile-time API shim at [`repro/win98-compat/`](repro/win98-compat/) macro-redirects the call to a `GetProcAddress`-probing wrapper. The shim ships in the cross-toolchain sysroot — see §5.6.

**Behavioral denylist (stub-only exports).** Some functions are present in Win98 SE's export table — so they bind at PE load time — but are NT-era stubs that always return failure on the Win9x kernel. The allowlist accepts them (it reflects the actual export table verbatim, generated from a real Win98 SE install). A second-pass *denylist* at [`repro/data/win98-behavioral-denylist.json`](repro/data/win98-behavioral-denylist.json) names symbols to reject even though the allowlist accepts them; the verifier surfaces those as `Win98 stub-only (binds but non-functional): <dll>:<sym>` with `PE_CHECK_BAD_KIND=denied`. Currently seeded with the 98 NT-security exports in `advapi32.dll` (`Open*Token` / `*SecurityDescriptor` / `*Sid` / `*Acl` / `*SecurityInfo` / `Logon*` / `Lookup*` / `Impersonate*` / etc.). When you ship a binary that trips one of these, the fix is to patch out the call site at the source — convention is to wrap with `#ifdef _WIN98_PORT` short-circuits to the existing failure-path defaults (see busybox-w32 patch 0002 and make patch 0001 for the pattern), then add `-D_WIN98_PORT` to the tool's build script. Don't grow the denylist to whitelist a tool — add a tool patch instead. The denylist file's `description`/`rationale` fields explain when to add a symbol (it must be confirmed-present in `win98se-api-allowlist.json` AND confirmed-non-functional on the Win9x kernel).

## 3. Pipeline shape

### 3.1 Entry points

- [`repro/build.sh`](repro/build.sh) — one-shot host orchestrator. Builds the `toolchain-builder` image, runs the pipeline inside it, then builds the `consumer` image with the artifacts embedded, then runs smoke tests. Sources `repro/.env` so persisted settings (`JOBS`, `MATRIX`, `BUILD_EXTRAS`) affect orchestration; shell-supplied overrides win over `.env`.
- [`repro/scripts/run-toolchain-build.sh`](repro/scripts/run-toolchain-build.sh) — declares three arrays of build steps (`CROSS_STEPS`, `NATIVE_STEPS`, `EXTRAS_STEPS`) and runs each via `builder_script` (a `docker compose exec` wrapper from [`scripts/lib/common.sh`](repro/scripts/lib/common.sh)). **This is where you add new build phases.** Extras phase is gated on `BUILD_EXTRAS=1`.
- [`repro/scripts/run-smoke-pipeline.sh`](repro/scripts/run-smoke-pipeline.sh) — runs validation phases in the `consumer` container.

### 3.2 Containers

Both defined in [`repro/docker-compose.yml`](repro/docker-compose.yml):

- **toolchain-builder** ([`docker/toolchain-builder.Dockerfile`](repro/docker/toolchain-builder.Dockerfile)) — Ubuntu 22.04 with build tooling. `/work/build` and `/work/src` are on named Docker volumes (`gcc-win98-build`, `gcc-win98-src`) — keeps heavy I/O off the Windows host's 9p layer. Wine + Xvfb live here too for in-build smoke checks. Note: Ubuntu's apt meson (0.61) is too old for muon; we `pip3 install meson` on top, lands at `/usr/local/bin` ahead of `/usr/bin`.
- **consumer** ([`docker/consumer.Dockerfile`](repro/docker/consumer.Dockerfile)) — multi-stage; the `extractor` stage unpacks all three tarballs into `/opt/cross-toolset`, `/opt/native-toolset`, `/opt/extras`. Ships Wine + Xvfb for smoke tests.

### 3.3 Build phases (canonical order)

1. **Cross** (Linux→Win98): fetch → patch → cross-binutils → cross-mingw-w64 → cross-gcc-stage1 → cross-pthread9x → cross-gcc-final → verify → **win98-compat shim** → package → manifest. (The win98-compat shim installs `libwin98compat.a` + `win98_compat.h` into the cross sysroot at `out/toolchain/i686-w64-mingw32/{lib,include}` so the package step rolls it into the cross tarball.)
2. **Native** (Canadian Cross, Win98→Win98): build-native-mingw-deps (gmp/mpfr/mpc for the host) → build-native-mingw-w64 → build-native-host-gcc → build-native-binutils → build-native-pthread9x → verify → package → manifest.
3. **Extras** (Win98-hosted user tools — gated on `BUILD_EXTRAS=1`): busybox → ctags → make → diffutils → patch → gdb → muon → bcrypt-shim → verify → package → manifest. Order is cheapest-first so failures surface early; the bcrypt shim sits between muon and verify because the shim install goes into `out/extras-toolset/bin/` and must be present before verify scans.
4. **Smoke**: layout check, PE check on native + extras binaries, CMake+Ninja builds of `tests/` under both toolchains, all run/checked under Wine.

### 3.4 Conventions

- **Naming**: `build-cross-*.sh` vs `build-native-*.sh`. New native tools (cross/native or extras) should be `build-native-<tool>.sh`.
- **Step sentinels**: every script ends with `mark_done <step-name>`; later scripts gate on `require_step <step-name>`. Files live at `out/.status-<STATUS_SCOPE>-<step>` where `STATUS_SCOPE` defaults to `${TARGET}__m${MATRIX}` (prevents resume from skipping into a different config). Names must match between scripts and the `*_STEPS` arrays.
- **Common library**: source [`lib/common.sh`](repro/scripts/lib/common.sh) at the top of every script. It provides `log`, `die`, `run_logged`, `mark_done`, `is_done`, `skip_if_done`, `require_step`, `require_dir`, `require_file`, `require_executable`, `builder_exec`, `builder_script`, `fetch_component`, and the dir vars `ROOT_DIR`, `SRC_DIR`, `BUILD_DIR`, `LOG_DIR`, `OUT_DIR`, `PATCH_DIR`, `PREFIX`, `TARGET`, `JOBS`. Plus two Win98-flag pairs you propagate into every native build's configure/Make: `WIN98_TARGET_CPPFLAGS`/`WIN98_TARGET_LDFLAGS` (header gates + PE DllCharacteristics — always required) and `WIN98_COMPAT_CPPFLAGS`/`WIN98_COMPAT_LDFLAGS` (force-include the win98-compat shim header + link `-lwin98compat` — required for any binary whose source references a function in the §5.6 coverage list).
- **Logging**: `run_logged <log-name>.log <cmd...>` tees to `logs/`. Every step has its own log.
- **Sources fetched via [`config.json`](repro/config.json)**: pinned commits (and SHA-checksummed tarballs where available). Add new components by extending the matrix entry, updating the `MAPPING` in [`config_matrix_exports.py`](repro/scripts/lib/config_matrix_exports.py), adding `*_FETCH_*`/`*_TARBALL_*`/`*_COMPONENT_VERSION` placeholders to [`common.sh`](repro/scripts/lib/common.sh), and calling `fetch_component` in [`fetch-sources.sh`](repro/scripts/fetch-sources.sh). Also add to the `retry-clean.sh` sweep list.
- **Prefer release tarballs over git** when both are available. `fetch_component` takes both — if `tarball.url` is set in config.json, it's used and the git source is metadata only. Tarballs are faster to extract (no per-file checkout) and ship pre-generated `configure` so we sidestep `./bootstrap` / `autoreconf` dependency drift.
- **Canadian Cross compiler hygiene**: when building native (Win98-hosted) tools, prepend `$REPO_ROOT/out/toolchain/bin` to `PATH` and pass `--host=i686-w64-mingw32`. The simpler `build-native-*` scripts (make, diffutils, ctags) are good templates.
- **Packaging**: the cross tarball is made with `XZ_OPT=-1 tar -cJf` (low compression — large file, trades disk for time). The native + extras zips are made with `zip -9 -r` from a `cp -al`-staged tree under the renamed top-level (`gcc_win98/` or `gcc_win98_extras/`); the staging step is what lets us rename the prefix without zip's missing `--transform` equivalent. The stage dir MUST be on the same filesystem as the source (we use `mktemp -d -p "$PACKAGE_DIR" ...`, NOT the default `/tmp`) — `cp -al` fails with `EXDEV` across devices, and in the toolchain-builder container `/work` is a bind-mount while `/tmp` is the overlay FS. All three archives land in `out/package/`.

### 3.5 Patch system

- [`repro/patches/`](repro/patches/) holds per-component patch series. `apply-patches.sh` applies `series.txt` in order with `git apply`.
- New patched components need: `patches/<name>/<version>/series.txt` + `*.patch` files, **plus** a `patch.py` `PatchSet` subclass if you want regeneration support via `generate-patches.py`. Hand-rolled patches without the generator class work fine — generator support is a nice-to-have.
- For one-off mingw header gaps in a single component, an inline build-script CPPFLAGS or stub-include approach (see §5 patch / muon) is usually less overhead than a full patch series.

## 4. Extras tools — what's there and how they're built

Each tool has a `build-native-<tool>.sh` script following the standard structure (skip_if_done → require_* → configure → build → install → mark_done). Specific gotchas per tool below.

| Tool       | Source                                | Notes                                                                                                                  |
| ---------- | ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| busybox-w32 | github.com/rmyorston/busybox-w32     | Kconfig + Makefile (not autoconf). Checked-in `repro/configs/busybox-w32.config` is the Kconfig snapshot. Produces `busybox.exe` + symlinked `sh.exe`. |
| make       | GNU make 4.4.1 release tarball       | Tarball ships pre-built `configure` + bundled gnulib m4. Git source needs `./bootstrap`; tarball avoids that headache.   |
| ctags      | universal-ctags git                  | Needs `WINDRES="${TARGET}-windres"` passed to configure or it bare-invokes `windres` and fails.                        |
| diffutils  | 3.10 release tarball                 | Bundled gnulib needs mingw signal-symbol stubs in CPPFLAGS (`-DSA_RESTART=0 -DSIGHUP=1 -DSIGPIPE=13 -DSIGSTOP=17`).      |
| patch      | 2.7.6 release tarball                | Heaviest mingw porting load. Uses a stub include dir (`<sys/resource.h>` + a force-included `compat-mingw.h`) — see §5. |
| gdb        | rides on `binutils-gdb` source tree  | `--enable-gdb --disable-binutils --disable-gas --disable-ld --disable-sim --disable-gprof`; uses `--with-libgmp-prefix` (NOT `--with-gmp`); needs `-Wl,--allow-multiple-definition` to resolve pthread9x ↔ mingw-w64 CRT `strtoull` collision. CLI + bundled-readline, no curses, no TUI. |
| muon       | github.com/muon-build/muon git       | Built via upstream meson + ninja (not muon's bootstrap — the bootstrap CLI doesn't accept `--cross-file`). Cross-file lives at `$BUILD_DIR/mingw32.cross.ini`. Options: `-Dstatic=true -Dsamurai=enabled -Dreadline=builtin -Dnative_backtrace=disabled` plus disables for libcurl/libarchive/libpkgconf/tracy/man-pages/meson-docs/meson-tests/website (= no wrap-file support, no docs). Build script idempotently in-place edits `src/platform/windows/filesystem.c` to wrap the MSYS/mintty pipe-detection block in `#if _WIN32_WINNT >= 0x0600` — its `FILE_NAME_INFO` / `GetFileInformationByHandleEx` are Vista+ and our `_WIN32_WINNT=0x0400` hides them. (The earlier os.c `os_ncpus`/`GetLogicalProcessorInformation` patch is gone — the win98-compat shim covers it now; see §5.6.) Vista+ playbook in §5.8. |
| bcrypt-shim | [`repro/bcrypt-shim/bcrypt.c`](repro/bcrypt-shim/bcrypt.c) (in-tree) | Tiny `bcrypt.dll` with a single export — `BCryptGenRandom` — that satisfies the libstdc++ `std::random_device` dependency baked into `gdb.exe`. Cross-compiled with `--kill-at` so the export is undecorated. Built by [`build-bcrypt-shim.sh`](repro/scripts/build-bcrypt-shim.sh), installed to `out/extras-toolset/bin/bcrypt.dll`. Verifier sees the import via `PE_CHECK_BUNDLED_DLLS=bcrypt.dll`. See §5.7. |
| win98-compat | [`repro/win98-compat/`](repro/win98-compat/) (in-tree)              | Project-wide compile-time API shim. Static archive (`libwin98compat.a`) + header (`win98_compat.h`) installed into the cross-toolchain sysroot at build time; the header force-includes via `-include` and macro-redirects ~13 missing Win9x functions across kernel32/ws2_32/advapi32/msvcrt to `GetProcAddress`-probing wrappers with behavior-preserving fallbacks. Wired into CROSS_STEPS before `package` so the cross tarball ships it for downstream porting. See §5.6 for the full pattern. |

## 5. Porting playbook — patterns and gotchas

These came out of porting the extras tools. Pattern-match these against new tools before reinventing.

### 5.1 mingw header gaps

mingw-w64 lacks POSIX symbols Windows has no analog for. The cheapest fix for each:

- **`SA_RESTART`, `SIGHUP`, `SIGPIPE`, `SIGSTOP`, `SIGQUIT`, `SIG_BLOCK`, `SIG_UNBLOCK`, `SIG_SETMASK`**: stuff defaults via CPPFLAGS (`-DSIGHUP=1 -DSIGPIPE=13` etc — pick unused-on-Windows signal numbers). At runtime `signal()` returns `SIG_ERR` for these, the handler doesn't install, and since the signal can't fire on Windows it's a no-op.
- **`<sys/resource.h>`**: ship a stub header on the include path. See `build-native-patch.sh` for the pattern — a build-script heredoc writes `mingw-stubs/sys/resource.h` with typedef `rlim_t`, `struct rlimit`, and macros for `getrlimit`/`setrlimit` that return success with placeholder limits.
- **`getuid`, `getgid`, `geteuid`, `getegid`**: macro them to `(0)` via a force-included compat header — Windows has no POSIX users; everything runs as if root. Combined with the resource stub, force-include via `-include $BUILD_DIR/mingw-stubs/compat-mingw.h`.
- **`<regex.h>` (POSIX C regex)**: mingw has no POSIX regex (only C++ `<regex>`). Either link gnulib-regex, link libgnurx, or drop the tool. cscope was dropped for this plus curses.

### 5.2 Multi-package builds (binutils-gdb, gcc)

The top-level binutils-gdb `configure` passes `--disable-option-checking` to sub-configures. This silently swallows unknown flags — you'll think your `-Dfoo=bar` is taking effect when it isn't. Always check the sub-configure's `--help` for the exact flag name. Caught this with gdb 11's `--with-libgmp-prefix` vs the misleading-looking `--with-gmp` (the latter is a top-level mingw-deps flag, not gdb's).

The gdb in the `binutils-2_36_1` tree is **gdb 11.0.50-dev**, not gdb 10.1 — gdb's release cadence is independent of binutils.

### 5.3 Symbol collisions

Linking against pthread9x AND mingw-w64's `libmsvcrt.a` can collide on symbols both provide as Windows-old-CRT fallbacks. We hit this with `strtoull` (pthread9x's `int64.c` and mingw's `lib32_libmsvcrt_extra` both supply it). Fix: `-Wl,--allow-multiple-definition` in `LDFLAGS`. The two impls are interchangeable; first-on-the-link-line wins.

Pure-C extras tools didn't trip this because they don't pull in `-lpthread`. C++ tools (gdb) do because libstdc++ drags it in for thread support.

### 5.4 Cross-compile with meson

For meson-based projects, the bootstrap-the-build-system path is often a dead end (e.g. muon's bootstrap CLI is too minimal for cross-files). Just use Python meson + ninja from the builder:

1. Write a `mingw32.cross.ini` with `[binaries]` pointing at `$CROSS_BIN_DIR/${TARGET}-*` and `[host_machine]` declaring `system='windows', cpu='i686'`.
2. Set `[properties]` `needs_exe_wrapper = true` so meson doesn't try to run cross-built executables on the host. If the project needs to run produced helpers mid-build, add `exe_wrapper = 'wine'` instead.
3. `meson setup --cross-file=... build-dir source-dir`; `ninja -C build-dir`; manually copy artifacts to install dir (meson's install path will try to invoke the cross-built binaries).

### 5.5 Configure quirks worth knowing

- `--disable-dependency-tracking` cuts a lot of useless work in cross-builds — every autoconf-based extras script uses it.
- `MAKEINFO=true` skips info-page generation (we ship none); pass it to `make` for autoconf tools that try to rebuild texinfo docs.
- `--disable-gcc-warnings` on gnulib-using projects (diffutils, patch) saves time and noise — gnulib's `-Werror` defaults are aggressive.

### 5.6 Compile-time API shim (win98-compat)

For *missing functions* on *present DLLs* — the case where Win98's `KERNEL32.DLL` (or `ADVAPI32`, `WS2_32`, `MSVCRT`) exists but doesn't export some entry point the compiler bound as a static PE import — there's a project-wide static-archive shim at [`repro/win98-compat/`](repro/win98-compat/). It installs `libwin98compat.a` + `<win98_compat.h>` into the cross-toolchain sysroot, and gets force-included into every Win98-hosted native build via `WIN98_COMPAT_CPPFLAGS="-include win98_compat.h"` + `WIN98_COMPAT_LDFLAGS="-lwin98compat"` (defined in `lib/common.sh`). Because the install location is the sysroot, the cross-toolchain tarball ships it for downstream porting too — anyone using the cross gcc can `-include win98_compat.h` / `-lwin98compat` without extra path plumbing.

How the header threads the needle:

1. It pulls in `<winsock2.h>`, `<ws2tcpip.h>`, `<windows.h>` FIRST so the real system prototypes (`getaddrinfo` decorated with `__declspec(dllimport)`, etc.) land normally — those still need to resolve via the IAT when an unshimmed binary uses them.
2. Then it forward-declares `win98_<api>` wrappers WITHOUT `dllimport` — these are normal static-archive symbols that live in `libwin98compat.a`.
3. Then it installs `#define <api> win98_<api>` macros. Because the system headers are already preprocessed, the macros affect only consumer-source-level calls; they do NOT propagate back into the system-header declarations. Without step 1 first, the macros would rewrite the system declaration text and the resulting `win98_*` symbol would inherit `dllimport`, sending the linker hunting for `_imp__win98_*` (this was the v1 bug).

Each wrapper does `GetProcAddress` against the real system DLL at runtime: full behavior on NT-class hosts, behavior-preserving fallback on Win9x (sensible failure return / synthesized data — see [`repro/win98-compat/src/win98_compat.c`](repro/win98-compat/src/win98_compat.c) for what each fallback does).

Current coverage:

- **kernel32**: GetFinalPathNameByHandleA, GetSystemWow64DirectoryA, GetLogicalProcessorInformation, GetSystemTimePreciseAsFileTime, IsWow64Process, GetProcessId, GetConsoleWindow, GetFileSizeEx.
- **ws2_32**: getaddrinfo, freeaddrinfo, getnameinfo.
- **advapi32**: SystemFunction036 (RtlGenRandom).
- **msvcrt**: qsort_s.

When to add a function:

1. **Confirm** it's a real binding in a shipped binary via `objdump -p`. Vista+ symbols the compiler tries-and-dead-strips don't need shimming.
2. **Add** a `#define` in [`win98_compat.h`](repro/win98-compat/include/win98_compat.h) and a probe-then-fallback impl in [`win98_compat.c`](repro/win98-compat/src/win98_compat.c). Add it to the `EXPECTED_SYMBOLS` spot-check in [`build-win98-compat.sh`](repro/scripts/build-win98-compat.sh) if it's a new DLL bucket.
3. **Don't** add a function whose fallback would have to misrepresent its API (returning fake results that break callers downstream). Drop the consumer or patch out the specific call site instead.

When NOT to use this pattern (use a bundled-DLL drop-in §5.7 instead):

- The whole DLL is missing on Win98 (`bcrypt.dll`, `libcurl.dll`, etc.). A static archive can't satisfy the loader's DLL-existence check.
- The consumer dynamically `LoadLibrary`s a missing DLL by name. Same reason.

### 5.7 Bundled-DLL shims for unresolvable static imports

When the compiler bakes a static PE import of a DLL that doesn't exist on Win98 — and the import is too deep in a third-party library to patch out — ship a tiny shim DLL with the same name + exports next to the consuming `.exe`. Win98's App Directory search resolves DLLs by name from the binary's own directory before walking system paths, so a same-name shim wins.

The bcrypt shim is the canonical example: libstdc++ 11's `std::random_device` statically imports `bcrypt!BCryptGenRandom`, that dependency travels into anything linked `-static-libstdc++` (here, `gdb.exe`), and Win98 has no `bcrypt.dll`. The shim is ~10 lines of C ([`repro/bcrypt-shim/bcrypt.c`](repro/bcrypt-shim/bcrypt.c)) implementing only the function gdb actually imports, delegating to msvcrt's `rand` seeded from `GetTickCount` (non-cryptographic — acceptable because gdb only uses the entropy as a seed source, not for keys).

The recipe:

1. **Confirm scope** with `objdump -p <exe> | awk '/DLL Name: <shim>.dll/,/DLL Name:/'` — list every function the consumer actually imports. Only stub those; resist adding plausible-looking siblings.
2. **Cross-build with `--kill-at`** so stdcall exports come out undecorated (libstdc++ imports `BCryptGenRandom`, not `BCryptGenRandom@16`). Also pass `WIN98_TARGET_CPPFLAGS` / `WIN98_TARGET_LDFLAGS` so the shim itself is Win98-safe.
3. **Self-verify** the shim DLL through `pe_check_win98` in its build script before installing — catches a shim that accidentally pulls in a Vista+ API of its own.
4. **Install to `out/<toolset>/bin/`** alongside the consumer, NOT to a separate directory. Win98's App Directory search needs them adjacent.
5. **Declare to the verifier**: `export PE_CHECK_BUNDLED_DLLS="<shim>.dll"` before the verify scan. The verifier still applies the full PE check to the shim itself; it just lets the consumer's import resolve. Set this in *every* verifier that scans the toolset (currently [`verify-extras-package.sh`](repro/scripts/verifiers/verify-extras-package.sh) and [`smoke-check-extras-pe.sh`](repro/scripts/smoke-check-extras-pe.sh)).
6. **Wire as its own EXTRAS_STEP** between the consumer's build and the package-verify step. Don't fold it into the consumer's build script — the shim should be independently re-buildable.

If you find yourself wanting to add a second function to an existing shim, stop and ask whether the underlying tool needs to be there at all. The shim should stay ~10 lines; growth signals that the actual dependency is heavier than this pattern was designed for, and a libstdc++ / source patch may be cleaner.

### 5.8 Vista+ APIs in third-party source

The Win98 `_WIN32_WINNT=0x0400` setting hides any mingw-w64 declaration gated behind a higher target. Third-party projects that feature-detect at compile time (rather than via configure-time probes) hit this as `unknown type name` / `implicit declaration` errors on Vista-era APIs like `FILE_NAME_INFO`, `GetFileInformationByHandleEx`, `BCryptGenRandom`, `RtlGenRandom`.

Pick by who's calling and why:

- **The caller is dead code on Win98** (e.g. muon's MSYS/mintty pty detection — Cygwin/MSYS can't run on Win98) → inline-patch the source from the build script to wrap the block in `#if _WIN32_WINNT >= 0x0600 ... #endif`. Make the patch idempotent (check for an inserted marker comment before applying). See `build-native-muon.sh` for the pattern — a python heredoc with brace-matching.
- **The caller is live and the missing symbol is a function on a DLL Win98 does have** (e.g. `kernel32!GetFinalPathNameByHandleA`) → use the compile-time API shim (§5.6). Add the function to its coverage and you're done — no per-tool patch.
- **The caller is live and the missing symbol is the whole DLL** (e.g. `bcrypt.dll`, `libcurl.dll`) → bundled-DLL drop-in (§5.7).
- **The caller is live and there's no honest fallback** (crypto primitives the tool genuinely uses, etc.) → disable the codepath via configure, drop the tool, or fork the source. Don't ship a fake.
- **The caller is in mingw-w64's own CRT** (e.g. `libmingwex.a::ftruncate64.o` pulling in `FindFirstVolumeW` for a disk-space check). That's a source-level patch against our mingw-w64 source tree — see `repro/patches/mingw-w64/master/0002-ftruncate64-skip-volume-walk-pre-win2k.patch` for an example that gates the offending block on `_WIN32_WINNT >= 0x0500`.

### 5.9 PE verifier `set -e` interaction

`pe_check_win98` returns 1 on a Win98-incompatible binary as a normal status code, not an error — the caller reads `$PE_CHECK_RESULT` for the verdict and `$PE_CHECK_FAIL_REASON` for the why. But the verifier scripts run under `set -e`, which treats rc=1 as fatal and kills the loop before the `case` runs — masking the actual failure with a silent exit 1. Every caller MUST wrap the call: `pe_check_win98 "$f" || true`. There are currently five callers, all fixed; mirror the pattern in any new verifier.

Same trap, different cause: awk `exit` inside a `printf '%s\n' "$dump" | awk ...` pipeline closes the pipe early. Under `set -o pipefail` the upstream `printf` gets `SIGPIPE` and the assignment fails with rc=141, killing the whole verify. Don't use `exit` inside awk pipelines on small inputs — let awk read to EOF.

Third trap, very different cause: the per-function check parses `objdump -p` output, and the column count of that output **varies by binutils version**. There are two layouts in the wild:

- **3-col** (`vma  Hint/Ord  Member-Name  Bound-To`) — what the toolchain-builder container's Ubuntu 22.04 binutils 2.38 emits. Example row: `\t999fe\t 1373  GetTokenInformation`.
- **4-col** (`vma  Ordinal  Hint  Member-Name  Bound-To`) — what newer binutils emit (e.g. mingw-w64 host objdump). Example row: `\t0009952c  <none>  055d  GetTokenInformation`.

A regex anchored on the wrong count silently matches zero rows — the verifier reports green while the per-function check is effectively a no-op. [`pe-win98-check.sh`](repro/scripts/verifiers/pe-win98-check.sh) now tries the 4-col regex first and falls back to the 3-col regex, so it auto-detects which layout is in front of it — but bumping the base image again could introduce a third layout (5-col Bound-To populated, etc.). If you bump binutils or notice the function-allowlist check passing on a binary you *know* has a forbidden import, generate a fresh `objdump -p` against the active toolchain and confirm at least one of the two patterns still matches a real import row.

Heads-up for cross-environment debugging: running `objdump -p` from the **host** (mingw64 binutils) and from the **toolchain-builder container** (Ubuntu binutils 2.38) on the same `.exe` produces *different layouts*. If you reproduce a verifier issue interactively, run inside the container (`docker compose exec -T toolchain-builder bash -c '...'`) to match what CI sees — otherwise you may convince yourself the regex is broken when it's actually only broken for one side. Both regex layouts are exercised in [`pe-win98-check.sh`](repro/scripts/verifiers/pe-win98-check.sh)'s import-row block and either one matching is sufficient.

(History: this trap has shipped a regression *in both directions* — once when the regex was anchored to a phantom 4th column that never appeared in container output, and once when it was tightened from 4-col back to 3-col after a host-environment debugging session falsely concluded the 4-col layout was wrong. Auto-detect ends the ping-pong.)

## 6. Things to avoid

- **Don't introduce UCRT anywhere.** Any new component's configure must select msvcrt (`--with-default-msvcrt=msvcrt` for mingw-w64 sub-builds; for tools, link against `-lmsvcrt` if it matters).
- **Don't enable threads/features that require Vista+ APIs.** When in doubt, the PE verifier will catch it — but it's a slow feedback loop.
- **Don't use the Ubuntu `gcc-mingw-w64-i686-win32` package as the final compiler for anything shipped.** It's GCC 10 and uses Vista+ thread-atexit. Always prepend `out/toolchain/bin` to `PATH`.
- **Don't lose reproducibility.** New components need pinned commits in `config.json`; don't fetch tarballs with floating URLs. When pinning a git source after a successful build, capture the resolved SHA with `git -C /work/src/<name> rev-parse HEAD` and paste it into the `commit` field.
- **Don't skip the PE check.** Every shipped `.exe`/`.dll` must pass `pe_check_win98`. The extras verifier ([`verifiers/verify-extras-package.sh`](repro/scripts/verifiers/verify-extras-package.sh)) handles this for the extras package; mirror the pattern for new families.
- **Don't `--no-verify`, `--force`, `--amend`, or `rm -rf` anything load-bearing without asking.** The build is long and resumable — preserve in-flight state.

## 7. Useful runtime facts

- **Build environment**: Windows 11 host (PowerShell + Git Bash), but the build itself runs in Linux containers via Docker Compose. Use the Bash tool for repo work — scripts under `repro/` are bash and the dev loop is `docker compose exec`.
- **Resumability**: status sentinels under `out/.status-*` make the pipeline resumable. `./build.sh` (or `./scripts/run-toolchain-build.sh --resume`) picks up where it left off. To force a step to re-run, delete its sentinel: `rm /work/out/.status-*-<step-name>`. To force re-fetch of one tool's source, also delete `src/<tool>/.tarball-extracted` (for tarball components) or `rm -rf src/<tool>` (for git components).
- **Resume vs sentinel invalidation**: `--resume` skips steps before the resume point regardless of sentinel state — so if you need an earlier step to re-run, *don't* use `--resume`; just nuke its sentinel and let the runner walk the full list (it'll skip done-steps via `is_done_in_builder` and run the un-done ones).
- **MSYS path conversion** (Git Bash on Windows): `docker compose exec` rewrites `/work/...` to `C:/git-sdk-64/work/...` before passing to the container. `in_container_path()` in common.sh prepends a leading `/` (so `//work/...`) which MSYS leaves alone; in-container bash collapses double-slash per POSIX. Every `builder_*` / `consumer_*` helper goes through this.
- **Status reporters** live in [`scripts/utils/`](repro/scripts/utils/) — `project-status.sh` aggregates the lot, including the extras phase via `extras-toolset-status.sh`.
- **Logs** are in [`repro/logs/`](repro/logs/), timestamped per step.
- **Paths from PowerShell** are `u:\home\brian\github\gcc-for-Windows98\...`. Bash tool sees them as `u:/home/brian/github/gcc-for-Windows98/...`.

## 8. Quick file map

| Path | Purpose |
| ---- | ------- |
| [`repro/build.sh`](repro/build.sh) | One-shot host entry point; sources `.env`, drives the three phases |
| [`repro/config.json`](repro/config.json) | Pinned source revisions for every component |
| [`repro/docker-compose.yml`](repro/docker-compose.yml) | Two-service container layout; named volumes for `/work/build` and `/work/src` |
| [`repro/docker/toolchain-builder.Dockerfile`](repro/docker/toolchain-builder.Dockerfile) | Build environment (apt + pip3 meson) |
| [`repro/docker/consumer.Dockerfile`](repro/docker/consumer.Dockerfile) | Smoke-test environment (unpacks all three tarballs) |
| [`repro/scripts/run-toolchain-build.sh`](repro/scripts/run-toolchain-build.sh) | Master build orchestrator; `CROSS_STEPS`/`NATIVE_STEPS`/`EXTRAS_STEPS` arrays live here |
| [`repro/scripts/lib/common.sh`](repro/scripts/lib/common.sh) | Shared bash library (source this in every script) |
| [`repro/scripts/lib/config_matrix_exports.py`](repro/scripts/lib/config_matrix_exports.py) | Translates `config.json` matrix into shell `export` lines |
| [`repro/scripts/fetch-sources.sh`](repro/scripts/fetch-sources.sh) | One `fetch_component` call per component |
| [`repro/scripts/retry-clean.sh`](repro/scripts/retry-clean.sh) | `--retry` source-reset sweep (git reset / clean per component) |
| [`repro/scripts/build-cross-*.sh`](repro/scripts/) | Cross-toolchain build steps |
| [`repro/scripts/build-native-*.sh`](repro/scripts/) | Native-host + extras build steps |
| [`repro/scripts/build-bcrypt-shim.sh`](repro/scripts/build-bcrypt-shim.sh) | Cross-compiles the in-tree bcrypt.dll shim into `out/extras-toolset/bin/` |
| [`repro/bcrypt-shim/bcrypt.c`](repro/bcrypt-shim/bcrypt.c) | bcrypt.dll shim source — single export `BCryptGenRandom` for gdb's libstdc++ random_device |
| [`repro/scripts/build-win98-compat.sh`](repro/scripts/build-win98-compat.sh) | Cross-compiles the in-tree win98-compat static archive into `out/toolchain/i686-w64-mingw32/{lib,include}/` |
| [`repro/win98-compat/include/win98_compat.h`](repro/win98-compat/include/win98_compat.h) | Public header — system-header preload, win98_* forward decls, macro redirects (see §5.6 for the ordering rules) |
| [`repro/win98-compat/src/win98_compat.c`](repro/win98-compat/src/win98_compat.c) | Implementations — one `GetProcAddress`-probe-and-fallback per shimmed symbol |
| [`repro/patches/mingw-w64/master/0002-ftruncate64-skip-volume-walk-pre-win2k.patch`](repro/patches/mingw-w64/master/0002-ftruncate64-skip-volume-walk-pre-win2k.patch) | Example mingw-w64 CRT patch: gates `ftruncate64`'s `checkfreespace` volume walk on `_WIN32_WINNT >= 0x0500` so `FindFirstVolumeW` doesn't get statically imported into binaries that call `ftruncate` (it was tripping `make.exe`) |
| [`repro/scripts/package-extras-toolset.sh`](repro/scripts/package-extras-toolset.sh) | Zips `out/extras-toolset/` → `out/package/gcc-win98-extras.zip` (stage dir under `out/package/` to avoid EXDEV) |
| [`repro/scripts/verifiers/pe-win98-check.sh`](repro/scripts/verifiers/pe-win98-check.sh) | PE verifier — sourceable, used by every package-verify script. Honors `PE_CHECK_BUNDLED_DLLS` and `PE_CHECK_ALLOWLIST` env vars |
| [`repro/data/win98se-api-allowlist.json`](repro/data/win98se-api-allowlist.json) | Win98 SE system DLL + per-DLL export-table snapshot driving the verifier's allowlist |
| [`repro/scripts/verifiers/verify-extras-package.sh`](repro/scripts/verifiers/verify-extras-package.sh) | Extras-tarball verifier (required tools + PE check sweep); sets `PE_CHECK_BUNDLED_DLLS=bcrypt.dll` |
| [`repro/scripts/utils/extras-toolset-status.sh`](repro/scripts/utils/extras-toolset-status.sh) | Per-extras-tool sentinel + binary presence report |
| [`repro/scripts/smoke-extras-wine-version.sh`](repro/scripts/smoke-extras-wine-version.sh) | Smoke: each extras tool `--version` (or muon's positional `version`) under Wine |
| [`repro/scripts/write-toolchain-manifest.sh`](repro/scripts/write-toolchain-manifest.sh) | Writes all three manifests (cross / native / extras) |
| [`repro/configs/busybox-w32.config`](repro/configs/busybox-w32.config) | Checked-in busybox-w32 Kconfig snapshot |
| [`repro/patches/`](repro/patches/) | Per-component patch series + generator |
| [`repro/docs/design.md`](repro/docs/design.md) | Authoritative design doc — read for deeper detail |
| [`.github/workflows/docker.yml`](.github/workflows/docker.yml) | CI; `BUILD_EXTRAS=1` only on tag pushes; release artifact glob is `repro/out/package/*.tar.*` |

## Useful executable paths

jq -- C:\git-sdk-64\usr\bin
objdump -- C:\git-sdk-64\mingw64\bin
