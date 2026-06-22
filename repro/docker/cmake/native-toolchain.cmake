set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR i686)
set(CMAKE_C_COMPILER /opt/cmake-toolchain/wine-gcc.sh)
set(CMAKE_CXX_COMPILER /opt/cmake-toolchain/wine-gxx.sh)
set(CMAKE_RC_COMPILER /opt/cmake-toolchain/wine-windres.sh)
set(CMAKE_FIND_ROOT_PATH /opt/native-toolset/i686-w64-mingw32)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)

# Inject the win98-compat shim into every CMake-built binary. See the
# matching block in cross-toolchain.cmake for the full rationale — same
# mechanism, same flags. The native toolset's sysroot ships its own copy
# of libwin98compat.a installed by install-win98-compat-native.sh.
set(_WIN98_COMPAT_LINK "-Wl,--whole-archive -lwin98compat -Wl,--no-whole-archive")
set(CMAKE_EXE_LINKER_FLAGS_INIT    "${_WIN98_COMPAT_LINK}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${_WIN98_COMPAT_LINK}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${_WIN98_COMPAT_LINK}")
