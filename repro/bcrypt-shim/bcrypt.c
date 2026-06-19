/*
 * bcrypt.dll shim for Windows 98 — exports only BCryptGenRandom.
 *
 * libstdc++ 11's std::random_device (random.cc) statically imports
 * BCryptGenRandom from bcrypt.dll when targeting Windows. That dependency
 * gets baked into anything that links libstdc++ — for us, gdb.exe in the
 * extras toolset. Win98 has no bcrypt.dll, so without this shim the loader
 * fails before main().
 *
 * This shim satisfies the dynamic import with a non-cryptographic PRNG
 * (msvcrt rand seeded from GetTickCount). std::random_device callers in
 * gdb only use it as a seed source for std::mt19937 etc.; gdb is a
 * debugger, not a key generator.
 *
 * If anything later in the extras toolset starts needing real entropy on
 * Win98 — don't extend this file. Disable that feature or rebuild GCC with
 * a patched libstdc++ random.cc instead.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>

typedef LONG NTSTATUS;
#define STATUS_SUCCESS ((NTSTATUS)0)

static BOOL g_seeded = FALSE;

__declspec(dllexport)
NTSTATUS WINAPI
BCryptGenRandom(void *hAlgorithm, PUCHAR pbBuffer, ULONG cbBuffer, ULONG dwFlags)
{
    (void)hAlgorithm;
    (void)dwFlags;

    if (!g_seeded) {
        srand((unsigned)GetTickCount());
        g_seeded = TRUE;
    }
    while (cbBuffer--) {
        *pbBuffer++ = (UCHAR)(rand() & 0xff);
    }
    return STATUS_SUCCESS;
}

BOOL WINAPI
DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved)
{
    (void)hinst;
    (void)reason;
    (void)reserved;
    return TRUE;
}
