#!/usr/bin/env python3
"""
Regenerator for 0015-xargs-parallel-terminate-on-win9x.patch.

Background:
  xargs --parallel installs a ctrl_handler that, on Ctrl+C, walks the
  array of currently-running child HANDLEs and calls
  `kill(GetProcessId(G.procs[i]), SIGTERM)` for each one.  Win9x has
  no GetProcessId (returns 0 via shim) and busybox's kill_signal_by_handle
  uses CreateRemoteThread (NT-only), so on Win9x the parallel-xargs
  Ctrl+C handler is a no-op -- children outlive the parent.

  Single-process branch uses `kill(-G.pid, SIGTERM)` to kill a process
  group, which on Win9x walks tlhelp32 looking for the surrogate pid
  established by patch 0013 -- that pid is not a real PID so the walk
  finds nothing.  Fixing the single-process Ctrl+C correctly would
  require either reverse-mapping the surrogate or restructuring the
  signal model; leaving as-is per the audit (load-bearing but only on
  the Ctrl+C path).

Fix (parallel path only -- audit site #3):
  On Win9x, TerminateProcess(G.procs[i], SIGTERM << 24) directly.
  Loses descendants of each running child, but kills the immediate
  child so it doesn't outlive xargs.

Usage (run inside the toolchain-builder container):
    cd /work/src/busybox-w32
    python3 /work/patches/busybox-w32/master/.gen-0015-patch.py
"""
import subprocess
import sys
from pathlib import Path

EDITS = []


def edit(src, old, new):
    EDITS.append((Path(src), old, new))


# ---- 1. findutils/xargs.c : ctrl_handler() parallel-mode block -----------
edit(
    "findutils/xargs.c",
    "# if ENABLE_FEATURE_XARGS_SUPPORT_PARALLEL\n"
    "\t\telse {\n"
    "\t\t\tint i;\n"
    "\n"
    "\t\t\tfor (i = 0; i < G.running_procs; ++i) {\n"
    "\t\t\t\tpid_t pid = GetProcessId(G.procs[i]);\n"
    "\t\t\t\tif (pid > 0)\n"
    "\t\t\t\t\tkill(-pid, SIGTERM);\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "# endif\n",
    "# if ENABLE_FEATURE_XARGS_SUPPORT_PARALLEL\n"
    "\t\telse {\n"
    "\t\t\tint i;\n"
    "\n"
    "\t\t\tfor (i = 0; i < G.running_procs; ++i) {\n"
    "\t\t\t\tif (is_win9x_proc()) {\n"
    "\t\t\t\t\t/* GetProcessId is Vista+ (returns 0 via shim);\n"
    "\t\t\t\t\t * kill_signal_by_handle uses CreateRemoteThread\n"
    "\t\t\t\t\t * (NT-only).  TerminateProcess directly on the\n"
    "\t\t\t\t\t * HANDLE -- loses descendants but kills the\n"
    "\t\t\t\t\t * immediate child so it doesn't outlive xargs. */\n"
    "\t\t\t\t\tTerminateProcess(G.procs[i], SIGTERM << 24);\n"
    "\t\t\t\t} else {\n"
    "\t\t\t\t\tpid_t pid = GetProcessId(G.procs[i]);\n"
    "\t\t\t\t\tif (pid > 0)\n"
    "\t\t\t\t\t\tkill(-pid, SIGTERM);\n"
    "\t\t\t\t}\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "# endif\n",
)


def main():
    src_root = Path("/work/src/busybox-w32")
    if not src_root.exists():
        sys.exit(f"error: source root {src_root} does not exist")

    work = Path("/tmp/bb-0015-edit")
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
        "/work/patches/busybox-w32/master/0015-xargs-parallel-terminate-on-win9x.patch"
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
        "Subject: [PATCH] xargs --parallel: TerminateProcess on Win9x Ctrl+C\n"
        "\n"
        "ctrl_handler's parallel-mode branch called\n"
        "`kill(GetProcessId(G.procs[i]), SIGTERM)` on each running child.\n"
        "Win9x's GetProcessId returns 0 via shim and signal-by-handle uses\n"
        "CreateRemoteThread (NT-only), so on Win9x the parallel xargs\n"
        "Ctrl+C handler is a no-op and children outlive the parent.\n"
        "\n"
        "On Win9x, TerminateProcess() the HANDLE directly.  Loses\n"
        "descendants of each child but kills the immediate child --\n"
        "the property a SIGINT user is after when interrupting xargs.\n"
        "\n"
        "Fixes audit site #3 from repro/docs/win9x-shim-audit.md.\n"
        "Single-process Ctrl+C path (kill(-pid)) remains degraded;\n"
        "noted in the audit, low priority.\n"
        "\n"
        "---\n"
    )
    patch_text = header + "\n".join(chunks)
    patch_path.write_text(patch_text)
    print(f"\nwrote {patch_path} ({len(touched)} file(s), {len(patch_text)} bytes)")


if __name__ == "__main__":
    main()
