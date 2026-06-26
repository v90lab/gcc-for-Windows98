/*
 * httpdiag - Tiny TCP listener for verifying inbound connectivity on Win9x.
 *
 * Standalone Win98-clean i686 executable; msvcrt + kernel32 + ws2_32 only.
 * Winsock 1.1 primitives only (socket/bind/listen/accept/recv/send/
 * closesocket/inet_ntoa) - no getaddrinfo, no threads, no fd-indirection.
 * We keep the raw SOCKET throughout to sidestep the msvcrt!_open_osfhandle
 * quirk documented in sockdiag.c (Win9x rejects socket handles in the fd
 * table - the cause of busybox-w32 wget's "socket: invalid argument").
 *
 * Why this exists:
 *   Verifying inbound TCP from another box without any working networking
 *   tool on the Win98 SE side (no ping/wget/curl/telnet that you trust).
 *   Run this on Win98, point a browser at http://<win98-ip>:8080/ from
 *   anywhere on the LAN, and the page tells you TCP is up. Each connection
 *   logs the peer addr + first request line to stdout.
 *
 * Usage:
 *   from command.com: httpdiag.exe          (listens on 0.0.0.0:8080)
 *                     httpdiag.exe 80       (listens on 0.0.0.0:80)
 *   from busybox sh:  /opt/extras/bin/httpdiag.exe 8080
 *   Ctrl-Break to quit.
 *
 * Not part of EXTRAS_STEPS - built on demand via build-httpdiag.sh.
 */

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DEFAULT_PORT 8080
#define BACKLOG      5
#define RECV_BUF     2048

static const char HTTP_BODY[] =
    "<!DOCTYPE html>\n"
    "<html><head><title>Hello from Win98</title></head>\n"
    "<body><h1>Hello from Win98</h1>\n"
    "<p>If you can read this, TCP is doing its job.</p>\n"
    "</body></html>\n";

static void log_wsa(const char *what)
{
    fprintf(stdout, "httpdiag: %s failed wsaerr=%d\n", what, WSAGetLastError());
    fflush(stdout);
}

int main(int argc, char **argv)
{
    int port = DEFAULT_PORT;
    if (argc > 1) {
        int p = atoi(argv[1]);
        if (p > 0 && p < 65536) {
            port = p;
        } else {
            fprintf(stdout, "httpdiag: bad port \"%s\", using %d\n",
                    argv[1], DEFAULT_PORT);
        }
    }

    /* Unbuffered stdout so log lines appear at the console immediately
     * (msvcrt's _IOLBF is treated like _IOFBF for files, so without this
     * piping httpdiag.exe > log.txt would batch lines indefinitely). */
    setvbuf(stdout, NULL, _IONBF, 0);

    WSADATA wsa;
    if (WSAStartup(MAKEWORD(1, 1), &wsa) != 0) {
        fprintf(stdout, "httpdiag: WSAStartup(1.1) failed (gle=%lu)\n",
                (unsigned long)GetLastError());
        return 1;
    }

    SOCKET lsock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (lsock == INVALID_SOCKET) {
        log_wsa("socket");
        WSACleanup();
        return 1;
    }

    /* SO_REUSEADDR so a quick restart after Ctrl-Break doesn't hit TIME_WAIT. */
    BOOL yes = TRUE;
    setsockopt(lsock, SOL_SOCKET, SO_REUSEADDR,
               (const char *)&yes, sizeof(yes));

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((unsigned short)port);
    sa.sin_addr.s_addr = INADDR_ANY;

    if (bind(lsock, (struct sockaddr *)&sa, sizeof(sa)) == SOCKET_ERROR) {
        log_wsa("bind");
        closesocket(lsock);
        WSACleanup();
        return 1;
    }

    if (listen(lsock, BACKLOG) == SOCKET_ERROR) {
        log_wsa("listen");
        closesocket(lsock);
        WSACleanup();
        return 1;
    }

    fprintf(stdout, "httpdiag: listening on 0.0.0.0:%d (Ctrl-Break to quit)\n",
            port);

    for (;;) {
        struct sockaddr_in peer;
        int peer_len = sizeof(peer);
        SOCKET c = accept(lsock, (struct sockaddr *)&peer, &peer_len);
        if (c == INVALID_SOCKET) {
            log_wsa("accept");
            continue;
        }

        /* Read whatever the client sent in one recv. Browsers/curl send the
         * full request line + headers in one packet for a short GET, so this
         * suffices for logging the first line. We don't actually parse it. */
        char buf[RECV_BUF];
        int n = recv(c, buf, sizeof(buf) - 1, 0);
        char first_line[256];
        first_line[0] = 0;
        if (n > 0) {
            buf[n] = 0;
            int i;
            int cap = (int)sizeof(first_line) - 1;
            for (i = 0; i < cap && buf[i] && buf[i] != '\r' && buf[i] != '\n'; i++) {
                first_line[i] = buf[i];
            }
            first_line[i] = 0;
        }
        if (first_line[0] == 0) {
            strcpy(first_line, "(no data)");
        }

        unsigned char *pa = (unsigned char *)&peer.sin_addr.s_addr;
        fprintf(stdout, "[%u.%u.%u.%u:%u] %s\n",
                pa[0], pa[1], pa[2], pa[3],
                (unsigned)ntohs(peer.sin_port),
                first_line);

        char hdr[256];
        int hdr_len = sprintf(hdr,
            "HTTP/1.0 200 OK\r\n"
            "Content-Type: text/html\r\n"
            "Content-Length: %u\r\n"
            "Connection: close\r\n"
            "\r\n",
            (unsigned)(sizeof(HTTP_BODY) - 1));
        send(c, hdr, hdr_len, 0);
        send(c, HTTP_BODY, (int)(sizeof(HTTP_BODY) - 1), 0);

        /* Half-close write side so the client sees clean EOF before our
         * closesocket - matters for HTTP/1.0 Connection: close semantics. */
        shutdown(c, SD_SEND);
        closesocket(c);
    }

    /* unreachable */
}
