#!/usr/bin/env python3
"""
Regenerator for 0014-timeout-terminate-on-win9x.patch.

Background:
  busybox `timeout PROG ARGS` waits for the child, and when the timer
  expires it signals via `kill(GetProcessId(child), signo)`.  Win9x has
  no GetProcessId; the win98-compat shim returns 0; busybox's `kill()`
  treats 0 specially (current process) which is the wrong thing here;
  and even if we plumbed the right PID through, busybox's
  kill_signal_by_handle() uses CreateRemoteThread (NT-only).  So on
  Win9x the timer fires but the child is never signaled -- timeout
  silently fails to enforce its deadline.

  Two sites in coreutils/timeout.c:
    - kill_child() atexit handler (line 57)
    - timeout_main() post-timeout signal block (line 215)

Fix:
  On Win9x, TerminateProcess(child, sig << 24) directly using the
  already-in-scope HANDLE.  This loses descendants (a child shell
  would normally also kill its grandchildren via kill(-pid)) and
  doesn't give the child a chance to clean up -- but neither does
  the existing NT fallback for non-installable signals.  Since the
  goal is "enforce the deadline", forced termination achieves it.

  Same intuition as the audit's proposed fix shape at
  repro/docs/win9x-shim-audit.md.

Two edits to coreutils/timeout.c.  is_win9x_proc() is declared in
include/mingw.h (patch 0008) and reaches via libbb.h on PLATFORM_MINGW32.

Usage (run inside the toolchain-builder container):
    cd /work/src/busybox-w32
    python3 /work/patches/busybox-w32/master/.gen-0014-patch.py
"""
import subprocess
import sys
from pathlib import Path

EDITS = []


def edit(src, old, new):
    EDITS.append((Path(src), old, new))


# ---- 1. coreutils/timeout.c : kill_child() atexit handler -----------------
edit(
    "coreutils/timeout.c",
    "static void kill_child(void)\n"
    "{\n"
    "\tif (child != INVALID_HANDLE_VALUE) {\n"
    "\t\tpid_t pid = (pid_t)GetProcessId(child);\n"
    "\t\tif (pid)\n"
    "\t\t\tkill(pid, SIGTERM);\n"
    "\t}\n"
    "}\n",
    "static void kill_child(void)\n"
    "{\n"
    "\tif (child != INVALID_HANDLE_VALUE) {\n"
    "\t\tif (is_win9x_proc()) {\n"
    "\t\t\t/* GetProcessId is Vista+ (returns 0 via win98-compat\n"
    "\t\t\t * shim on Win9x), and busybox's kill_signal_by_handle()\n"
    "\t\t\t * uses CreateRemoteThread which doesn't exist on Win9x.\n"
    "\t\t\t * Force-terminate via the HANDLE we already own. */\n"
    "\t\t\tTerminateProcess(child, SIGTERM << 24);\n"
    "\t\t} else {\n"
    "\t\t\tpid_t pid = (pid_t)GetProcessId(child);\n"
    "\t\t\tif (pid)\n"
    "\t\t\t\tkill(pid, SIGTERM);\n"
    "\t\t}\n"
    "\t}\n"
    "}\n",
)

# ---- 2. coreutils/timeout.c : timeout_main() post-timeout signal block ----
edit(
    "coreutils/timeout.c",
    "\tpid = (pid_t)GetProcessId(child);\n"
    "\tif (pid) {\n"
    "\t\tkill(pid, signo);\n"
    "\n"
    "\t\tif (kill_timeout > 0) {\n"
    "\t\t\tif (timeout_wait(kill_timeout, child, &status))\n"
    "\t\t\t\tgoto finish;\n"
    "\t\t\tkill(pid, SIGKILL);\n"
    "\t\t\tstatus = 137;\n"
    "\t\t}\n"
    "\t}\n",
    "\tif (is_win9x_proc()) {\n"
    "\t\t/* GetProcessId is Vista+; signal-by-handle uses\n"
    "\t\t * CreateRemoteThread (also NT-only).  Force-terminate\n"
    "\t\t * the child HANDLE directly to enforce the deadline. */\n"
    "\t\tTerminateProcess(child, signo << 24);\n"
    "\t\tif (kill_timeout > 0) {\n"
    "\t\t\tif (timeout_wait(kill_timeout, child, &status))\n"
    "\t\t\t\tgoto finish;\n"
    "\t\t\tTerminateProcess(child, SIGKILL << 24);\n"
    "\t\t\tstatus = 137;\n"
    "\t\t}\n"
    "\t} else {\n"
    "\t\tpid = (pid_t)GetProcessId(child);\n"
    "\t\tif (pid) {\n"
    "\t\t\tkill(pid, signo);\n"
    "\n"
    "\t\t\tif (kill_timeout > 0) {\n"
    "\t\t\t\tif (timeout_wait(kill_timeout, child, &status))\n"
    "\t\t\t\t\tgoto finish;\n"
    "\t\t\t\tkill(pid, SIGKILL);\n"
    "\t\t\t\tstatus = 137;\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "\t}\n",
)


def main():
    src_root = Path("/work/src/busybox-w32")
    if not src_root.exists():
        sys.exit(f"error: source root {src_root} does not exist")

    work = Path("/tmp/bb-0014-edit")
    work.mkdir(parents=True, exist_ok=True)
    orig_dir = work / "orig"
    new_dir = work / "new"
    for d in (orig_dir, new_dir):
        if d.exists():
            for p in sorted(d.rglob("*"), reverse=True):
                if p.is_file():
                    p.unlink()
                else:
                    p.rmdir()
        d.mkdir(parents=True, exist_ok=True)

    touched = []
    for relpath, old, new in EDITS:
        target = src_root / relpath
        text = target.read_text()

        if old not in text:
            if new in text:
                print(f"info: {relpath} already contains the new edit -- skipping")
                continue
            sys.exit(
                f"error: anchor not found in {relpath}\n--- expected ---\n{old}\n----------------"
            )

        snapshot = orig_dir / relpath
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        if not snapshot.exists():
            snapshot.write_text(text)

        new_text = text.replace(old, new, 1)
        target.write_text(new_text)

        new_snapshot = new_dir / relpath
        new_snapshot.parent.mkdir(parents=True, exist_ok=True)
        new_snapshot.write_text(new_text)

        if relpath not in touched:
            touched.append(relpath)
        print(f"patched {relpath}")

    patch_path = Path(
        "/work/patches/busybox-w32/master/0014-timeout-terminate-on-win9x.patch"
    )
    chunks = []
    for relpath in touched:
        orig = orig_dir / relpath
        new = new_dir / relpath
        result = subprocess.run(
            [
                "diff",
                "-u",
                "--label",
                f"a/{relpath.as_posix()}",
                "--label",
                f"b/{relpath.as_posix()}",
                str(orig),
                str(new),
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode not in (0, 1):
            sys.exit(f"error: diff -u failed for {relpath}: {result.stderr}")
        if result.returncode == 0:
            continue
        chunk = "diff --git a/{p} b/{p}\n".format(p=relpath.as_posix())
        chunk += result.stdout
        chunks.append(chunk)

    header = (
        "From: gcc-for-windows98 patcher <patches@example.invalid>\n"
        "Subject: [PATCH] timeout: TerminateProcess on Win9x instead of kill+GetProcessId\n"
        "\n"
        "`busybox timeout PROG ARGS` enforces its deadline by calling\n"
        "`kill(GetProcessId(child), signo)`.  Win9x has no GetProcessId\n"
        "(our shim returns 0), and busybox's kill_signal_by_handle()\n"
        "uses CreateRemoteThread (also NT-only).  Result: the timer\n"
        "fires but the child is never signaled -- timeout becomes a\n"
        "silent no-op past its deadline.\n"
        "\n"
        "On Win9x use TerminateProcess() directly via the HANDLE\n"
        "already in scope.  Loses descendants, but enforces the\n"
        "deadline (which is the whole point of the applet).\n"
        "\n"
        "Fixes audit sites #4 and #5 from repro/docs/win9x-shim-audit.md.\n"
        "is_win9x_proc() is declared in include/mingw.h (patch 0008).\n"
        "\n"
        "---\n"
    )
    patch_text = header + "\n".join(chunks)
    patch_path.write_text(patch_text)
    print(f"\nwrote {patch_path} ({len(touched)} file(s), {len(patch_text)} bytes)")


if __name__ == "__main__":
    main()
