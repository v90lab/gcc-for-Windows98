#!/usr/bin/env python3
"""Generate 0001-mingw-hdep-poll-console-input-on-win9x.patch.

Runs inside the toolchain-builder container. Reads the upstream
gdb/mingw-hdep.c, splices in a polling fallback used on Win9x where
WaitForMultipleObjects rejects console input handles, then emits a
unified diff to stdout. The maintainer captures it as a patch.

This script is checked in alongside the patch itself so the patch
can be regenerated whenever upstream context shifts. It is NOT
invoked by the build — only the resulting .patch is applied.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

SRC = Path("/work/src/binutils-gdb/gdb/mingw-hdep.c")

ANCHOR_BEFORE_HELPERS = "windows_get_absolute_argv0 (const char *argv0)\n{\n  char full_name[PATH_MAX];\n\n  if (GetModuleFileName (NULL, full_name, PATH_MAX))\n    return xstrdup (full_name);\n  return xstrdup (argv0);\n}\n\n"

HELPERS = """/* Returns nonzero iff the host is a Win9x kernel (95/98/ME).  Cached
   after the first call.  Win9x's WaitForMultipleObjects rejects
   console input handles as wait objects (an NT 4+ feature), so the
   gdb_select code below has to take a polling fallback path on
   these hosts -- see gdb_select_win9x.  Without this fallback the
   event loop hits WAIT_FAILED, prints "select: No Error." (errno is
   never set, so strerror(0) renders unhelpfully), and spins
   forever.  */

static int
gdb_select_is_win9x (void)
{
  static int cached = -1;

  if (cached == -1)
    {
      OSVERSIONINFO osvi;
      memset (&osvi, 0, sizeof (osvi));
      osvi.dwOSVersionInfoSize = sizeof (osvi);
      if (GetVersionEx (&osvi)
\t  && osvi.dwPlatformId == VER_PLATFORM_WIN32_WINDOWS)
\tcached = 1;
      else
\tcached = 0;
    }

  return cached;
}

/* Polling fallback used by gdb_select on Win9x in place of
   WaitForMultipleObjects.  Loops at WIN98_POLL_INTERVAL_MS ticks;
   per registered read fd it uses PeekConsoleInput when the
   underlying handle is a console input handle (draining
   non-keypress noise so the input queue doesn't accumulate junk
   readline can't consume), and WaitForSingleObject with timeout=0
   otherwise.  Bits in EXCEPTFDS are cleared on return -- exception
   fds never fire on the console handles gdb actually exercises,
   matching the never_handle behavior of the NT path.  */

#define WIN98_POLL_INTERVAL_MS 20

static int
gdb_select_win9x (int n, fd_set *readfds, fd_set *writefds,
\t\t  fd_set *exceptfds, struct timeval *timeout)
{
  HANDLE handles[MAXIMUM_WAIT_OBJECTS];
  int handle_fds[MAXIMUM_WAIT_OBJECTS];
  size_t num_handles = 0;
  struct serial *scbs[MAXIMUM_WAIT_OBJECTS];
  size_t num_scbs = 0;
  fd_set ready_read;
  DWORD remaining_ms;
  int num_ready = 0;
  int fd;
  size_t i;

  FD_ZERO (&ready_read);

  for (fd = 0; fd < n; ++fd)
    {
      HANDLE read = NULL, except_h = NULL;
      struct serial *scb;

      gdb_assert (!writefds || !FD_ISSET (fd, writefds));

      if ((!readfds || !FD_ISSET (fd, readfds))
\t  && (!exceptfds || !FD_ISSET (fd, exceptfds)))
\tcontinue;

      scb = serial_for_fd (fd);
      if (scb)
\t{
\t  serial_wait_handle (scb, &read, &except_h);
\t  scbs[num_scbs++] = scb;
\t}
      if (read == NULL)
\tread = (HANDLE) _get_osfhandle (fd);

      if (readfds && FD_ISSET (fd, readfds))
\t{
\t  gdb_assert (num_handles < MAXIMUM_WAIT_OBJECTS);
\t  handles[num_handles] = read;
\t  handle_fds[num_handles] = fd;
\t  num_handles++;
\t}
    }

  if (timeout != NULL)
    remaining_ms
      = (DWORD) (timeout->tv_sec * 1000 + timeout->tv_usec / 1000);
  else
    remaining_ms = INFINITE;

  while (1)
    {
      DWORD slept;

      for (i = 0; i < num_handles; ++i)
\t{
\t  HANDLE h = handles[i];
\t  int fdh = handle_fds[i];
\t  DWORD pending = 0;

\t  if (FD_ISSET (fdh, &ready_read))
\t    continue;

\t  if (GetNumberOfConsoleInputEvents (h, &pending))
\t    {
\t      INPUT_RECORD ir;
\t      DWORD got;

\t      while (pending > 0
\t\t     && PeekConsoleInput (h, &ir, 1, &got)
\t\t     && got == 1)
\t\t{
\t\t  if (ir.EventType == KEY_EVENT
\t\t      && ir.Event.KeyEvent.bKeyDown
\t\t      && ir.Event.KeyEvent.uChar.AsciiChar != 0)
\t\t    {
\t\t      FD_SET (fdh, &ready_read);
\t\t      num_ready++;
\t\t      break;
\t\t    }
\t\t  ReadConsoleInput (h, &ir, 1, &got);
\t\t  if (!GetNumberOfConsoleInputEvents (h, &pending))
\t\t    break;
\t\t}
\t    }
\t  else if (WaitForSingleObject (h, 0) == WAIT_OBJECT_0)
\t    {
\t      FD_SET (fdh, &ready_read);
\t      num_ready++;
\t    }
\t}

      if (num_ready > 0)
\tbreak;
      if (remaining_ms == 0)
\tbreak;

      slept = (remaining_ms == INFINITE
\t       || remaining_ms > WIN98_POLL_INTERVAL_MS)
\t\t? WIN98_POLL_INTERVAL_MS : remaining_ms;
      Sleep (slept);
      if (remaining_ms != INFINITE)
\tremaining_ms -= slept;
    }

  for (i = 0; i < num_scbs; ++i)
    serial_done_wait_handle (scbs[i]);

  if (readfds)
    for (fd = 0; fd < n; ++fd)
      if (FD_ISSET (fd, readfds) && !FD_ISSET (fd, &ready_read))
\tFD_CLR (fd, readfds);
  if (exceptfds)
    FD_ZERO (exceptfds);

  return num_ready;
}

"""

ANCHOR_DISPATCH_BEFORE = "      return 0;\n    }\n\n  num_ready = 0;\n"

DISPATCH = """      return 0;
    }

  /* Win9x's WaitForMultipleObjects rejects console input handles,
     leaving the event loop spinning on WAIT_FAILED.  Dispatch to the
     polling fallback above.  */
  if (gdb_select_is_win9x ())
    return gdb_select_win9x (n, readfds, writefds, exceptfds, timeout);

  num_ready = 0;
"""


def main() -> int:
    original = SRC.read_text(encoding="utf-8")

    if ANCHOR_BEFORE_HELPERS not in original:
        print("ERROR: anchor #1 (windows_get_absolute_argv0 block) not found", file=sys.stderr)
        return 1
    if ANCHOR_DISPATCH_BEFORE not in original:
        print("ERROR: anchor #2 (n==0 dispatch site) not found", file=sys.stderr)
        return 1

    modified = original.replace(
        ANCHOR_BEFORE_HELPERS,
        ANCHOR_BEFORE_HELPERS + HELPERS,
        1,
    )
    modified = modified.replace(
        ANCHOR_DISPATCH_BEFORE,
        DISPATCH,
        1,
    )

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        a = td / "a"
        b = td / "b"
        a.mkdir()
        b.mkdir()
        rel = "gdb/mingw-hdep.c"
        (a / "gdb").mkdir()
        (b / "gdb").mkdir()
        (a / rel).write_text(original, encoding="utf-8")
        (b / rel).write_text(modified, encoding="utf-8")
        proc = subprocess.run(
            [
                "diff", "-u",
                "--label", f"a/{rel}",
                "--label", f"b/{rel}",
                str(a / rel), str(b / rel),
            ],
            cwd=td,
            capture_output=True,
            text=True,
        )
        # diff returns 1 when files differ — that's normal, not failure.
        if proc.returncode not in (0, 1):
            print(proc.stderr, file=sys.stderr)
            return proc.returncode
        sys.stdout.write(proc.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
