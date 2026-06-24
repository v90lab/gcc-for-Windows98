# std::filesystem on Win98: status and the path to enabling

If you're here because you tried to flip `PROBE_ENABLE_FILESYSTEM=1` in [`tests/smoke-cpp/cpp_feature_probe_config.hpp`](../tests/smoke-cpp/cpp_feature_probe_config.hpp) and want to know the cost before going further, read this whole doc. The disable is intentional, the shims aren't trivial, and several methods can't honestly be supported at all without source patches into libstdc++.

## TL;DR

| Status | API surface |
| --- | --- |
| **PE-check flags as missing (load-killers today)** | `KERNEL32:CreateHardLinkW`, `msvcrt:_wstat64` |
| **PE-check passes but stub-fails on Win9x at runtime** | `CreateFileW`, `DeleteFileW`, `GetFileAttributesW`, `GetFullPathNameW`, `GetTempPathW`, `MoveFileExW`, `RemoveDirectoryW`, `GetDiskFreeSpaceExW`, `CreateDirectoryW` (when called) |
| **Wide msvcrt funcs — likely OK on Win98 SE (unverified on hardware)** | `_wfopen`, `_wopen`, `_wchdir`, `_wchmod`, `_wmkdir`, `_wfindfirst`, `_wfindnext`, `_wfullpath`, `_wgetcwd`, `_wutime` |
| **Truly Vista+ — no Win9x equivalent, would need source patch to disable** | `GetFinalPathNameByHandleW`, `GetFileInformationByHandleEx`, `CreateSymbolicLinkW` (linker-dead-stripped today, return as soon as `canonical`/`read_symlink`/`create_symlink` is called) |

**Realistic minimum cost** to make a *useful subset* of `std::filesystem` work on Win98 (no symlinks, no `canonical`): **~15-18 shim functions + behavioral-denylist entries + likely a libstdc++ source patch to disable the Vista-only methods**.

**Realistic minimum cost** to make PE-check pass (with the binary still crashing at runtime the first time it touches a path): **2 shims**.

This is roughly an order of magnitude more work than [bcrypt-shim](../bcrypt-shim/bcrypt.c) (1 DLL, ~10 lines) and comparable to the [networking work](networking-on-win98.md) we punted on. Same class of decision, same answer.

## How the numbers were derived

Setup: temporarily set `PROBE_ENABLE_FILESYSTEM=1` in [`cpp_feature_probe_config.hpp`](../tests/smoke-cpp/cpp_feature_probe_config.hpp). The probe calls `temp_directory_path`, `create_directories`, `directory_iterator`, `file_size`, and `remove_all` — a narrow surface, deliberately. Then rebuild via `scripts/smoke-cmake-build.sh cross 4` and `objdump -p` the resulting binaries.

**Dynamic variant** (`cpp_feature_probe.exe`) PE-check: **PASSES.** This is misleading. The filesystem code lives in `libstdc++-6.dll`, which the bundled-DLLs hatch in [smoke-cmake-build.sh](../scripts/smoke-cmake-build.sh) suppresses checks for. The DLL still calls the stub-W APIs at runtime — it just doesn't get scanned.

**Static variant** (`cpp_feature_probe_static.exe`) PE-check: **FAILS** with exactly:
```
import not available on Win98: KERNEL32.dll:CreateHardLinkW
import not available on Win98: msvcrt.dll:_wstat64
```

But `objdump -p` on the static binary shows the **full** wide-API import surface (KERNEL32 + msvcrt) listed in the TL;DR table. The reason PE-check only flags 2 of those: the Win98 SE allowlist at [`data/win98se-api-allowlist.json`](../data/win98se-api-allowlist.json) is a verbatim snapshot of a real Win98 SE install's export tables. Most of the W APIs really are *exported* by Win98 SE's `KERNEL32.dll` — they just stub-fail at runtime with `ERROR_CALL_NOT_IMPLEMENTED`. So the imports bind, the loader is happy, and PE-check passes — but the first `fs::create_directory` call returns failure on real hardware.

This is the same class of trap as the `advapi32` NT-security stubs in [`win98-behavioral-denylist.json`](../data/win98-behavioral-denylist.json) and the same intuition from [AGENTS.md §5.8](../../AGENTS.md): the Win9x kernel is permissive in the wrong ways. The behavioral denylist exists exactly to surface these, but it currently only covers the advapi32 set.

## What it would take to enable

### Tier 0 — Make PE-check happy (does not work at runtime)
Add two trivial stubs to [`win98-compat`](../win98-compat/):
- `CreateHardLinkW` → return `FALSE` + `SetLastError(ERROR_CALL_NOT_IMPLEMENTED)`. Filesystem's `create_hard_link` already throws on failure.
- `_wstat64` → wrap `_wstati64`, widen the time fields the way [`win98_compat.c`](../win98-compat/src/win98_compat.c) already does for `_fstat64`.

**Cost**: 30 lines. **Result**: PE-check green; runtime still broken because of Tier 1.

### Tier 1 — Make the stub-W APIs honest on Win98
For each W-API in the "stub-fails at runtime" row of the TL;DR:
1. Add it to [`win98-behavioral-denylist.json`](../data/win98-behavioral-denylist.json) so PE-check tells the truth.
2. Add a shim to [`win98-compat`](../win98-compat/) that lazy-loads the A-equivalent on Win9x: convert the wide path via `WideCharToMultiByte(CP_ACP, ...)` (FAT32 paths are DBCS-safe on Win98), call the A version, convert the result back.
3. Verify each on real Win98 SE — some may actually work natively (Microsoft was inconsistent about which W APIs were stubs and which had real wide implementations even on Win9x).

**Cost**: ~11 functions, ~250-400 lines of shim code, plus on-hardware verification for each.
**Result**: a working subset that handles paths, directory iteration, file metadata, `remove`, `rename`. Still no symlinks or `canonical`.

### Tier 2 — Decide what to do about the Vista-only methods
`std::filesystem::canonical`, `read_symlink`, and `create_symlink` reach for `GetFinalPathNameByHandleW`, `GetFileInformationByHandleEx`, `CreateSymbolicLinkW`. The first two have **no Win9x equivalent at all** — they expose NT reparse-point and file-id concepts that the Win9x FAT-only filesystem doesn't have. The third is gated on a Win9x feature (NTFS symlinks) that doesn't exist.

Two honest options:
- **Patch libstdc++ source** to `throw std::filesystem::filesystem_error(make_error_code(std::errc::function_not_supported))` from these methods when `_WIN98_PORT` is defined, and rebuild libstdc++. Same pattern as the busybox `_WIN98_PORT` short-circuits.
- **Document them as undefined on Win98** and rely on the user not to call them. Risky — uncaught `filesystem_error` from a confusing place.

**Cost**: 1-2 days including the libstdc++ rebuild dance.
**Result**: complete `<filesystem>` interface, with the symlink/canonical subset failing in an expected, catchable way.

## Why we punted

1. **The audience is narrow.** Win98 users writing modern C++17 code in 2026 are a small set. Most of the working set wants to compile pre-C++17 Win9x-era code (where `<filesystem>` doesn't exist) or port small tools (where they can use `_wfopen`/`FindFirstFile` directly without the C++17 wrapper).

2. **The Tier 1 work is real-hardware-heavy.** Each of the ~11 W APIs needs an on-hardware probe (Wine doesn't reproduce the Win9x stub-fail trap, per AGENTS.md §5.8). That's per-API write-build-copy-to-disk-boot-test cycles, multiplied by some refactor rounds.

3. **The behavioral denylist work is a prerequisite, not a bonus.** Until [`win98-behavioral-denylist.json`](../data/win98-behavioral-denylist.json) covers all the stub-W APIs, PE-check actively lies on this code path. A user enabling `<filesystem>` today and seeing the smoke pass would believe it works, ship it, and discover the breakage in user reports.

4. **No existing extras tool needs it.** None of the tools in the extras toolset (busybox, make, ctags, diff, patch, gdb, muon, jq) use `std::filesystem` — they're all C, or pre-C++17 C++ using `<dirent.h>`/`FindFirstFile` directly. Enabling `<filesystem>` is purely for user code.

The decision was made on 2026-06-24 after running the experiment described in "How the numbers were derived" above.

## How to revisit

If you want to take this on later:

1. **Start with the denylist additions** — that's the cheap win that makes the rest possible. For each W API in the "stub-fails at runtime" row of the TL;DR, add an entry to [`win98-behavioral-denylist.json`](../data/win98-behavioral-denylist.json) with a rationale (the source for the stub-only behavior; Microsoft's old MSDN docs are the canonical reference). PE-check will then flag the filesystem-enabled probe build with the full list instead of just two imports.
2. **Tier 0 first** — get PE-check passing with the two stub shims, even if runtime is still broken. This unblocks iterating on Tier 1 without fighting the verifier on every rebuild.
3. **Audit on real hardware** before writing any Tier 1 shim. Write a `fsdiag.exe` in [`repro/diag/`](../diag/) modeled on [`sockdiag.c`](../diag/sockdiag.c) that calls each W API and reports actual return values + `GetLastError`. Some APIs may genuinely work on Win98 SE despite the stub assumption — don't waste shim work on those.
4. **Tier 1 shims one at a time, verified on hardware after each.** The W-to-A conversion path is straightforward but easy to get subtly wrong (`MB_PRECOMPOSED` vs not, lead-byte handling on DBCS code pages, trailing-null in the A buffer, etc.).
5. **Tier 2 source patch goes last.** The libstdc++ rebuild is invasive — make sure the rest works before adding it to the critical path.
6. **Flip `PROBE_ENABLE_FILESYSTEM=1` in the probe config** and verify the full probe passes on real hardware, not just under Wine.

## References

- The probe and its config: [`tests/smoke-cpp/cpp_feature_probe.cpp`](../tests/smoke-cpp/cpp_feature_probe.cpp), [`cpp_feature_probe_config.hpp`](../tests/smoke-cpp/cpp_feature_probe_config.hpp)
- Existing W-API allowlist (export-table truth): [`data/win98se-api-allowlist.json`](../data/win98se-api-allowlist.json)
- Existing behavioral denylist (the place stub-W APIs would go): [`data/win98-behavioral-denylist.json`](../data/win98-behavioral-denylist.json)
- Compile-time API shim infrastructure: [`win98-compat/`](../win98-compat/)
- The "Win9x is permissive in the wrong ways" intuition: [`AGENTS.md §5.8`](../../AGENTS.md)
- Parallel decision and reasoning shape: [`networking-on-win98.md`](networking-on-win98.md)
