/*
 * sockdiag - Win9x Winsock socket-creation diagnostic
 *
 * Built as a Win98-clean i686 executable; msvcrt + kernel32 + ws2_32 only.
 * No win98-compat shim, no busybox linkage — we want the raw Win9x Winsock
 * behavior of each probed variant.
 *
 * Why this exists:
 *   On real Win98 SE, busybox-w32's wget fails at socket creation with
 *   "socket: invalid argument" (WSAEINVAL). The call site is
 *   busybox-w32/win32/net.c::mingw_socket which does:
 *     s = WSASocket(domain, type, protocol, NULL, 0, 0);
 *   passing dwFlags=0. MS docs say "with g=0 and dwFlags=0 this behaves like
 *   BSD socket()" — but that's NT-class behavior. On Win9x, WSASocket may
 *   reject dwFlags=0 (some sources say WSA_FLAG_OVERLAPPED is mandatory) or
 *   reject protocol=0 + SOCK_STREAM without auto-resolving to IPPROTO_TCP.
 *   This diag tries all four (variant, protocol) combinations and reports
 *   which succeed, so the busybox patch can target the actually-working form.
 *
 * Output: written to a fixed log file (default C:\SOCKDIAG.LOG, override via
 * single positional arg). Pattern matches consdiag.exe — see its header
 * comment for why we don't rely on stdout redirection on Win9x.
 *
 * Usage:
 *   from command.com: sockdiag.exe                 (default log path)
 *                     sockdiag.exe c:\foo.log      (custom path)
 *   from busybox sh:  /opt/extras/bin/sockdiag.exe
 */

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

#define DEFAULT_LOG_PATH "C:\\SOCKDIAG.LOG"

static FILE *g_log = NULL;

static void plog(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    if (g_log) { vfprintf(g_log, fmt, ap); fflush(g_log); }
    va_end(ap);
}

static const char *platform_str(DWORD p)
{
    switch (p) {
    case VER_PLATFORM_WIN32_WINDOWS: return "Win9x";
    case VER_PLATFORM_WIN32_NT:      return "NT";
    case VER_PLATFORM_WIN32s:        return "Win32s";
    default:                         return "unknown";
    }
}

/* One socket-creation variant. */
struct variant {
    const char *label;
    SOCKET (*make)(void);
};

static SOCKET v_socket_proto0(void) {
    return socket(AF_INET, SOCK_STREAM, 0);
}
static SOCKET v_socket_proto_tcp(void) {
    return socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
}
static SOCKET v_wsasocket_proto0_flag0(void) {
    return WSASocket(AF_INET, SOCK_STREAM, 0, NULL, 0, 0);
}
static SOCKET v_wsasocket_proto_tcp_flag0(void) {
    return WSASocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0, 0);
}
static SOCKET v_wsasocket_proto0_overlapped(void) {
    return WSASocket(AF_INET, SOCK_STREAM, 0, NULL, 0, WSA_FLAG_OVERLAPPED);
}
static SOCKET v_wsasocket_proto_tcp_overlapped(void) {
    return WSASocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0, WSA_FLAG_OVERLAPPED);
}

static struct variant VARIANTS[] = {
    {"A: socket(AF_INET, SOCK_STREAM, 0)                                ", v_socket_proto0},
    {"B: socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)                      ", v_socket_proto_tcp},
    {"C: WSASocket(AF_INET, SOCK_STREAM, 0, NULL, 0, 0)                 ", v_wsasocket_proto0_flag0},
    {"D: WSASocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0, 0)       ", v_wsasocket_proto_tcp_flag0},
    {"E: WSASocket(AF_INET, SOCK_STREAM, 0, NULL, 0, WSA_FLAG_OVERLAPPED)", v_wsasocket_proto0_overlapped},
    {"F: WSASocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0, OVERLAPPED)", v_wsasocket_proto_tcp_overlapped},
};
#define NUM_VARIANTS (sizeof(VARIANTS)/sizeof(VARIANTS[0]))

/* Best-effort error-code → name. Subset of WSAE* codes we care about. */
static const char *wsa_err_name(int e)
{
    switch (e) {
    case 0:                       return "no error";
    case WSAEINTR:                return "WSAEINTR";
    case WSAEBADF:                return "WSAEBADF";
    case WSAEACCES:               return "WSAEACCES";
    case WSAEFAULT:               return "WSAEFAULT";
    case WSAEINVAL:               return "WSAEINVAL";
    case WSAEMFILE:               return "WSAEMFILE";
    case WSAEAFNOSUPPORT:         return "WSAEAFNOSUPPORT";
    case WSAEPROTONOSUPPORT:      return "WSAEPROTONOSUPPORT";
    case WSAEPROTOTYPE:           return "WSAEPROTOTYPE";
    case WSAESOCKTNOSUPPORT:      return "WSAESOCKTNOSUPPORT";
    case WSANOTINITIALISED:       return "WSANOTINITIALISED";
    case WSAVERNOTSUPPORTED:      return "WSAVERNOTSUPPORTED";
    default:                      return "(other)";
    }
}

int main(int argc, char **argv)
{
    const char *log_path = (argc > 1) ? argv[1] : DEFAULT_LOG_PATH;
    g_log = fopen(log_path, "w");
    if (!g_log) {
        fprintf(stderr, "sockdiag: cannot open log file %s\n", log_path);
        return 1;
    }

    plog("=== sockdiag ===\nlog: %s\n\n", log_path);

    /* --- Section 1: OS detection --- */
    OSVERSIONINFO ovi; ovi.dwOSVersionInfoSize = sizeof(ovi);
    if (GetVersionEx(&ovi)) {
        plog("OS: platform=%s (%lu) version=%lu.%lu build=%lu\n",
             platform_str(ovi.dwPlatformId),
             (unsigned long)ovi.dwPlatformId,
             (unsigned long)ovi.dwMajorVersion,
             (unsigned long)ovi.dwMinorVersion,
             (unsigned long)ovi.dwBuildNumber);
        if (ovi.szCSDVersion[0]) plog("OS CSD: %s\n", ovi.szCSDVersion);
    } else {
        plog("OS: GetVersionEx FAILED (gle=%lu)\n", (unsigned long)GetLastError());
    }
    plog("\n");

    /* --- Section 2: WSAStartup --- */
    WSADATA wsa;
    int rc = WSAStartup(MAKEWORD(2,2), &wsa);
    if (rc != 0) {
        plog("WSAStartup(2.2) FAILED rc=%d wsaerr=%d (%s)\n",
             rc, WSAGetLastError(), wsa_err_name(WSAGetLastError()));
        /* Try 1.1 as fallback for diagnostic purposes */
        rc = WSAStartup(MAKEWORD(1,1), &wsa);
        if (rc != 0) {
            plog("WSAStartup(1.1) ALSO FAILED rc=%d — Winsock unusable\n", rc);
            fclose(g_log);
            return 2;
        }
        plog("WSAStartup(1.1) succeeded as fallback\n");
    }
    plog("Winsock: requested=2.2 negotiated=%u.%u sysstatus=\"%s\" desc=\"%s\"\n",
         (unsigned)LOBYTE(wsa.wVersion), (unsigned)HIBYTE(wsa.wVersion),
         wsa.szSystemStatus, wsa.szDescription);
    plog("\n");

    /* --- Section 3: sanity-check the resolution primitives --- */
    plog("Primitives:\n");
    unsigned long ia = inet_addr("1.2.3.4");
    plog("  inet_addr(\"1.2.3.4\")   = 0x%08lx %s\n",
         (unsigned long)ia, ia == INADDR_NONE ? "(INADDR_NONE)" : "(ok)");
    struct hostent *he = gethostbyname("localhost");
    if (he && he->h_addr_list[0]) {
        unsigned char *b = (unsigned char *)he->h_addr_list[0];
        plog("  gethostbyname(\"localhost\")  → %u.%u.%u.%u (ok)\n",
             b[0], b[1], b[2], b[3]);
    } else {
        plog("  gethostbyname(\"localhost\")  FAILED wsaerr=%d (%s)\n",
             WSAGetLastError(), wsa_err_name(WSAGetLastError()));
    }
    plog("\n");

    /* --- Section 4: socket-creation variant probe --- */
    plog("Socket-creation variants (all AF_INET / SOCK_STREAM):\n");
    int first_success = -1;
    size_t i;
    for (i = 0; i < NUM_VARIANTS; i++) {
        SOCKET s = VARIANTS[i].make();
        if (s == INVALID_SOCKET) {
            int e = WSAGetLastError();
            plog("  [FAIL] %s  wsaerr=%d (%s)\n",
                 VARIANTS[i].label, e, wsa_err_name(e));
        } else {
            plog("  [ OK ] %s\n", VARIANTS[i].label);
            if (first_success < 0) first_success = (int)i;
            closesocket(s);
        }
    }
    plog("\n");

    /* --- Section 5: connect test using the first working variant --- */
    if (first_success >= 0) {
        plog("Connect test (using variant %c on 1.1.1.1:53 — Cloudflare DNS-over-TCP):\n",
             'A' + first_success);
        SOCKET s = VARIANTS[first_success].make();
        if (s == INVALID_SOCKET) {
            plog("  unexpected re-creation failure wsaerr=%d\n", WSAGetLastError());
        } else {
            struct sockaddr_in sa; memset(&sa, 0, sizeof(sa));
            sa.sin_family = AF_INET;
            sa.sin_port = htons(53);
            sa.sin_addr.s_addr = inet_addr("1.1.1.1");
            int crc = connect(s, (struct sockaddr *)&sa, sizeof(sa));
            if (crc == 0) {
                plog("  connect() OK — socket-layer connectivity to remote works\n");
            } else {
                int e = WSAGetLastError();
                plog("  connect() rc=%d wsaerr=%d (%s)\n",
                     crc, e, wsa_err_name(e));
                plog("  (timeout / refused / network down all show here — not necessarily a bug)\n");
            }
            closesocket(s);
        }
        plog("\n");
    } else {
        plog("No working socket variant — connect test skipped.\n\n");
    }

    /* --- Section 6: summary --- */
    plog("Summary:\n");
    if (first_success < 0) {
        plog("  All %u variants failed. Winsock socket creation broken on this host.\n",
             (unsigned)NUM_VARIANTS);
    } else {
        plog("  First working variant: %c\n", 'A' + first_success);
        plog("  Use this to drive the busybox-w32 mingw_socket patch.\n");
    }

    WSACleanup();
    fclose(g_log);
    return first_success < 0 ? 3 : 0;
}
