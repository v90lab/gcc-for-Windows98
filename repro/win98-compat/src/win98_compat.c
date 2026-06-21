/* win98_compat.c - Win98 API compatibility shim implementations.
 *
 * The shim installs itself by IAT interception, not by macro rewriting at
 * the source level. At the bottom of this file an inline asm block defines
 * __imp__FOO@N symbols (the PE Import Address Table slots) pre-pointing
 * at win98_FOO. When a consumer is linked with -lwin98compat ahead of the
 * implicit -lkernel32 / -lws2_32 / -ladvapi32 / -lmsvcrt, the linker
 * resolves the consumer's `call *_imp__FOO@N` references against our slots
 * — no import descriptor for FOO from the real DLL is emitted, and the
 * call lands directly in our wrapper at runtime.
 *
 * Consumers don't include any header to get this behavior — they just
 * link the library. (win98_compat.h still ships in the sysroot for
 * downstream code that wants to call win98_* wrappers explicitly.)
 *
 * Each wrapper:
 *   1. Tries GetProcAddress on the real system DLL (kernel32 / advapi32 /
 *      ws2_32). If found (NT-class host: Win2000+, XP, ...), calls through
 *      so behavior matches the real API exactly.
 *   2. Otherwise (genuine Win9x), falls back to a behavior-preserving stub.
 *      Fallbacks aim for "the consumer gets a sensible status and proceeds"
 *      not bit-exact semantics — gdb on Win9x without GetFinalPathNameByHandleA
 *      can't resolve symlinks, but a reasonable failure return lets the
 *      caller fall back to its non-resolved path.
 */

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>   /* must come BEFORE windows.h to suppress legacy winsock.h */
#include <ws2tcpip.h>
#include <windows.h>
#include <stdlib.h>
#include <string.h>

/* --- DLL handle caches -------------------------------------------------- */

static FARPROC resolve_kernel32(const char *name)
{
    static HMODULE k32 = NULL;
    if (!k32) k32 = GetModuleHandleA("kernel32.dll");
    return k32 ? GetProcAddress(k32, name) : NULL;
}

static FARPROC resolve_advapi32(const char *name)
{
    static HMODULE a32 = NULL;
    /* LoadLibraryA holds advapi32 for our lifetime — Win9x and NT both
       maintain the ref-count and unload at process exit; we never unmap. */
    if (!a32) a32 = LoadLibraryA("advapi32.dll");
    return a32 ? GetProcAddress(a32, name) : NULL;
}

static FARPROC resolve_ws2_32(const char *name)
{
    static HMODULE ws = NULL;
    if (!ws) ws = LoadLibraryA("ws2_32.dll");
    return ws ? GetProcAddress(ws, name) : NULL;
}

/* === KERNEL32 ============================================================ */

DWORD WINAPI
win98_GetFinalPathNameByHandleA(HANDLE hFile, LPSTR lpszFilePath,
                                DWORD cchFilePath, DWORD dwFlags)
{
    typedef DWORD (WINAPI *fn_t)(HANDLE, LPSTR, DWORD, DWORD);
    fn_t fn = (fn_t)resolve_kernel32("GetFinalPathNameByHandleA");
    if (fn) return fn(hFile, lpszFilePath, cchFilePath, dwFlags);

    /* No equivalent on Win9x — there's no symlink/junction concept and no
       handle->path inverse lookup. Returning 0 with ERROR_CALL_NOT_IMPLEMENTED
       is what callers checking the docs expect on failure. */
    (void)hFile; (void)lpszFilePath; (void)cchFilePath; (void)dwFlags;
    SetLastError(ERROR_CALL_NOT_IMPLEMENTED);
    return 0;
}

UINT WINAPI
win98_GetSystemWow64DirectoryA(LPSTR lpBuffer, UINT uSize)
{
    typedef UINT (WINAPI *fn_t)(LPSTR, UINT);
    fn_t fn = (fn_t)resolve_kernel32("GetSystemWow64DirectoryA");
    if (fn) return fn(lpBuffer, uSize);

    /* On 32-bit Windows (Win9x and 32-bit NT) there is no SysWOW64. Per
       MSDN, callers treat 0 as "no WOW64 directory" and skip the path
       transform. gdb/gdbserver windows-nat already handles this. */
    (void)lpBuffer; (void)uSize;
    SetLastError(ERROR_CALL_NOT_IMPLEMENTED);
    return 0;
}

BOOL WINAPI
win98_GetLogicalProcessorInformation(PSYSTEM_LOGICAL_PROCESSOR_INFORMATION buf,
                                     PDWORD ReturnLength)
{
    typedef BOOL (WINAPI *fn_t)(PSYSTEM_LOGICAL_PROCESSOR_INFORMATION, PDWORD);
    fn_t fn = (fn_t)resolve_kernel32("GetLogicalProcessorInformation");
    if (fn) return fn(buf, ReturnLength);

    /* Synthesize a single-core entry covering all CPUs reported by
       GetSystemInfo. Loses HT-vs-core distinction but is correct enough
       for muon's os_ncpus() (which just counts mask bits to seed -j). */
    SYSTEM_INFO si;
    GetSystemInfo(&si);

    DWORD needed = sizeof(SYSTEM_LOGICAL_PROCESSOR_INFORMATION);
    if (!ReturnLength) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return FALSE;
    }
    if (!buf || *ReturnLength < needed) {
        *ReturnLength = needed;
        SetLastError(ERROR_INSUFFICIENT_BUFFER);
        return FALSE;
    }

    ZeroMemory(buf, needed);
    buf->Relationship = RelationProcessorCore;

    DWORD n = si.dwNumberOfProcessors;
    if (n == 0) n = 1;
    if (n >= (sizeof(ULONG_PTR) * 8)) n = (DWORD)(sizeof(ULONG_PTR) * 8) - 1;
    buf->ProcessorMask = ((ULONG_PTR)1 << n) - 1;

    *ReturnLength = needed;
    return TRUE;
}

VOID WINAPI
win98_GetSystemTimePreciseAsFileTime(LPFILETIME ft)
{
    typedef VOID (WINAPI *fn_t)(LPFILETIME);
    fn_t fn = (fn_t)resolve_kernel32("GetSystemTimePreciseAsFileTime");
    if (fn) { fn(ft); return; }

    /* Win9x: ~15ms resolution from GetSystemTimeAsFileTime. Consumers
       using the "precise" variant for sub-millisecond stamps degrade
       gracefully — nothing in our toolset actually depends on it. */
    GetSystemTimeAsFileTime(ft);
}

BOOL WINAPI
win98_IsWow64Process(HANDLE proc, PBOOL is_wow64)
{
    typedef BOOL (WINAPI *fn_t)(HANDLE, PBOOL);
    fn_t fn = (fn_t)resolve_kernel32("IsWow64Process");
    if (fn) return fn(proc, is_wow64);

    /* Win9x is 32-bit only — by definition not a WOW64 process. */
    (void)proc;
    if (is_wow64) *is_wow64 = FALSE;
    return TRUE;
}

DWORD WINAPI
win98_GetProcessId(HANDLE proc)
{
    typedef DWORD (WINAPI *fn_t)(HANDLE);
    fn_t fn = (fn_t)resolve_kernel32("GetProcessId");
    if (fn) return fn(proc);

    /* Win9x has no documented handle->PID inverse. Best-effort: if the
       caller passes the current-process pseudo-handle, give them the real
       PID via GetCurrentProcessId. Otherwise give up. */
    if (proc == GetCurrentProcess()) return GetCurrentProcessId();
    SetLastError(ERROR_CALL_NOT_IMPLEMENTED);
    return 0;
}

HWND WINAPI
win98_GetConsoleWindow(void)
{
    typedef HWND (WINAPI *fn_t)(void);
    fn_t fn = (fn_t)resolve_kernel32("GetConsoleWindow");
    if (fn) return fn();

    /* Consoles exist on Win9x but the inverse-lookup API doesn't. NULL
       is the documented "no console attached" return — TUI/CUI consumers
       fall back to non-windowed behavior. */
    return NULL;
}

BOOL WINAPI
win98_GetFileSizeEx(HANDLE hFile, PLARGE_INTEGER size)
{
    typedef BOOL (WINAPI *fn_t)(HANDLE, PLARGE_INTEGER);
    fn_t fn = (fn_t)resolve_kernel32("GetFileSizeEx");
    if (fn) return fn(hFile, size);

    /* Compose from the (split low/high) GetFileSize. INVALID_FILE_SIZE
       can be a legitimate low DWORD of a >4GiB file, so the failure
       discriminator is GetLastError() != NO_ERROR. */
    DWORD hi = 0;
    DWORD lo = GetFileSize(hFile, &hi);
    if (lo == INVALID_FILE_SIZE && GetLastError() != NO_ERROR) return FALSE;
    if (size) {
        size->u.LowPart = lo;
        size->u.HighPart = (LONG)hi;
    }
    return TRUE;
}

/* === WS2_32 ============================================================== */

/* Fallback addrinfo emulation for genuine Win9x (no real getaddrinfo).
 *
 * Built on top of the Winsock-1.1 primitives gethostbyname / inet_addr /
 * getservbyname / getservbyport / inet_ntoa / gethostbyaddr — all of which
 * Win98 SE's ws2_32.dll exports. We resolve them lazily through
 * resolve_ws2_32() rather than calling them directly so consumers that
 * link libwin98compat but never call getaddrinfo (e.g. make.exe, ctags.exe)
 * don't grow new ws2_32 imports in their PE.
 *
 * Scope of the emulation, on Win9x only:
 *   - IPv4 / AF_INET only (Win9x has no IPv6 stack).
 *   - Single A-record returned. Consumers iterate ai_next but only the
 *     first node is populated; round-robin DNS failover degrades to
 *     "try the first answer".
 *   - AI_PASSIVE with a NULL node returns INADDR_ANY; with no AI_PASSIVE,
 *     NULL node returns INADDR_LOOPBACK (matches POSIX getaddrinfo).
 *   - AI_NUMERICHOST / AI_NUMERICSERV honored.
 *   - AI_CANONNAME ignored — ai_canonname stays NULL. (No shipped consumer
 *     reads it.)
 *
 * Memory: each addrinfo node and its sockaddr are separate calloc blocks;
 * win98_freeaddrinfo walks ai_next and frees both.
 */

/* ws2tcpip.h gates AI_NUMERICSERV / EAI_OVERFLOW on _WIN32_WINNT >= 0x0501;
   the shim pins 0x0400 (WIN98_TARGET_CPPFLAGS) so they may be undefined. */
#ifndef AI_NUMERICSERV
#define AI_NUMERICSERV 0x00000008
#endif
#ifndef EAI_OVERFLOW
#define EAI_OVERFLOW WSAEFAULT
#endif

/* Hand-rolled byte-swap. Avoids pulling ws2_32!htons/htonl/ntohs imports
   into every consumer that links libwin98compat (those funcs live in
   ws2_32 on Win98, and most extras tools — make.exe, ctags.exe, etc. —
   would otherwise grow a brand-new ws2_32 dependency just from being
   linked with -lwin98compat under --whole-archive). gcc -O2 recognizes
   the pattern and emits a single bswap on i686+. */
static inline unsigned short win98_htons_i(unsigned short v) {
    return (unsigned short)((v >> 8) | (v << 8));
}
static inline unsigned long win98_htonl_i(unsigned long v) {
    return ((v >> 24) & 0xffUL) | ((v >> 8) & 0xff00UL) |
           ((v << 8) & 0xff0000UL) | ((v & 0xffUL) << 24);
}

static struct addrinfo *
win98_ai_alloc(struct in_addr addr, unsigned short port,
               int socktype, int protocol)
{
    struct addrinfo *ai = (struct addrinfo *)calloc(1, sizeof(*ai));
    if (!ai) return NULL;
    struct sockaddr_in *sin = (struct sockaddr_in *)calloc(1, sizeof(*sin));
    if (!sin) { free(ai); return NULL; }
    sin->sin_family = AF_INET;
    sin->sin_port = port;
    sin->sin_addr = addr;
    ai->ai_family = AF_INET;
    ai->ai_socktype = socktype;
    ai->ai_protocol = protocol;
    ai->ai_addrlen = sizeof(*sin);
    ai->ai_addr = (struct sockaddr *)sin;
    return ai;
}

/* Decimal unsigned-short to NUL-terminated string. Max 5 digits + NUL fits
   in 6 bytes; caller passes a >=6-byte buffer. Avoids pulling in stdio. */
static void
win98_u16_to_dec(unsigned val, char *out)
{
    char tmp[6];
    int n = 0;
    if (val == 0) tmp[n++] = '0';
    while (val) { tmp[n++] = (char)('0' + (val % 10)); val /= 10; }
    int i = 0;
    while (n--) out[i++] = tmp[n];
    out[i] = '\0';
}

int WSAAPI
win98_getaddrinfo(const char *node, const char *service,
                  const struct addrinfo *hints, struct addrinfo **res)
{
    typedef int (WSAAPI *fn_t)(const char *, const char *,
                               const struct addrinfo *, struct addrinfo **);
    fn_t fn = (fn_t)resolve_ws2_32("getaddrinfo");
    if (fn) return fn(node, service, hints, res);

    if (!res) return EAI_FAIL;
    *res = NULL;
    if (!node && !service) return EAI_NONAME;

    int socktype = 0, protocol = 0, flags = 0;
    if (hints) {
        if (hints->ai_family != AF_UNSPEC && hints->ai_family != AF_INET)
            return EAI_FAMILY;
        socktype = hints->ai_socktype;
        protocol = hints->ai_protocol;
        flags = hints->ai_flags;
    }

    typedef unsigned long  (WSAAPI *inet_addr_fn)(const char *);
    typedef struct hostent *(WSAAPI *gethostbyname_fn)(const char *);
    typedef struct servent *(WSAAPI *getservbyname_fn)(const char *, const char *);

    inet_addr_fn p_inet_addr = (inet_addr_fn)resolve_ws2_32("inet_addr");
    if (!p_inet_addr) return EAI_FAIL;

    struct in_addr addr;
    if (!node) {
        addr.s_addr = (flags & AI_PASSIVE) ? win98_htonl_i(INADDR_ANY)
                                           : win98_htonl_i(INADDR_LOOPBACK);
    } else {
        unsigned long a = p_inet_addr(node);
        if (a != INADDR_NONE) {
            addr.s_addr = a;
        } else {
            if (flags & AI_NUMERICHOST) return EAI_NONAME;
            gethostbyname_fn p_ghbn =
                (gethostbyname_fn)resolve_ws2_32("gethostbyname");
            if (!p_ghbn) return EAI_FAIL;
            struct hostent *he = p_ghbn(node);
            if (!he || he->h_addrtype != AF_INET || !he->h_addr_list[0])
                return EAI_NONAME;
            memcpy(&addr, he->h_addr_list[0], sizeof(addr));
        }
    }

    unsigned short port = 0;
    if (service && *service) {
        char *end;
        unsigned long p = strtoul(service, &end, 10);
        if (*end == '\0') {
            if (p > 65535) return EAI_SERVICE;
            port = win98_htons_i((unsigned short)p);
        } else {
            if (flags & AI_NUMERICSERV) return EAI_SERVICE;
            getservbyname_fn p_gsbn =
                (getservbyname_fn)resolve_ws2_32("getservbyname");
            if (!p_gsbn) return EAI_SERVICE;
            const char *proto = (socktype == SOCK_DGRAM) ? "udp" : "tcp";
            struct servent *se = p_gsbn(service, proto);
            if (!se) return EAI_SERVICE;
            port = (unsigned short)se->s_port;  /* already net byte order */
        }
    }

    int eff_socktype = socktype ? socktype : SOCK_STREAM;
    int eff_protocol = protocol ? protocol
                                : (eff_socktype == SOCK_DGRAM ? IPPROTO_UDP
                                                              : IPPROTO_TCP);
    struct addrinfo *ai = win98_ai_alloc(addr, port, eff_socktype, eff_protocol);
    if (!ai) return EAI_MEMORY;
    *res = ai;
    return 0;
}

void WSAAPI
win98_freeaddrinfo(struct addrinfo *ai)
{
    typedef void (WSAAPI *fn_t)(struct addrinfo *);
    fn_t fn = (fn_t)resolve_ws2_32("freeaddrinfo");
    if (fn) { fn(ai); return; }
    /* Our fallback never sets ai_canonname; addrinfo and sockaddr are
       separate calloc blocks per node. */
    while (ai) {
        struct addrinfo *next = ai->ai_next;
        free(ai->ai_addr);
        free(ai);
        ai = next;
    }
}

int WSAAPI
win98_getnameinfo(const struct sockaddr *sa, socklen_t salen,
                  char *host, DWORD hostlen, char *serv, DWORD servlen,
                  int flags)
{
    typedef int (WSAAPI *fn_t)(const struct sockaddr *, socklen_t,
                               char *, DWORD, char *, DWORD, int);
    fn_t fn = (fn_t)resolve_ws2_32("getnameinfo");
    if (fn) return fn(sa, salen, host, hostlen, serv, servlen, flags);

    /* IPv4 only — Win9x has no IPv6 stack. */
    if (!sa || (size_t)salen < sizeof(struct sockaddr_in))
        return EAI_FAMILY;
    if (sa->sa_family != AF_INET) return EAI_FAMILY;
    const struct sockaddr_in *sin = (const struct sockaddr_in *)sa;

    typedef char *(WSAAPI *inet_ntoa_fn)(struct in_addr);
    typedef struct hostent *(WSAAPI *gethostbyaddr_fn)(const char *, int, int);
    typedef struct servent *(WSAAPI *getservbyport_fn)(int, const char *);

    if (host && hostlen) {
        const char *name = NULL;
        if (!(flags & NI_NUMERICHOST)) {
            gethostbyaddr_fn p_ghba =
                (gethostbyaddr_fn)resolve_ws2_32("gethostbyaddr");
            if (p_ghba) {
                struct hostent *he =
                    p_ghba((const char *)&sin->sin_addr,
                           sizeof(sin->sin_addr), AF_INET);
                if (he) name = he->h_name;
            }
        }
        if (!name) {
            if (flags & NI_NAMEREQD) return EAI_NONAME;
            inet_ntoa_fn p_ina = (inet_ntoa_fn)resolve_ws2_32("inet_ntoa");
            if (!p_ina) return EAI_FAIL;
            name = p_ina(sin->sin_addr);
            if (!name) return EAI_FAIL;
        }
        size_t n = strlen(name);
        if (n + 1 > hostlen) return EAI_OVERFLOW;
        memcpy(host, name, n + 1);
    }

    if (serv && servlen) {
        const char *name = NULL;
        char buf[8];
        if (!(flags & NI_NUMERICSERV)) {
            getservbyport_fn p_gsbp =
                (getservbyport_fn)resolve_ws2_32("getservbyport");
            if (p_gsbp) {
                const char *proto = (flags & NI_DGRAM) ? "udp" : "tcp";
                struct servent *se = p_gsbp((int)sin->sin_port, proto);
                if (se) name = se->s_name;
            }
        }
        if (!name) {
            win98_u16_to_dec((unsigned)win98_htons_i(sin->sin_port), buf);
            name = buf;
        }
        size_t n = strlen(name);
        if (n + 1 > servlen) return EAI_OVERFLOW;
        memcpy(serv, name, n + 1);
    }

    return 0;
}

/* === ADVAPI32: SystemFunction036 (RtlGenRandom) =========================== */

BOOLEAN WINAPI
win98_SystemFunction036(PVOID buf, ULONG len)
{
    typedef BOOLEAN (WINAPI *fn_t)(PVOID, ULONG);
    fn_t fn = (fn_t)resolve_advapi32("SystemFunction036");
    if (fn) return fn(buf, len);

    /* Non-cryptographic fallback — same trade-off the bcrypt.dll shim
       makes for BCryptGenRandom. Consumers calling RtlGenRandom in our
       toolset (gnulib's getrandom-via-advapi32 path, etc.) seed PRNGs;
       no key material on the line. */
    static int seeded = 0;
    if (!seeded) { srand((unsigned)GetTickCount()); seeded = 1; }
    UCHAR *p = (UCHAR *)buf;
    while (len--) *p++ = (UCHAR)(rand() & 0xff);
    return TRUE;
}

/* === MSVCRT: qsort_s ====================================================== */
/* qsort_s is exported by NT-class msvcrt builds (Vista+ KB) but absent on
   Win98's msvcrt.dll. We implement a small reentrant insertion-sort that
   threads the context through directly — no statics, safe under recursive
   calls from comparators. Insertion sort is O(n^2) but consumers needing
   qsort_s in our toolset sort small arrays; upgrade to median-of-three
   quicksort here if a profile ever flags it. */

static void
win98_qsort_s_swap(unsigned char *a, unsigned char *b, size_t size)
{
    unsigned char tmp;
    while (size--) { tmp = *a; *a++ = *b; *b++ = tmp; }
}

void __cdecl
win98_qsort_s(void *base, size_t num, size_t width,
              int (__cdecl *cmp)(void *, const void *, const void *),
              void *ctx)
{
    if (!base || num < 2 || width == 0 || !cmp) return;
    unsigned char *p = (unsigned char *)base;
    for (size_t i = 1; i < num; i++) {
        for (size_t j = i; j > 0 && cmp(ctx, p + (j - 1) * width, p + j * width) > 0; j--) {
            win98_qsort_s_swap(p + (j - 1) * width, p + j * width, width);
        }
    }
}

/* === Linker-symbol interception =========================================== */
/* For each shimmed function FOO, expose BOTH names the linker can reach:
 *
 *   __imp__FOO@N  in .rdata    — IAT slot for callers using __declspec(dllimport)
 *                                (i.e. anyone including windows.h / ws2tcpip.h /
 *                                <search.h> with _CRTIMP wired to dllimport).
 *                                Compiler emits `call *__imp__FOO@N` and the
 *                                indirect call lands in our wrapper.
 *
 *   _FOO@N        in .text     — direct-call thunk for callers without dllimport.
 *                                (e.g. busybox's libbb/yescrypt declares
 *                                SystemFunction036 by hand, so gcc emits
 *                                `call _SystemFunction036@8`.) Without our
 *                                thunk, the linker pulls advapi32's short
 *                                import-library member to resolve _FOO@N —
 *                                and that .o ALSO defines __imp__FOO@N in
 *                                .idata$5, colliding with ours. Defining
 *                                _FOO@N ourselves keeps advapi32 out of it.
 *
 * Decoration rules (i686 mingw):
 *   stdcall (WINAPI / WSAAPI):  symbol = _<name>@<argbytes>
 *                               IAT slot = __imp__<name>@<argbytes>
 *   cdecl:                      symbol = _<name>
 *                               IAT slot = __imp__<name>
 *
 * argbytes = sizeof-each-arg rounded up to 4, summed. All our shimmed args
 * are pointer-or-DWORD sized, so it's 4 * argcount.
 *
 * Consumers link with -lwin98compat in WIN98_COMPAT_LDFLAGS, which uses
 * -Wl,--whole-archive so every symbol below is pulled in unconditionally
 * at the point of -lwin98compat in the link line — beating the system
 * import libraries to definition regardless of where the autotools rule
 * positions LDFLAGS.
 *
 * No __i386__ guard: build-win98-compat.sh always invokes the i686 cross
 * gcc. A hypothetical x86_64 build would fail loudly at assemble time on
 * the stdcall @<argbytes> decorations below, which is the desired behavior.
 */
__asm__(
    /* --- IAT slots (.rdata) --------------------------------------------- */
    ".section .rdata, \"dr\"\n"
    ".p2align 2\n"

    /* kernel32 */
    ".globl __imp__GetFinalPathNameByHandleA@16\n"
    "__imp__GetFinalPathNameByHandleA@16:\n"
    "\t.long _win98_GetFinalPathNameByHandleA@16\n"
    ".globl __imp__GetSystemWow64DirectoryA@8\n"
    "__imp__GetSystemWow64DirectoryA@8:\n"
    "\t.long _win98_GetSystemWow64DirectoryA@8\n"
    ".globl __imp__GetLogicalProcessorInformation@8\n"
    "__imp__GetLogicalProcessorInformation@8:\n"
    "\t.long _win98_GetLogicalProcessorInformation@8\n"
    ".globl __imp__GetSystemTimePreciseAsFileTime@4\n"
    "__imp__GetSystemTimePreciseAsFileTime@4:\n"
    "\t.long _win98_GetSystemTimePreciseAsFileTime@4\n"
    ".globl __imp__IsWow64Process@8\n"
    "__imp__IsWow64Process@8:\n"
    "\t.long _win98_IsWow64Process@8\n"
    ".globl __imp__GetProcessId@4\n"
    "__imp__GetProcessId@4:\n"
    "\t.long _win98_GetProcessId@4\n"
    ".globl __imp__GetConsoleWindow@0\n"
    "__imp__GetConsoleWindow@0:\n"
    "\t.long _win98_GetConsoleWindow@0\n"
    ".globl __imp__GetFileSizeEx@8\n"
    "__imp__GetFileSizeEx@8:\n"
    "\t.long _win98_GetFileSizeEx@8\n"

    /* ws2_32 */
    ".globl __imp__getaddrinfo@16\n"
    "__imp__getaddrinfo@16:\n"
    "\t.long _win98_getaddrinfo@16\n"
    ".globl __imp__freeaddrinfo@4\n"
    "__imp__freeaddrinfo@4:\n"
    "\t.long _win98_freeaddrinfo@4\n"
    ".globl __imp__getnameinfo@28\n"
    "__imp__getnameinfo@28:\n"
    "\t.long _win98_getnameinfo@28\n"

    /* advapi32 */
    ".globl __imp__SystemFunction036@8\n"
    "__imp__SystemFunction036@8:\n"
    "\t.long _win98_SystemFunction036@8\n"

    /* msvcrt */
    ".globl __imp__qsort_s\n"
    "__imp__qsort_s:\n"
    "\t.long _win98_qsort_s\n"

    /* --- Direct-call thunks (.text) ------------------------------------- */
    ".text\n"

    /* kernel32 */
    ".globl _GetFinalPathNameByHandleA@16\n"
    "_GetFinalPathNameByHandleA@16:\n"
    "\tjmp _win98_GetFinalPathNameByHandleA@16\n"
    ".globl _GetSystemWow64DirectoryA@8\n"
    "_GetSystemWow64DirectoryA@8:\n"
    "\tjmp _win98_GetSystemWow64DirectoryA@8\n"
    ".globl _GetLogicalProcessorInformation@8\n"
    "_GetLogicalProcessorInformation@8:\n"
    "\tjmp _win98_GetLogicalProcessorInformation@8\n"
    ".globl _GetSystemTimePreciseAsFileTime@4\n"
    "_GetSystemTimePreciseAsFileTime@4:\n"
    "\tjmp _win98_GetSystemTimePreciseAsFileTime@4\n"
    ".globl _IsWow64Process@8\n"
    "_IsWow64Process@8:\n"
    "\tjmp _win98_IsWow64Process@8\n"
    ".globl _GetProcessId@4\n"
    "_GetProcessId@4:\n"
    "\tjmp _win98_GetProcessId@4\n"
    ".globl _GetConsoleWindow@0\n"
    "_GetConsoleWindow@0:\n"
    "\tjmp _win98_GetConsoleWindow@0\n"
    ".globl _GetFileSizeEx@8\n"
    "_GetFileSizeEx@8:\n"
    "\tjmp _win98_GetFileSizeEx@8\n"

    /* ws2_32 */
    ".globl _getaddrinfo@16\n"
    "_getaddrinfo@16:\n"
    "\tjmp _win98_getaddrinfo@16\n"
    ".globl _freeaddrinfo@4\n"
    "_freeaddrinfo@4:\n"
    "\tjmp _win98_freeaddrinfo@4\n"
    ".globl _getnameinfo@28\n"
    "_getnameinfo@28:\n"
    "\tjmp _win98_getnameinfo@28\n"

    /* advapi32 */
    ".globl _SystemFunction036@8\n"
    "_SystemFunction036@8:\n"
    "\tjmp _win98_SystemFunction036@8\n"

    /* msvcrt */
    ".globl _qsort_s\n"
    "_qsort_s:\n"
    "\tjmp _win98_qsort_s\n"
);
