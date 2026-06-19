# gcc-for-Windows98 Reproducible Build

Docker-based reproducible build environment for `fsb4000/gcc-for-Windows98`.

Produces two toolchain artifacts and a consumer Docker image:

| Artifact        | Path                                          | Description                                     |
|-----------------|-----------------------------------------------|-------------------------------------------------|
| Cross toolchain | `out/package/gcc-win98-toolchain.tar.xz`      | Linux-hosted MinGW cross compiler (→ Win98)     |
| Native toolset  | `out/package/gcc-win98-native-toolset.zip`    | Windows-hosted compiler (runs on Win98)         |
| Consumer image  | `gcc-win98-consumer:latest`                   | Docker image with both toolchains + Wine        |

## Quick Start

```bash
# One-shot: build both toolchains, consumer image, and smoke tests
./build.sh

# Control parallel jobs and matrix version
./build.sh --jobs 4 --matrix gcc-11.1.0

# Regenerate patches before build (after modifying sources)
./build.sh --generate-patches

# Clean outputs and rebuild from scratch
./build.sh --clean

# Force Docker image rebuild (no layer cache)
./build.sh --no-cache
```

```
Usage: ./build.sh [--jobs N] [--matrix ID_OR_LABEL] [--generate-patches] [--no-cache] [--clean]
  --jobs N            Parallel build jobs (default: nproc)
  --matrix M          Matrix selector: numeric index or version label from config.json (default: 0)
  --generate-patches  Regenerate versioned patch folders before build
  --no-cache          Force Docker image rebuild without cache
  --clean             Remove out/ before building
```

## Repository Layout

```
repro/
├── build.sh                  # One-shot entry point
├── config.json               # Pinned source commits (reproducibility matrix)
├── docker-compose.yml        # Services: toolchain-builder, consumer
├── cmake/                    # CMake compatibility helpers (filesystem, patch)
├── docker/
│   ├── toolchain-builder.Dockerfile
│   ├── consumer.Dockerfile
│   ├── cmake/                # CMake toolchain files + Wine wrapper scripts
│   └── scripts/              # Container-internal helpers
├── docs/
│   └── design.md             # Architecture and design reference
├── patches/                  # Win98 compatibility patches
│   ├── generate-patches.py   # Patch generation tool
│   ├── gcc/11.1.0/           # GCC 11.1.0 patches + series.txt
│   ├── mingw-w64/master/     # mingw-w64 patch + series.txt
│   └── pthread9x/master/     # pthread9x patch + series.txt
├── scripts/                  # Build and smoke orchestration scripts
│   ├── lib/                  # Shared shell library + Python helpers
│   ├── utils/                # Status reporters
│   └── verifiers/            # PE and package verifiers
├── src/                      # Populated at build time by fetch-sources.sh
└── tests/                    # CMake-based smoke test suite
    ├── smoke-c/              # C tests
    └── smoke-cpp/            # C++ tests
```

## Build Phases

### Phase 1: Cross Toolchain (Linux → i686-w64-mingw32)

Orchestrated by `scripts/run-toolchain-build.sh`:

1. Fetch sources (GCC 11.1.0, binutils 2.36.1, mingw-w64, pthread9x) at pinned commits
2. Generate and apply Win98 compatibility patches
3. Build cross binutils, mingw-w64 headers + CRT, GCC stage1, pthread9x, GCC final
4. Package as `gcc-win98-toolchain.tar.xz`

### Phase 2: Native Toolset (Canadian Cross)

Builds Windows-hosted tools that run natively on Windows 98:

5. Build native GCC, binutils, mingw-w64, pthread9x via Canadian Cross
6. Package as `gcc-win98-native-toolset.zip`

### Phase 3: Smoke Tests

Orchestrated by `scripts/run-smoke-pipeline.sh` inside the consumer container:

- **Phase 1**: Toolchain layout verification (`smoke-verify-layout.sh`)
- **Phase 2**: Win98 PE compatibility of native binaries (`smoke-check-native-pe.sh`)
- **Phase 3a/b**: CMake+Ninja builds of `tests/` with cross and native toolchains, PE check, Wine execution (`smoke-cmake-build.sh`)

## Key Design Decisions

| Decision        | Choice                                           | Rationale                                                        |
|-----------------|--------------------------------------------------|------------------------------------------------------------------|
| C runtime       | `msvcrt.dll`                                     | Present on Windows 95/98; UCRT requires Windows 10+              |
| Threading       | `pthread9x`                                      | POSIX threads for Win98; avoids Vista+ `_GLIBCXX_THREAD_ATEXIT_WIN32` |
| Static linking  | `-static-libgcc -static-libstdc++`               | Avoids DLL deployment issues on old Windows                      |
| GCC version     | 11.1.0                                           | Last series with maintainable Win98 patch surface                |
| Build isolation | Docker Compose                                   | Prevents host-environment contamination                          |
| Resumability    | `.status-<step>` sentinel files                  | Long builds can be interrupted and resumed                       |

## Status Reporting

```bash
# Overall project status
bash scripts/utils/project-status.sh

# Cross toolchain status
bash scripts/utils/cross-toolset-status.sh

# Native toolset status
bash scripts/utils/native-toolset-status.sh

# Smoke test status
bash scripts/utils/smoke-tests-status.sh
```

## License

See [LICENSE](../LICENSE)
