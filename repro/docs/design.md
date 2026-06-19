# gcc-for-Windows98 Reproducible Build — Design Document

## 1. Purpose

This directory contains a Docker-based reproducible build environment for
`fsb4000/gcc-for-Windows98`. Its goals are:

- Produce two toolchain artifacts that other projects can consume:
  - **Cross toolchain** (`gcc-win98-toolchain.tar.xz`): a Linux-hosted
    MinGW cross compiler targeting `i686-w64-mingw32`.
  - **Native toolset** (`gcc-win98-native-toolset.zip`): a
    Windows-hosted compiler (built via Canadian Cross) that runs on and
    targets Windows 98-class machines.
- Provide a **consumer Docker image** (`gcc-win98-consumer:latest`) with
  both toolchains pre-installed plus Wine, suitable for CI smoke tests.
- Ensure the build is fully reproducible via pinned source commits, a
  fixed base image, and idempotent step-tracking.

## 2. Key Design Decisions

| Decision        | Choice                                           | Rationale                                                                           |
|-----------------|--------------------------------------------------|-------------------------------------------------------------------------------------|
| C runtime       | `msvcrt.dll`                                     | Present on Windows 95/98; UCRT requires Windows 10+                                 |
| Threading       | `pthread9x`                                      | POSIX threads for Win98-class systems; avoids Vista+ `_GLIBCXX_THREAD_ATEXIT_WIN32` |
| Static linking  | Supported via `-static-libgcc -static-libstdc++` | Avoids DLL deployment issues on old Windows                                         |
| GCC version     | 11.1.0                                           | Last series with maintainable Win98 patch surface                                   |
| Build isolation | Docker Compose                                   | Prevents host-environment contamination                                             |
| Resumability    | `.status-<step>` sentinel files                  | Long builds can be interrupted and resumed                                          |

## 3. Repository Layout

```
repro/
├── build.sh                     # Top-level entry point
├── config.json                  # Pinned source commits (reproducibility matrix)
├── docker-compose.yml           # Two services: toolchain-builder, consumer
├── cmake/                       # CMake helpers for the test suite
│   ├── filesystem.hxx.in        # Compatibility header template (std::filesystem)
│   ├── FindStdFileSystem.cmake  # Detects / polyfills C++17 filesystem
│   └── Patch.cmake              # Portable GNU patch wrapper
├── docker/
│   ├── toolchain-builder.Dockerfile  # Build environment
│   ├── consumer.Dockerfile           # Runtime/test environment (multi-stage)
│   ├── cmake/                        # CMake toolchain files & Wine wrappers
│   │   ├── cross-toolchain.cmake
│   │   ├── native-toolchain.cmake
│   │   ├── wine-gcc.sh
│   │   ├── wine-gxx.sh
│   │   └── wine-windres.sh
│   └── scripts/                      # Container-internal helper scripts
│       ├── apt-mirror-selector.sh
│       ├── install-toolchain-artifact.sh
│       └── verify-toolchain-contract.sh
├── docs/
│   └── design.md                # ← this file
├── patches/                     # Source patches applied during build
│   ├── generate-patches.py      # Patch generation tool
│   ├── base.py                  # PatchSet base class
│   ├── gcc/11.1.0/              # Four GCC patches (thread-atexit, aligned-alloc, quick_exit)
│   ├── mingw-w64/master/        # UCRT → msvcrt default patch
│   └── pthread9x/master/        # Static-linking dllimport fix
├── scripts/                     # Staged build and smoke scripts
│   ├── lib/
│   │   ├── common.sh            # Shared utilities, logging, Docker helpers, step tracking
│   │   ├── status-common.sh     # Shared helpers for status reporter scripts
│   │   ├── config_matrix_exports.py  # Parse config.json matrix; emit shell exports
│   │   └── toolchain_manifest.py     # Build and write toolchain manifest JSON
│   ├── utils/
│   │   ├── project-status.sh         # Top-level status aggregator
│   │   ├── cross-toolset-status.sh   # Cross toolchain status report
│   │   ├── native-toolset-status.sh  # Native toolset status report
│   │   └── smoke-tests-status.sh     # Smoke test pipeline status report
│   ├── verifiers/
│   │   ├── pe-win98-check.sh         # Shared Win98 PE checker (sourceable + CLI)
│   │   └── verify-native-package.sh  # Verify native package tar.xz contents
│   ├── run-toolchain-build.sh   # Toolchain build orchestrator (cross + native)
│   ├── run-smoke-pipeline.sh    # Smoke test orchestrator (inside consumer container)
│   ├── fetch-sources.sh … package-native-toolset.sh  # Staged build scripts
│   ├── smoke-verify-layout.sh   # Smoke Phase 1: toolchain layout check
│   ├── smoke-check-native-pe.sh # Smoke Phase 2: Win98 PE check on native binaries
│   ├── smoke-cmake-build.sh     # Smoke Phase 3: CMake+Ninja + PE check + Wine run
│   └── apply-patches.sh         # Apply Win98 compatibility patches from series.txt
├── src/                         # Populated at build time by fetch-sources.sh
└── tests/                       # CMake-based smoke-test suite
    ├── smoke-c/                  # C tests (hello, threads, winsock, win98 API, …)
    └── smoke-cpp/                # C++ tests (exceptions, STL, fstream, …)
```

## 4. Component Versions (config.json)

All sources are fetched at pinned commits to guarantee reproducibility:

| Component | Repository                        | Tag / Commit          |
|-----------|-----------------------------------|-----------------------|
| GCC       | `gcc-mirror/gcc`                  | `gcc-11_1_0-release`  |
| binutils  | `sourceware.org/git/binutils-gdb` | `binutils-2_36_1`     |
| mingw-w64 | `mirror/mingw-w64`                | `master` @ pinned SHA |
| pthread9x | `JHRobotics/pthread9x`            | `main` @ pinned SHA   |

`config.json` is parsed at build time by `scripts/lib/config_matrix_exports.py`, which emits
shell-safe `KEY=value` lines that `common.sh` evaluates to set fetch refs.

## 5. Docker Infrastructure

### 5.1 Services (docker-compose.yml)

| Service             | Image                                     | Role                                                |
|---------------------|-------------------------------------------|-----------------------------------------------------|
| `toolchain-builder` | Built from `toolchain-builder.Dockerfile` | Compiles everything; mounts project root at `/work` |
| `consumer`          | Built from `consumer.Dockerfile`          | Embeds both artifacts; runs smoke tests under Wine  |

Both services share the project root as a volume so build outputs flow
between host and containers without copying.

### 5.2 toolchain-builder.Dockerfile

Base: `ubuntu:22.04`

Key packages installed:
- Build tools: `build-essential`, `cmake`, `make`, `patch`, `perl`,
  `python3`, `bison`, `flex`, `gawk`, `texinfo`, `help2man`
- GCC prerequisites: `libgmp-dev`, `libmpc-dev`, `libmpfr-dev`, `libisl-dev`
- Bootstrap cross compiler: `binutils-mingw-w64-i686`, `gcc-mingw-w64-i686-win32`
- Utilities: `git`, `curl`, `jq`, `xz-utils`

`apt-mirror-selector.sh` probes several Ubuntu mirrors (Aliyun, Tencent,
USTC) before falling back to the default, ensuring reliable installs in
network-restricted environments.

### 5.3 consumer.Dockerfile (multi-stage)

| Stage       | Purpose                                                           |
|-------------|-------------------------------------------------------------------|
| `base`      | Installs runtime dependencies, Wine, xvfb                         |
| `extractor` | Unpacks both `.tar.xz` artifacts into `/opt/`                     |
| `final`     | Installs CMake toolchain files, configures Wine prefix, sets PATH |

The consumer image ships `/opt/cross-toolset` and `/opt/native-toolset`
plus CMake toolchain files at `/opt/cmake-toolchain/`, making it
self-contained for downstream CI use.

### 5.4 CMake Toolchain Files

**cross-toolchain.cmake** — standard Linux cross-compilation:
```cmake
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_C_COMPILER   i686-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER i686-w64-mingw32-g++)
set(CMAKE_RC_COMPILER  i686-w64-mingw32-windres)
```

**native-toolchain.cmake** — drives native Windows binaries via Wine
wrappers (`wine-gcc.sh`, `wine-gxx.sh`, `wine-windres.sh`):
```bash
export WINEARCH=win32
exec wine "${NATIVE_PREFIX}/bin/gcc.exe" "$@"
```
This allows CMake to treat the native toolchain like a local compiler
while actually delegating execution to Wine.

## 6. Build Pipeline

The pipeline has three phases: cross toolchain, native toolset, and smoke tests.

### 6.1 Phase 1 — Cross Toolchain (Linux → i686-w64-mingw32)

Orchestrated by `run-toolchain-build.sh` inside the `toolchain-builder` container.

| Script                       | What it does                                                               |
|------------------------------|----------------------------------------------------------------------------|
| `fetch-sources.sh`           | Shallow-clones GCC, binutils, mingw-w64, pthread9x at pinned commits       |
| `generate-patches.sh`        | (optional) Regenerate patch series from current source trees               |
| `prepare-mingw-w64.sh`       | Apply Win98 patches to mingw-w64; reset to clean state first               |
| `build-cross-binutils.sh`    | Cross binutils (`--target=i686-w64-mingw32`)                               |
| `build-cross-mingw-w64.sh`   | mingw-w64 headers + CRT with `--with-default-msvcrt=msvcrt`                |
| `prepare-gcc.sh`             | Apply Win98 patches to GCC/libstdc++                                       |
| `build-cross-gcc-stage1.sh`  | Bootstrap GCC: `--without-headers --with-newlib --disable-threads`         |
| `build-cross-pthread9x.sh`   | pthread9x (static + dynamic); installs headers, `libpthread.a`, `crtfix.o` |
| `build-cross-gcc.sh`         | Final GCC: `--enable-languages=c,c++ --enable-threads=posix`               |
| `package-cross-toolset.sh`   | Packages into `out/package/gcc-win98-toolchain.tar.xz`                     |
| `write-toolchain-manifest.sh`| Writes JSON manifest (SHA256, GCC version, thread model)                   |

**Script naming convention**: Cross-toolchain build scripts are named `build-cross-*.sh`.
Native-toolchain build scripts are named `build-native-*.sh`.

### 6.2 Phase 2 — Native Toolset (Canadian Cross)

Build triple: `--build=x86_64-pc-linux-gnu --host=i686-w64-mingw32 --target=i686-w64-mingw32`

The resulting binaries run on Windows 98 and produce Windows 98 code.

| Script                      | What it does                                                   |
|-----------------------------|----------------------------------------------------------------|
| `build-native-host-gcc.sh`  | Canadian Cross GCC; uses cross-toolchain as the build compiler |
| `build-native-binutils.sh`  | Native-host binutils                                           |
| `build-native-mingw-w64.sh` | Native-host mingw-w64 CRT                                      |
| `build-native-pthread9x.sh` | Native-host pthread9x                                          |
| `package-native-toolset.sh` | Packages into `out/package/gcc-win98-native-toolset.zip`       |

**Notable Canadian Cross workarounds:**
- `--disable-libstdcxx-pch` — avoids PCH incompatibilities.
- `--disable-lto` — avoids `liblto_plugin.so` ABI conflicts.

### 6.3 Phase 3 — Smoke Tests

Orchestrated by `run-smoke-pipeline.sh` inside the `consumer` container.

| Step | Script | What it validates |
|------|--------|-------------------|
| Phase 1 | `smoke-verify-layout.sh` | Toolchain layout: required binaries and directories exist |
| Phase 2 | `smoke-check-native-pe.sh` | Win98 PE compatibility of native toolchain binaries themselves |
| Phase 3a | `smoke-cmake-build.sh cross N` | CMake+Ninja build of `tests/` with cross toolchain; PE check + Wine run |
| Phase 3b | `smoke-cmake-build.sh native N` | CMake+Ninja build of `tests/` with native toolchain; PE check + Wine run |

Phases 3a and 3b both use `verifiers/pe-win98-check.sh` to validate that every
built `.exe` has `MajorOSVersion ≤ 4` and no forbidden imports (UCRT, `api-ms-win-*`,
`vcruntime`).

### 6.4 Step Tracking and Resumability

`scripts/lib/common.sh` provides:
- `mark_done <step>` — creates `$OUT_DIR/.status-<step>`
- `is_done <step>` — checks for the sentinel
- `builder_script <script> [args]` — run a script inside the toolchain-builder container
- `consumer_script <script> [args]` — run a script inside the consumer container

`run-toolchain-build.sh` supports `--resume [STEP]` to restart from the last
completed step (or a named step), skipping steps whose sentinels already exist.

## 7. Patch System

Patches live under `patches/` and are applied by `apply-patches.sh`,
which applies each file listed in `series.txt` in order using `git apply`.

### 7.1 GCC Patches (`patches/gcc/11.1.0/`)

| Patch | Purpose |
|-------|---------|
| `0001-disable-thread-atexit-win32.patch` | Disables `_GLIBCXX_THREAD_ATEXIT_WIN32` (requires Vista+) |
| `0002-remove-atexit-thread-dll-handling.patch` | Removes `GetModuleHandleExW` / `FreeLibrary` calls from `atexit_thread.cc` |
| `0003-disable-lfs-and-aligned-alloc.patch` | Disables `_GLIBCXX_USE_LFS`, `_GLIBCXX_HAVE_ALIGNED_ALLOC`, `_GLIBCXX_HAVE__ALIGNED_MALLOC` |
| `0004-fix-msvcrt-quick-exit-detection.patch` | Disables `at_quick_exit`/`quick_exit` detection in libstdc++ configure inputs |

### 7.2 mingw-w64 Patches (`patches/mingw-w64/master/`)

| Patch | Purpose |
|-------|---------|
| `0001-ucrt-default-to-msvcrt.patch` | Changes default CRT from UCRT to `msvcrt-os` in `configure.ac` |

### 7.3 pthread9x Patches (`patches/pthread9x/master/`)

| Patch | Purpose |
|-------|---------|
| `0001-fix-static-linking-dllimport.patch` | Removes `dllimport` decorations that break `-static` builds |

### 7.4 Patch Generation

`patches/generate-patches.py` dynamically generates patch series by diffing modified sources:

```bash
python3 patches/generate-patches.py --gcc-version=11.1.0 --source-dir=src/gcc
python3 patches/generate-patches.py --mingw-w64-version=master --source-dir=src/mingw-w64
python3 patches/generate-patches.py --pthread9x-version=master --source-dir=src/pthread9x
```

Each component has a `PatchSet` subclass (`gcc/patch.py`, `mingw-w64/patch.py`,
`pthread9x/patch.py`) implementing component-specific patch logic.

## 8. Shared Libraries

### 8.1 Bash Library (`scripts/lib/`)

| File | Purpose |
|------|---------|
| `common.sh` | Directory paths, version pins, logging (`log`, `die`), step tracking, `builder_exec`, `builder_script`, `consumer_exec`, `consumer_script`, `load_fetch_config_from_json` |
| `status-common.sh` | Shared helpers for status reporters: `status_say`, `status_section`, `status_exists_line`, `status_file_meta`, `status_sha256_if_file`, `status_tail_latest`, `status_step_line` |

### 8.2 Python Modules (`scripts/lib/`)

| File | Purpose |
|------|---------|
| `config_matrix_exports.py` | Parses `config.json` by numeric index or version label; emits `KEY=value` lines for `eval` in shell |
| `toolchain_manifest.py` | Constructs and writes the toolchain manifest JSON from component version data |

Unit tests for both modules live in `scripts/lib/tests/`.

### 8.3 Win98 PE Verifier (`scripts/verifiers/pe-win98-check.sh`)

A shared, sourceable library that implements Win98 PE binary verification:

- `PE_FORBIDDEN_IMPORT_PATTERNS` — array of forbidden DLL name patterns (`*ucrt*`, `api-ms-win-*`, `vcruntime*`)
- `pe_check_win98 <binary>` — checks a PE binary for forbidden imports and `MajorOSVersion > 4`; returns non-zero on failure

Used directly by `smoke-cmake-build.sh` and `smoke-check-native-pe.sh`.
Also callable as a standalone CLI tool:

```bash
bash scripts/verifiers/pe-win98-check.sh path/to/binary.exe
```

## 9. Status Reporters (`scripts/utils/`)

Four scripts provide human-readable build status reports:

| Script | Reports on |
|--------|-----------|
| `project-status.sh` | Aggregated summary — calls cross, native, and smoke reporters in sequence |
| `cross-toolset-status.sh` | Cross toolchain step markers, artifact existence, package metadata |
| `native-toolset-status.sh` | Native toolset step markers, artifact existence |
| `smoke-tests-status.sh` | Smoke phase markers, `.exe` counts, latest log tails |

All reporters source `lib/status-common.sh` for consistent formatting.

## 10. Entry Point: build.sh

`build.sh` is the single entry point for a complete build:

```bash
./build.sh [--jobs N] [--matrix ID_OR_LABEL] [--generate-patches] [--no-cache] [--clean]
```

Execution flow:
1. Parse arguments; validate matrix selector against `config.json`.
2. Build (or reuse cached) `toolchain-builder` Docker image.
3. Start `toolchain-builder` container; run `run-toolchain-build.sh` to build cross + native toolchains.
4. Build (or reuse cached) `consumer` Docker image (embeds the just-built artifacts).
5. Start `consumer` container; run `run-smoke-pipeline.sh` to validate both toolchains.
6. Print a summary of artifact locations.

`--clean` removes `out/` before starting; `--no-cache` forces Docker image rebuilds.

## 11. Outputs

| Artifact           | Path                                          | Description                              |
|--------------------|-----------------------------------------------|------------------------------------------|
| Cross toolchain    | `out/package/gcc-win98-toolchain.tar.xz`      | Linux-hosted MinGW cross compiler        |
| Native toolset     | `out/package/gcc-win98-native-toolset.zip`    | Windows-hosted native compiler           |
| Toolchain manifest | `out/package/toolchain-manifest.json`         | SHA256, GCC version, thread model        |
| Consumer image     | `gcc-win98-consumer:latest`                   | Docker image with both toolchains + Wine |
| Build logs         | `logs/`                                       | Per-step log files with timestamps       |



