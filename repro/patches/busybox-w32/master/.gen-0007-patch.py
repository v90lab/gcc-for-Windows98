#!/usr/bin/env python3
"""
Regenerator for 0007-bbdbg-log-wait-paths.patch.

Adds file-based debug logging at every key wait/spawn point so we can see
EXACTLY where busybox hangs on Win98.  Logs to C:\\BBLOG.TXT in append mode.
Always-on (no env var gate); the user is debugging anyway and the overhead
is negligible.

Edits:
  1. include/mingw.h  -- declare bbdbg_log()
  2. win32/mingw.c    -- implement bbdbg_log() (fopen/vfprintf/fclose)
  3. win32/process.c  -- log entry/exit of wait_for_child
  4. shell/ash.c      -- log entry/exit of waitpid_child + spawn_forkshell
                         + log every WaitForMultipleObjects call

Usage:
    cd /work/src/busybox-w32
    # ensure 0001-0006 are applied on top of HEAD
    python3 /work/patches/busybox-w32/master/.gen-0007-patch.py
"""
import sys
from pathlib import Path

MINGW_H = Path("include/mingw.h")
MINGW_C = Path("win32/mingw.c")
PROCESS_C = Path("win32/process.c")
ASH_C = Path("shell/ash.c")


def edit(path, old, new):
    text = path.read_text()
    if new in text:
        print(f"  {path}: already patched")
        return
    if old not in text:
        sys.exit(f"  {path}: anchor not found\n  Looking for:\n{old[:200]}")
    path.write_text(text.replace(old, new, 1))
    print(f"  {path}: patched")


# ---- 1. include/mingw.h: declare bbdbg_log ---------------------------------

MINGW_H_ANCHOR = "pid_t getppid(void) FAST_FUNC;"
MINGW_H_NEW = """pid_t getppid(void) FAST_FUNC;

/* Debug log helper -- writes to C:\\BBLOG.TXT in append mode.  Used by
 * patches 0007 et seq to trace the wait_for_child / waitpid_child path
 * looking for where Win98 hangs on child-exit notification.  Cheap; no
 * env-var gate.  Remove the patch when the underlying issue is fixed. */
void bbdbg_log(const char *fmt, ...) FAST_FUNC __attribute__((format(printf, 1, 2)));"""

# ---- 2. win32/mingw.c: implement bbdbg_log ---------------------------------

MINGW_C_ANCHOR = '#include "libbb.h"'
MINGW_C_NEW = """#include "libbb.h"
#include <stdarg.h>

/* See declaration in include/mingw.h.  Opens C:\\BBLOG.TXT in append mode,
 * writes one formatted line with a [pid=N] prefix, fcloses.  Silent
 * no-op if the file can't be opened (read-only media, permission denied,
 * etc.) so debugging never breaks the build. */
void FAST_FUNC bbdbg_log(const char *fmt, ...)
{
\tFILE *log = fopen("C:\\\\BBLOG.TXT", "a");
\tva_list ap;
\tif (!log)
\t\treturn;
\tfprintf(log, "[pid=%lu] ", (unsigned long)GetCurrentProcessId());
\tva_start(ap, fmt);
\tvfprintf(log, fmt, ap);
\tva_end(ap);
\tfputc('\\n', log);
\tfclose(log);
}
"""

# ---- 3. win32/process.c: log wait_for_child entry/exit ---------------------

PROCESS_C_ANCHOR = """\tif (getppid() == 1)
\t\texit(0);

\t/* Win9x: skip SetConsoleCtrlHandler + GetProcessId-based ctrl handler"""

PROCESS_C_NEW = """\tbbdbg_log("wait_for_child ENTRY child=0x%p cmd=%s",
\t          (void *)child, cmd ? cmd : "(null)");

\tif (getppid() == 1) {
\t\tbbdbg_log("wait_for_child getppid()==1, exit(0) early");
\t\texit(0);
\t}

\t/* Win9x: skip SetConsoleCtrlHandler + GetProcessId-based ctrl handler"""

PROCESS_C_ANCHOR2 = """\tWaitForSingleObject(child, INFINITE);
\tGetExitCodeProcess(child, &code);"""

PROCESS_C_NEW2 = """\tbbdbg_log("wait_for_child PRE-WaitForSingleObject child=0x%p", (void *)child);
\tWaitForSingleObject(child, INFINITE);
\tbbdbg_log("wait_for_child POST-WaitForSingleObject child=0x%p", (void *)child);
\tGetExitCodeProcess(child, &code);
\tbbdbg_log("wait_for_child GetExitCodeProcess code=%lu", (unsigned long)code);"""

PROCESS_C_ANCHOR3 = """\tif (!WIFSIGNALED(status) && code > 0xff)
\t\tcode = WEXITSTATUS(status);
\texit((int)code);
}"""

PROCESS_C_NEW3 = """\tif (!WIFSIGNALED(status) && code > 0xff)
\t\tcode = WEXITSTATUS(status);
\tbbdbg_log("wait_for_child PRE-exit code=%d", (int)code);
\texit((int)code);
}"""

# ---- 4. shell/ash.c: log waitpid_child + spawn_forkshell --------------------

ASH_C_ANCHOR_WAITPID = """\tif (pid_nr) {
\t\tdo {
\t\t\tidx = WaitForMultipleObjects(pid_nr, proclist, FALSE, blocking);
\t\t\tif (idx < pid_nr) {"""

ASH_C_NEW_WAITPID = """\tbbdbg_log("waitpid_child ENTRY pid_nr=%d blocking=%lu",
\t          pid_nr, (unsigned long)blocking);
\tif (pid_nr) {
\t\tint __i;
\t\tfor (__i = 0; __i < pid_nr; __i++)
\t\t\tbbdbg_log("waitpid_child proclist[%d]=0x%p", __i, (void *)proclist[__i]);
\t\tdo {
\t\t\tbbdbg_log("waitpid_child PRE-WaitForMultipleObjects pid_nr=%d blocking=%lu",
\t\t\t          pid_nr, (unsigned long)blocking);
\t\t\tidx = WaitForMultipleObjects(pid_nr, proclist, FALSE, blocking);
\t\t\tbbdbg_log("waitpid_child POST-WaitForMultipleObjects idx=%lu", (unsigned long)idx);
\t\t\tif (idx < pid_nr) {"""

ASH_C_ANCHOR_SPAWN = """\tret = mingw_spawn_applet(P_NOWAIT, (char *const *)argv, NULL);
\tCloseHandle(new->hMapFile);"""

ASH_C_NEW_SPAWN = """\tbbdbg_log("spawn_forkshell PRE-mingw_spawn_applet argv0=%s map=%s",
\t          argv[0] ? argv[0] : "(null)", map_name);
\tret = mingw_spawn_applet(P_NOWAIT, (char *const *)argv, NULL);
\tbbdbg_log("spawn_forkshell POST-mingw_spawn_applet ret=0x%p", (void *)ret);
\tCloseHandle(new->hMapFile);"""


def main():
    if not MINGW_H.exists():
        sys.exit("missing source files; run from /work/src/busybox-w32")

    print("Patching files:")
    edit(MINGW_H, MINGW_H_ANCHOR, MINGW_H_NEW)
    edit(MINGW_C, MINGW_C_ANCHOR, MINGW_C_NEW)
    edit(PROCESS_C, PROCESS_C_ANCHOR, PROCESS_C_NEW)
    edit(PROCESS_C, PROCESS_C_ANCHOR2, PROCESS_C_NEW2)
    edit(PROCESS_C, PROCESS_C_ANCHOR3, PROCESS_C_NEW3)
    edit(ASH_C, ASH_C_ANCHOR_WAITPID, ASH_C_NEW_WAITPID)
    edit(ASH_C, ASH_C_ANCHOR_SPAWN, ASH_C_NEW_SPAWN)
    print("Done.")


if __name__ == "__main__":
    main()
