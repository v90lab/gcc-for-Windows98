#!/usr/bin/env python3
"""
Regenerator for 0008-waitpid-handle-not-pid-on-win9x.patch.

Background:
  ash.c uses GetProcessId() at TWO sites to map a child HANDLE back to a
  PID -- forkparent() (stores ps_pid) and waitpid_child() (returns pid).
  GetProcessId is Vista+; our win98-compat shim returns 0 on Win9x for
  non-current-process handles.  Result: ps_pid=0 stored at spawn, pid=0
  returned from wait.  Then waitone() sees `pid <= 0` and `goto out`,
  skipping the job-state update.  dowait() loops forever because
  jp->state never becomes JOBDONE.  This is the "sh hangs after any
  external command" bug, confirmed in round 3 BBLOG.TXT
  (POST-WaitForMultipleObjects idx=0 followed by re-ENTRY in tight loop).

Fix:
  On Win9x, derive a stable surrogate pid from the handle value.  busybox
  only needs the pid as an identifier for equality matching between
  forkparent (store) and waitpid_child (return); the actual numeric value
  is opaque.  Reuse the existing is_win9x_proc() helper from process.c
  (added in patch 0006) -- expose it via mingw.h.

Three edits:
  1. include/mingw.h          -- declare is_win9x_proc()
  2. win32/process.c          -- drop `static` from is_win9x_proc
  3. shell/ash.c              -- replace GetProcessId() at both sites
                                 with a Win9x branch

Usage (run inside the toolchain-builder container):
    cd /work/src/busybox-w32
    # ensure 0001-0007 are applied on top of HEAD
    python3 /work/patches/busybox-w32/master/.gen-0008-patch.py
"""
import subprocess
import sys
from pathlib import Path

EDITS = []


def edit(src, old, new):
    EDITS.append((Path(src), old, new))


# ---- 1. include/mingw.h : declare is_win9x_proc() -----------------------
edit(
    "include/mingw.h",
    "int inet_aton(const char *cp, struct in_addr *inp) FAST_FUNC;\n",
    "int inet_aton(const char *cp, struct in_addr *inp) FAST_FUNC;\n"
    "int is_win9x_proc(void);\n",
)

# ---- 2. win32/process.c : remove `static` from is_win9x_proc ------------
edit(
    "win32/process.c",
    "static int is_win9x_proc(void)\n",
    "int is_win9x_proc(void)\n",
)

# ---- 3a. shell/ash.c : forkparent() -- replace GetProcessId at line ~6214
edit(
    "shell/ash.c",
    "#if ENABLE_PLATFORM_MINGW32\n"
    "\tpid_t pid = GetProcessId(proc);\n"
    "#else\n",
    "#if ENABLE_PLATFORM_MINGW32\n"
    "\t/* On Win9x GetProcessId() is unavailable (Vista+); our shim returns 0.\n"
    "\t * busybox stores this in ps_pid and later matches it against the value\n"
    "\t * returned from waitpid_child().  Use the handle value as a stable\n"
    "\t * surrogate -- it's unique within this process's lifetime and the\n"
    "\t * match site (waitone) only needs equality, not a real PID.  Both\n"
    "\t * sides of the comparison must agree on the same derivation, so\n"
    "\t * waitpid_child() applies the same transform. */\n"
    "\tpid_t pid;\n"
    "\tif (is_win9x_proc())\n"
    "\t\tpid = (pid_t)((uintptr_t)proc & 0x7FFFFFFF) | 1;\n"
    "\telse\n"
    "\t\tpid = GetProcessId(proc);\n"
    "#else\n",
)

# ---- 3b. shell/ash.c : waitpid_child() -- replace GetProcessId at line ~4942
edit(
    "shell/ash.c",
    "\t\t\tGetExitCodeProcess(proclist[idx], &win_status);\n"
    "\t\t\t\t*status = exit_code_to_wait_status(win_status);\n"
    "\t\t\t\tpid = GetProcessId(proclist[idx]);\n"
    "\t\t\t\tbreak;\n",
    "\t\t\tGetExitCodeProcess(proclist[idx], &win_status);\n"
    "\t\t\t\t*status = exit_code_to_wait_status(win_status);\n"
    "\t\t\t\t/* See forkparent(): on Win9x derive a surrogate pid from the\n"
    "\t\t\t\t * handle so this equality matches the value stored at spawn\n"
    "\t\t\t\t * time.  GetProcessId returns 0 on Win9x, which causes the\n"
    "\t\t\t\t * caller to busy-loop forever (see waitone -> goto out). */\n"
    "\t\t\t\tif (is_win9x_proc())\n"
    "\t\t\t\t\tpid = (pid_t)((uintptr_t)proclist[idx] & 0x7FFFFFFF) | 1;\n"
    "\t\t\t\telse\n"
    "\t\t\t\t\tpid = GetProcessId(proclist[idx]);\n"
    "\t\t\t\tbreak;\n",
)


def main():
    src_root = Path("/work/src/busybox-w32")
    if not src_root.exists():
        sys.exit(f"error: source root {src_root} does not exist")

    # Backup the originals before editing -- enables `diff -uN` reconstruction.
    work = Path("/tmp/bb-0008-edit")
    work.mkdir(parents=True, exist_ok=True)
    orig_dir = work / "orig"
    new_dir = work / "new"
    for d in (orig_dir, new_dir):
        # Wipe then recreate so we never mix files between runs.
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
            # Idempotency check: maybe already edited.
            if new in text:
                print(f"info: {relpath} already contains the new edit -- skipping")
                continue
            sys.exit(f"error: anchor not found in {relpath}\n--- expected ---\n{old}\n----------------")

        # Save original snapshot once per file (first time we touch it).
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

    # Emit a unified diff per file, concatenated with diff --git headers so
    # `git apply` (and our apply-patches.sh) recognize the file paths.
    patch_path = Path("/work/patches/busybox-w32/master/0008-waitpid-handle-not-pid-on-win9x.patch")
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
        # `diff -u` exits 1 when files differ (which is what we want).
        if result.returncode not in (0, 1):
            sys.exit(f"error: diff -u failed for {relpath}: {result.stderr}")
        if result.returncode == 0:
            continue  # no change for this file (shouldn't happen here)
        chunk = "diff --git a/{p} b/{p}\n".format(p=relpath.as_posix())
        chunk += result.stdout
        chunks.append(chunk)

    header = (
        "From: gcc-for-windows98 patcher <patches@example.invalid>\n"
        "Subject: [PATCH] ash: use handle-derived pid on Win9x instead of GetProcessId\n"
        "\n"
        "Win9x has no GetProcessId; our win98-compat shim returns 0 for any\n"
        "non-current-process handle.  busybox's forkparent stores this in\n"
        "ps_pid, then waitpid_child returns the same 0 from a matched wait,\n"
        "and waitone() bails on `pid <= 0` before the job-state update --\n"
        "so dowait() loops forever waiting for JOBDONE that never comes.\n"
        "This shows up as `sh` hanging after every external command on Win98.\n"
        "\n"
        "Use the child HANDLE value as a stable surrogate pid on Win9x.  The\n"
        "value is opaque to the user (so are real PIDs); equality matching\n"
        "between the spawn and wait sites is all busybox needs here.\n"
        "Reuses is_win9x_proc() from patch 0006 (exposed via mingw.h).\n"
        "\n"
        "---\n"
    )
    patch_text = header + "\n".join(chunks)
    patch_path.write_text(patch_text)
    print(f"\nwrote {patch_path} ({len(touched)} file(s), {len(patch_text)} bytes)")


if __name__ == "__main__":
    main()
