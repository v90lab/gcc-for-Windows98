/* win98_compat.h - Win98 compatibility shim header (flat layout)
 *
 * Force-included via `-include` into every consumer translation unit so
 * source-level references to APIs missing from Win98 SE's
 * KERNEL32/ADVAPI32/WS2_32/MSVCRT get rewritten to win98_* wrappers in
 * libwin98compat.a. Each wrapper does GetProcAddress against the real
 * system DLL at runtime — full behavior on NT-class hosts, behavior-
 * preserving fallback on genuine Win9x.
 *
 * The header must do three things in this order:
 *
 *   1. Pull in the system headers — winsock2.h before windows.h to keep
 *      the legacy winsock.h out of the picture, ws2tcpip.h for addrinfo
 *      and socklen_t. This locks the real declarations of getaddrinfo /
 *      GetFinalPathNameByHandleA / etc. in with their normal dllimport
 *      linkage. (Counter-intuitively, that's what we WANT — those still
 *      need to resolve via the system DLL import tables when the consumer
 *      links a non-shimmed binary or when our wrapper calls through.)
 *
 *   2. Forward-declare the win98_* wrappers WITHOUT dllimport. These are
 *      normal static-library symbols that live in libwin98compat.a.
 *
 *   3. Install the macro redirects. Because the system headers are
 *      already preprocessed by now, the rewrites here only affect
 *      consumer source-level calls — they do NOT propagate back into
 *      the upstream declarations.
 *
 * Side effects of the system-header preload: every consumer TU gets the
 * full windows.h regardless of whether it set WIN32_LEAN_AND_MEAN. Our
 * consumers (binutils, gdb, busybox, ...) all use the full surface
 * anyway so the practical cost is just preprocessor noise.
 */

#ifndef WIN98_COMPAT_H
#define WIN98_COMPAT_H

/* --- 1. System header preload ------------------------------------------- */
/* Because the header is force-included into every consumer TU, pulling in
   the full windows.h subsystem set would pollute name spaces that don't
   need Win32 at all (e.g. libiberty/regex.c defines its own `typedef char
   boolean`, which collides with rpcndr.h's `boolean` pulled in by
   winscard.h). WIN32_LEAN_AND_MEAN skips winscard / winspool / mmsystem /
   ... while still loading the core windef + winbase + winuser + winnt
   types our shim prototypes reference. NOMINMAX likewise suppresses the
   windef.h min/max macros that conflict with consumer-side min/max.
   Both are set only if the consumer didn't already, and undef'd after the
   load so consumer code that branches on `#ifdef WIN32_LEAN_AND_MEAN`
   sees the original state. */
#ifndef WIN32_LEAN_AND_MEAN
# define WIN32_LEAN_AND_MEAN
# define WIN98_COMPAT_UNDEF_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
# define NOMINMAX
# define WIN98_COMPAT_UNDEF_NOMINMAX
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stddef.h>   /* size_t for qsort_s */

#ifdef WIN98_COMPAT_UNDEF_LEAN_AND_MEAN
# undef WIN32_LEAN_AND_MEAN
# undef WIN98_COMPAT_UNDEF_LEAN_AND_MEAN
#endif
#ifdef WIN98_COMPAT_UNDEF_NOMINMAX
# undef NOMINMAX
# undef WIN98_COMPAT_UNDEF_NOMINMAX
#endif

/* --- 2. win98_* wrapper declarations (NO dllimport) --------------------- */
#ifdef __cplusplus
extern "C" {
#endif

/* kernel32 */
DWORD WINAPI win98_GetFinalPathNameByHandleA(HANDLE, LPSTR, DWORD, DWORD);
UINT  WINAPI win98_GetSystemWow64DirectoryA(LPSTR, UINT);
BOOL  WINAPI win98_GetLogicalProcessorInformation(PSYSTEM_LOGICAL_PROCESSOR_INFORMATION, PDWORD);
VOID  WINAPI win98_GetSystemTimePreciseAsFileTime(LPFILETIME);
BOOL  WINAPI win98_IsWow64Process(HANDLE, PBOOL);
DWORD WINAPI win98_GetProcessId(HANDLE);
HWND  WINAPI win98_GetConsoleWindow(void);
BOOL  WINAPI win98_GetFileSizeEx(HANDLE, PLARGE_INTEGER);

/* ws2_32 */
int   WSAAPI win98_getaddrinfo(const char *, const char *, const struct addrinfo *, struct addrinfo **);
void  WSAAPI win98_freeaddrinfo(struct addrinfo *);
int   WSAAPI win98_getnameinfo(const struct sockaddr *, socklen_t, char *, DWORD, char *, DWORD, int);

/* advapi32 */
BOOLEAN WINAPI win98_SystemFunction036(PVOID, ULONG);

/* msvcrt */
void __cdecl win98_qsort_s(void *, size_t, size_t,
                           int (__cdecl *)(void *, const void *, const void *),
                           void *);

#ifdef __cplusplus
}
#endif

/* --- 3. Macro redirects (must come AFTER the system header preload) ---- */
#define GetFinalPathNameByHandleA      win98_GetFinalPathNameByHandleA
#define GetSystemWow64DirectoryA       win98_GetSystemWow64DirectoryA
#define GetLogicalProcessorInformation win98_GetLogicalProcessorInformation
#define GetSystemTimePreciseAsFileTime win98_GetSystemTimePreciseAsFileTime
#define IsWow64Process                 win98_IsWow64Process
#define GetProcessId                   win98_GetProcessId
#define GetConsoleWindow               win98_GetConsoleWindow
#define GetFileSizeEx                  win98_GetFileSizeEx
#define getaddrinfo                    win98_getaddrinfo
#define freeaddrinfo                   win98_freeaddrinfo
#define getnameinfo                    win98_getnameinfo
#define SystemFunction036              win98_SystemFunction036
#define qsort_s                        win98_qsort_s

#endif /* WIN98_COMPAT_H */
