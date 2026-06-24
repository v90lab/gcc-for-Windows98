// cpp_feature_probe_config.hpp
//
// Per-probe enable flags for cpp_feature_probe.cpp. Flip a knob to 0 to skip a
// probe at compile time (it then reports SKIP at runtime instead of running).
//
// Default-on probes are expected to compile, pass pe-win98-check, and run under
// Wine with this toolchain (gcc 11.1.0 + pthread9x + win98-compat shim).
// Default-off probes pull in unshimmed Win9x API gaps and would either fail to
// load (static-imported missing DLL) or fail at runtime. The comment next to
// each off-switch records the specific reason. When a probe is shimmed and
// starts passing, flip it on and update the comment.
//
// This file is consumed by the smoke build (CMake + Ninja inside the consumer
// container) AND by a Win98 user hand-compiling cpp_feature_probe.cpp on real
// hardware. Both compile against the same source.

#pragma once

// ── Default-on: expected to work on Win98 with the shipped toolchain ────────
#define PROBE_ENABLE_SHARED_MUTEX           1  // pthread9x rwlock
#define PROBE_ENABLE_CONDITION_VARIABLE     1  // pthread9x condvar + timed wait
#define PROBE_ENABLE_ASYNC                  1  // future/promise/async via std::thread
#define PROBE_ENABLE_MAGIC_STATICS          1  // __cxa_guard_* (libstdc++ + pthread)
#define PROBE_ENABLE_CROSS_THREAD_EXCEPTION 1  // current_exception / rethrow_exception
#define PROBE_ENABLE_CHRONO                 1  // system_clock::now reaches our GetSystemTimePreciseAsFileTime shim
#define PROBE_ENABLE_ATOMIC                 1  // i686 lock-prefixed ops, no API call
#define PROBE_ENABLE_REGEX                  1  // libstdc++ regex impl (pure C++)
#define PROBE_ENABLE_UNORDERED_MAP          1  // hash container + bucket alloc
#define PROBE_ENABLE_STRINGSTREAM           1  // ostringstream / istringstream
#define PROBE_ENABLE_SHARED_PTR             1  // refcount + weak_ptr
#define PROBE_ENABLE_FUNCTION               1  // std::function + lambda type erasure
#define PROBE_ENABLE_CPP17_VOCAB            1  // optional / variant / string_view
#define PROBE_ENABLE_RTTI                   1  // dynamic_cast + typeid

// ── Default-off: load-killers / known-broken on Win98 ───────────────────────

// std::random_device on libstdc++ 11 statically imports bcrypt!BCryptGenRandom.
// Win98 has no bcrypt.dll, so the binary fails to load before main() runs.
// Workaround: drop our bcrypt shim (out/extras-toolset/bin/bcrypt.dll, see
// AGENTS.md §5.7) next to the .exe; with that, this probe should pass.
#define PROBE_ENABLE_RANDOM_DEVICE          0

// std::filesystem in libstdc++ reaches for Vista+ wide-character path APIs
// (GetFinalPathNameByHandleW, GetFileInformationByHandleEx,
// CreateSymbolicLinkW, ...). The win98-compat shim only covers the ANSI
// GetFinalPathNameByHandleA today, so the wide imports kill the load.
// Enabling this would need the shim to grow wide variants AND the libstdc++
// impl to actually call them.
#define PROBE_ENABLE_FILESYSTEM             0
