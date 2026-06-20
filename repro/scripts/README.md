# gcc-for-Windows98 Build Scripts

This directory contains the build orchestration scripts for the gcc-for-Windows98 toolchain project.

## Directory Layout

```
scripts/
├── lib/
│   ├── common.sh                     # Shared utilities: paths, versions, logging, step tracking, Docker helpers
│   ├── status-common.sh              # Shared helpers for status reporter scripts
│   ├── config_matrix_exports.py      # Parse config.json matrix; emit shell-safe key=value exports
│   └── toolchain_manifest.py         # Build and write toolchain manifest JSON
├── utils/
│   ├── project-status.sh             # Top-level status aggregator (calls cross/native/smoke reporters)
│   ├── cross-toolset-status.sh       # Cross toolchain build status report
│   ├── native-toolset-status.sh      # Native toolset build status report
│   └── smoke-tests-status.sh         # Smoke test pipeline status report
├── verifiers/
│   ├── pe-win98-check.sh             # Shared Win98 PE compatibility checker (sourceable + CLI)
│   ├── check-for-imp-lib.sh          # CLI forbidden-import checker (sources pe-win98-check.sh)
│   └── verify-native-package.sh      # Verify native package zip contains required paths
├── run-toolchain-build.sh            # Master orchestration: cross + native build with resume support
├── run-smoke-pipeline.sh             # Smoke test orchestrator (runs inside consumer container)
├── fetch-sources.sh                  # Clone source trees at pinned commits
├── apply-patches.sh                  # Apply Win98 compatibility patches from patches/*/series.txt
├── generate-patches.sh               # Wrapper: invoke patches/generate-patches.py
├── prepare-mingw-w64.sh              # Prepare mingw-w64 sources for build
├── prepare-gcc.sh                    # Prepare GCC sources for build
├── build-cross-binutils.sh           # Build cross binutils (as, ld, ar)
├── build-cross-mingw-w64.sh          # Build mingw-w64 headers & CRT (--with-default-msvcrt=msvcrt)
├── build-cross-gcc-stage1.sh         # Build GCC stage1 bootstrap (C only, no libstdc++)
├── prepare-pthread9x.sh              # Prepare pthread9x sources for build
├── build-cross-pthread9x.sh          # Build pthread9x for the cross toolchain
├── build-cross-gcc.sh                # Build GCC final stage2 (C/C++ with pthread9x)
├── package-cross-toolset.sh          # Package cross toolchain as tar.xz
├── write-toolchain-manifest.sh       # Generate package manifest JSON for cross/native artifacts
├── build-native-mingw-deps.sh        # Build GMP/MPFR/MPC for the native-host toolchain
├── build-native-host-gcc.sh          # Build native-host GCC via Canadian Cross
├── build-native-binutils.sh          # Build native-host binutils via Canadian Cross
├── build-native-mingw-w64.sh         # Build native-host mingw-w64 via Canadian Cross
├── build-native-pthread9x.sh         # Build native-host pthread9x via Canadian Cross
├── package-native-toolset.sh         # Package native toolset as zip
├── smoke-verify-layout.sh            # Smoke Phase 1: toolchain layout verification
├── smoke-check-native-pe.sh          # Smoke Phase 2: Win98 PE compatibility of native binaries
└── smoke-cmake-build.sh              # Smoke Phase 3: CMake+Ninja build + PE check + Wine run
```

### Backward Compatibility Shims

`build-mingw-w64.sh` is a shim that delegates to `build-cross-mingw-w64.sh`. It exists only for backward
compatibility with any external references to the old naming scheme.

## Usage

### Full Build

```bash
./scripts/run-toolchain-build.sh```

### Resume After Failure

```bash
# Auto-detect last completed step and resume from there
./scripts/run-toolchain-build.sh --resume

# Resume from a specific step
./scripts/run-toolchain-build.sh --resume build-gcc-stage1
```

### Custom Jobs / Target

## Usage

### Full Build

```bash
# Run from repro/ (or via build.sh at project root)
./scripts/run-toolchain-build.sh
```

### Resume After Failure

```bash
# Auto-detect last completed step and resume
./scripts/run-toolchain-build.sh --resume

# Resume from a specific named step
./scripts/run-toolchain-build.sh --resume build-cross-gcc-stage1
```

### Custom Jobs / Target

```bash
./scripts/run-toolchain-build.sh --jobs 8 --target i686-w64-mingw32
```

### Regenerate Patches Before Build

```bash
./scripts/run-toolchain-build.sh --generate-patches
```

### Run Smoke Tests

```bash
# Requires consumer container running: docker compose up -d consumer
./scripts/run-smoke-pipeline.sh --jobs 4
```

### Status Reports

```bash
bash scripts/utils/project-status.sh        # Overall summary
bash scripts/utils/cross-toolset-status.sh  # Cross toolchain
bash scripts/utils/native-toolset-status.sh # Native toolset
bash scripts/utils/smoke-tests-status.sh    # Smoke tests
```

## Script Conventions

All build scripts follow these conventions:

1. **Header**: `#!/usr/bin/env bash` + `set -euo pipefail`
2. **Source common.sh**: `source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"`
3. **Use shared helpers**:
   - `log "message"` — timestamped logging
   - `die "message"` — fatal error with exit
   - `mark_done <step>` — record step completion
   - `is_done <step>` — check completion (used by orchestrators for resume/skip)
   - `builder_script <script> [args]` — run a script inside the toolchain-builder container
   - `consumer_script <script> [args]` — run a script inside the consumer container
4. **Status tracking**: Each step writes a sentinel via `mark_done` keyed by step name

## Build Phases

### Phase 1: Cross Toolchain (Linux → i686-w64-mingw32)

Orchestrated by `run-toolchain-build.sh`:

1. `fetch-sources.sh` — Shallow-clone source repositories at commits pinned in `config.json`
2. `generate-patches.sh` — (optional) Generate patch series from source trees
3. `prepare-mingw-w64.sh` — Apply Win98 compatibility patches to mingw-w64
4. `build-cross-binutils.sh` — Build cross assembler, linker, and archiver
5. `build-cross-mingw-w64.sh` — Build mingw-w64 headers and CRT (`--with-default-msvcrt=msvcrt`)
6. `prepare-gcc.sh` — Apply Win98 compatibility patches to GCC/libstdc++
7. `build-cross-gcc-stage1.sh` — Bootstrap GCC (C only, no libstdc++, no threads)
8. `prepare-pthread9x.sh` — Apply Win98 compatibility patches to pthread9x
9. `build-cross-pthread9x.sh` — Build pthread9x threading library
10. `build-cross-gcc.sh` — Full GCC (C/C++, pthread9x, libstdc++)
11. `package-cross-toolset.sh` — Package as `out/package/gcc-win98-cross-toolchain.tar.xz`
12. `write-toolchain-manifest.sh` — Write the cross-toolchain manifest JSON

### Phase 2: Native Toolset (Canadian Cross)

12. `build-native-mingw-deps.sh` — Build GMP/MPFR/MPC for the native-host compiler
13. `build-native-host-gcc.sh` — Native-host GCC via Canadian Cross
14. `build-native-binutils.sh` — Native-host binutils via Canadian Cross
15. `build-native-mingw-w64.sh` — Native-host mingw-w64 via Canadian Cross
16. `build-native-pthread9x.sh` — Native-host pthread9x via Canadian Cross
17. `package-native-toolset.sh` — Package as `out/package/gcc-win98-native-toolchain.zip`
18. `write-toolchain-manifest.sh` — Write the native-toolset manifest JSON

### Phase 3: Smoke Tests

Orchestrated by `run-smoke-pipeline.sh` inside the consumer container:

- `smoke-verify-layout.sh` — Phase 1: verify toolchain directory layout and key binaries
- `smoke-check-native-pe.sh` — Phase 2: Win98 PE compatibility check on native toolchain binaries
- `smoke-cmake-build.sh cross N` — Phase 3a: CMake+Ninja build with cross toolchain + PE check + Wine run
- `smoke-cmake-build.sh native N` — Phase 3b: CMake+Ninja build with native toolchain + PE check + Wine run

## Shared Library (`lib/`)

| File | Purpose |
|------|---------|
| `common.sh` | Directory paths, version pins, logging, step tracking, Docker exec helpers |
| `status-common.sh` | `status_say`, `status_section`, `status_file_meta`, `status_sha256_if_file`, `status_tail_latest`, `status_step_line` — used by all status reporters |
| `config_matrix_exports.py` | Parse `config.json` matrix entry by index or label; emit `KEY=value` shell exports |
| `toolchain_manifest.py` | Build and write toolchain manifest JSON from component version data |

## Verifiers (`verifiers/`)

| Script | Purpose |
|--------|---------|
| `pe-win98-check.sh` | Shared Win98 PE checker: defines `PE_FORBIDDEN_IMPORT_PATTERNS` and `pe_check_win98()`. Sourceable by other scripts; also usable as a standalone CLI tool. |
| `check-for-imp-lib.sh` | CLI wrapper that sources `pe-win98-check.sh` and checks a binary for forbidden imports (UCRT, api-ms-win, vcruntime) |
| `verify-native-package.sh` | Verifies that the native toolset zip contains all required paths (compiler, headers, linker, libraries) |

## Resume / Idempotency

Step completion is tracked via sentinel files: `$OUT_DIR/.status-<step-name>`.

- Re-running an orchestrator safely skips already-completed steps
- `--resume` in `run-toolchain-build.sh` auto-detects the last completed step or accepts an explicit step name
- Individual build scripts are also idempotent when sourced with common.sh helpers
