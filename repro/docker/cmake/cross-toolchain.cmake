set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR i686)
set(CMAKE_C_COMPILER i686-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER i686-w64-mingw32-g++)
set(CMAKE_RC_COMPILER i686-w64-mingw32-windres)
set(CMAKE_FIND_ROOT_PATH /opt/cross-toolset/i686-w64-mingw32)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Inject the win98-compat shim into every CMake-built binary. This is the
# parallel of WIN98_COMPAT_LDFLAGS in scripts/lib/common.sh (which the
# autotools-driven extras-tool builds consume directly). --whole-archive
# pulls in the IAT-slot definitions unconditionally so even imports the
# consumer never named at the source level (e.g. msvcrt:_fstat64 dragged
# in by static-linked stdio init) get redirected to win98_* wrappers,
# keeping them out of the PE import table.
set(_WIN98_COMPAT_LINK "-Wl,--whole-archive -lwin98compat -Wl,--no-whole-archive")
set(CMAKE_EXE_LINKER_FLAGS_INIT    "${_WIN98_COMPAT_LINK}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${_WIN98_COMPAT_LINK}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${_WIN98_COMPAT_LINK}")
