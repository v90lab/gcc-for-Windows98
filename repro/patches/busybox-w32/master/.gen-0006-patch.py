#!/usr/bin/env python3
"""
Regenerator for 0006-wait-for-child-skip-ctrl-handler-on-win9x.patch.

Why this exists: bash heredoc + python triple-quote escaping is too fragile to
do inline. Keep the patch logic here as a clean python script and let CI / dev
re-run it when the upstream baseline shifts.

Usage (run inside the toolchain-builder container):
    cd /work/src/busybox-w32
    # ensure 0001-0005 are applied on top of HEAD
    python3 /work/patches/busybox-w32/master/.gen-0006-patch.py
"""
import subprocess
import sys
from pathlib import Path

SRC = Path("win32/process.c")

ANCHOR = "pid_t FAST_FUNC waitpid(pid_t pid, int *status, int options)"

HELPER = """/* Win9x detection -- same logic as winansi.c::is_win9x but available
 * in process.c.  Cached, cheap on repeat calls. */
static int is_win9x_proc(void)
{
\tstatic int cached = -1;
\tif (cached == -1) {
\t\tOSVERSIONINFOA osvi;
\t\tosvi.dwOSVersionInfoSize = sizeof(osvi);
\t\tcached = GetVersionExA(&osvi) &&
\t\t         osvi.dwPlatformId == VER_PLATFORM_WIN32_WINDOWS;
\t}
\treturn cached;
}

"""

OLD_WAIT = """\tif (getppid() == 1)
\t\texit(0);

\tkill_child_ctrl_handler(GetProcessId(child));
\tSetConsoleCtrlHandler(kill_child_ctrl_handler, TRUE);
\tWaitForSingleObject(child, INFINITE);"""

NEW_WAIT = """\tif (getppid() == 1)
\t\texit(0);

\t/* Win9x: skip SetConsoleCtrlHandler + GetProcessId-based ctrl handler
\t * setup.  GetProcessId is a Vista+ API (our win98-compat shim returns
\t * 0 for non-current-process handles), and SetConsoleCtrlHandler on
\t * Win9x has been observed to cause the parent's wait on child exit
\t * notification to never return -- the child does terminate, but
\t * neither this WaitForSingleObject nor the parent shell's
\t * WaitForMultipleObjects ever fires.  Trade: Ctrl+C during a foreground
\t * command on Win9x won't politely propagate to the child; it kills the
\t * whole process group.  Acceptable for now. */
\tif (!is_win9x_proc()) {
\t\tkill_child_ctrl_handler(GetProcessId(child));
\t\tSetConsoleCtrlHandler(kill_child_ctrl_handler, TRUE);
\t}
\tWaitForSingleObject(child, INFINITE);"""


def main():
    if not SRC.exists():
        sys.exit(f"missing {SRC} -- run from /work/src/busybox-w32")

    text = SRC.read_text()

    if HELPER not in text:
        if ANCHOR not in text:
            sys.exit(f"anchor not found: {ANCHOR}")
        text = text.replace(ANCHOR, HELPER + ANCHOR, 1)

    if OLD_WAIT not in text:
        if NEW_WAIT in text:
            print("wait_for_child already patched")
        else:
            sys.exit("wait_for_child anchor not found")
    else:
        text = text.replace(OLD_WAIT, NEW_WAIT, 1)

    SRC.write_text(text)
    print(f"patched {SRC}")


if __name__ == "__main__":
    main()
