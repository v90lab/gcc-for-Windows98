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
#include <errno.h>
#include <io.h>      /* _open_osfhandle / _get_osfhandle / _close */
#include <fcntl.h>   /* O_RDWR / O_BINARY */

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
    /*
     * For each variant: create the socket, then try wrapping it as a POSIX fd
     * via msvcrt's _open_osfhandle (this is what busybox-w32's mingw_socket
     * does after WSASocket succeeds). On Win9x the msvcrt fd table may reject
     * socket handles outright — which would surface in xsocket as "socket:
     * Invalid argument" with errno=EINVAL=22 because mingw_socket prints its
     * "unable to make a socket file descriptor" message via bb_error_msg
     * (line-buffered stderr) and then returns -1 with errno set from the
     * _open_osfhandle failure path.
     */
    plog("Socket-creation variants (all AF_INET / SOCK_STREAM):\n");
    int first_success = -1;
    int first_fd_success = -1;
    size_t i;
    for (i = 0; i < NUM_VARIANTS; i++) {
        SOCKET s = VARIANTS[i].make();
        if (s == INVALID_SOCKET) {
            int e = WSAGetLastError();
            plog("  [FAIL] %s  wsaerr=%d (%s)\n",
                 VARIANTS[i].label, e, wsa_err_name(e));
            continue;
        }
        plog("  [ OK ] %s  (SOCKET=0x%lx)\n",
             VARIANTS[i].label, (unsigned long)s);
        if (first_success < 0) first_success = (int)i;

        /* osfhandle round-trip probe */
        errno = 0;
        int fd = _open_osfhandle((intptr_t)s, O_RDWR | O_BINARY);
        if (fd < 0) {
            int saved_errno = errno;
            plog("         _open_osfhandle: FAILED fd=-1 errno=%d (%s)\n",
                 saved_errno, strerror(saved_errno));
            closesocket(s);
            continue;
        }
        plog("         _open_osfhandle: fd=%d\n", fd);

        intptr_t rt = _get_osfhandle(fd);
        if (rt == (intptr_t)s) {
            plog("         _get_osfhandle(%d): roundtrip ok (matches SOCKET)\n", fd);
        } else if (rt == -1) {
            plog("         _get_osfhandle(%d): FAILED errno=%d (%s)\n",
                 fd, errno, strerror(errno));
        } else {
            plog("         _get_osfhandle(%d): MISMATCH got 0x%lx, want 0x%lx\n",
                 fd, (unsigned long)rt, (unsigned long)s);
        }

        if (first_fd_success < 0) first_fd_success = (int)i;
        /*
         * Once _open_osfhandle has taken ownership we'd normally _close(fd),
         * but on Win9x _close on a socket-backed fd may not run closesocket
         * properly. closesocket() the raw SOCKET — best-effort, accepts that
         * the fd slot may leak for the rest of this short-lived process.
         */
        closesocket(s);
    }
    plog("\n");

    /* --- Section 5: connect + send/recv test --- */
    /*
     * Uses the raw SOCKET (no fd indirection). If _open_osfhandle worked for
     * any variant, also re-run the I/O test against an fd-wrapped socket so
     * we know mingw_send / mingw_recv's _get_osfhandle path is sound.
     * Target: 1.1.1.1:80 — sending a 1-byte garbage payload, expect either
     * an HTTP error response, a connection close, or EHOSTUNREACH. Any
     * non-FAULT result confirms send/recv work.
     */
    if (first_success >= 0) {
        plog("Connect+I/O test (variant %c on 1.1.1.1:80, raw SOCKET):\n",
             'A' + first_success);
        SOCKET s = VARIANTS[first_success].make();
        if (s == INVALID_SOCKET) {
            plog("  unexpected re-creation failure wsaerr=%d\n", WSAGetLastError());
        } else {
            struct sockaddr_in sa; memset(&sa, 0, sizeof(sa));
            sa.sin_family = AF_INET;
            sa.sin_port = htons(80);
            sa.sin_addr.s_addr = inet_addr("1.1.1.1");
            int crc = connect(s, (struct sockaddr *)&sa, sizeof(sa));
            if (crc != 0) {
                int e = WSAGetLastError();
                plog("  connect() rc=%d wsaerr=%d (%s)\n",
                     crc, e, wsa_err_name(e));
                plog("  (timeout / refused / network down all show here)\n");
            } else {
                plog("  connect() OK\n");
                const char *req = "GET / HTTP/1.0\r\nHost: 1.1.1.1\r\n\r\n";
                int slen = (int)strlen(req);
                int sent = send(s, req, slen, 0);
                if (sent < 0) {
                    int e = WSAGetLastError();
                    plog("  send() rc=%d wsaerr=%d (%s)\n", sent, e, wsa_err_name(e));
                } else {
                    plog("  send() sent=%d/%d bytes\n", sent, slen);
                    char buf[128];
                    int rcv = recv(s, buf, sizeof(buf) - 1, 0);
                    if (rcv < 0) {
                        int e = WSAGetLastError();
                        plog("  recv() rc=%d wsaerr=%d (%s)\n", rcv, e, wsa_err_name(e));
                    } else if (rcv == 0) {
                        plog("  recv() returned 0 (peer closed)\n");
                    } else {
                        /* show first line only */
                        buf[rcv] = 0;
                        char *eol = strchr(buf, '\n');
                        if (eol) *eol = 0;
                        plog("  recv() got %d bytes, first line: %s\n", rcv, buf);
                    }
                }
            }
            closesocket(s);
        }
        plog("\n");

        /*
         * If any variant produced a usable fd via _open_osfhandle, re-run the
         * connect path through _get_osfhandle to confirm the fd-indirection
         * mingw_socket relies on actually round-trips behaviorally — not just
         * value-wise (Section 4 only checked value equality).
         */
        if (first_fd_success >= 0) {
            plog("FD-indirection I/O test (variant %c via _open_osfhandle / _get_osfhandle):\n",
                 'A' + first_fd_success);
            SOCKET s2 = VARIANTS[first_fd_success].make();
            if (s2 == INVALID_SOCKET) {
                plog("  unexpected re-creation failure wsaerr=%d\n", WSAGetLastError());
            } else {
                errno = 0;
                int fd = _open_osfhandle((intptr_t)s2, O_RDWR | O_BINARY);
                if (fd < 0) {
                    plog("  _open_osfhandle FAILED errno=%d (%s)\n", errno, strerror(errno));
                    closesocket(s2);
                } else {
                    SOCKET rt = (SOCKET)_get_osfhandle(fd);
                    struct sockaddr_in sa; memset(&sa, 0, sizeof(sa));
                    sa.sin_family = AF_INET;
                    sa.sin_port = htons(80);
                    sa.sin_addr.s_addr = inet_addr("1.1.1.1");
                    int crc = connect(rt, (struct sockaddr *)&sa, sizeof(sa));
                    if (crc != 0) {
                        int e = WSAGetLastError();
                        plog("  connect(via_fd) rc=%d wsaerr=%d (%s)\n", crc, e, wsa_err_name(e));
                    } else {
                        plog("  connect(via_fd) OK — fd-indirection is behaviorally sound\n");
                    }
                    closesocket(s2);
                }
            }
            plog("\n");
        } else {
            plog("FD-indirection I/O test: skipped (no variant produced a valid fd)\n\n");
        }
    } else {
        plog("No working socket variant — connect test skipped.\n\n");
    }

    /* --- Section 6: summary --- */
    plog("Summary:\n");
    if (first_success < 0) {
        plog("  All %u variants failed. Winsock socket creation broken on this host.\n",
             (unsigned)NUM_VARIANTS);
    } else {
        plog("  First working socket variant:    %c\n", 'A' + first_success);
        if (first_fd_success >= 0) {
            plog("  First fd-wrappable variant:      %c\n", 'A' + first_fd_success);
            plog("  → socket creation AND _open_osfhandle work on this host;\n");
            plog("    the busybox-w32 wget bug is somewhere ELSE (look upstream\n");
            plog("    of mingw_socket — maybe in mingw_recv, _get_osfhandle in\n");
            plog("    a different context, or wget's own setsockopt path).\n");
        } else {
            plog("  No variant produced a usable fd via _open_osfhandle.\n");
            plog("  → _open_osfhandle rejects socket handles on this Win9x host.\n");
            plog("    mingw_socket's fd-wrapping is the busybox-w32 wget bug.\n");
            plog("    Fix: maintain a side-table mapping fake-fd → SOCKET on Win9x\n");
            plog("    instead of relying on msvcrt's fd table.\n");
        }
    }

    WSACleanup();
    fclose(g_log);
    return first_success < 0 ? 3 : 0;
}
