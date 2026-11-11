#!/usr/bin/env python3
"""
Regenerator for 0013-spawn-waitpid-handle-table-on-win9x.patch.

Background:
  After patch 0008 (ash's forkparent/waitpid_child) the dominant remaining
  GetProcessId() breakage was mingw_spawn() at win32/process.c:447.  Every
  non-shell caller of `spawn(argv); wait4pid(rc)` (find -exec, xargs single-
  process, flock, install -o/-g, inotifyd, watch, crontab, time, busybox
  spawn_and_wait()) hits this path -- mingw_spawn returns 0 on Win9x via
  the win98-compat GetProcessId shim, then wait4pid short-circuits on
  `pid <= 0` and never calls WaitForSingleObject, so the applet thinks
  the child failed regardless of what actually happened.

  The audit at repro/docs/win9x-shim-audit.md flagged 5 unfixed sites;
  this patch covers the dominant pair (mingw_spawn + waitpid); patches
  0014/0015 cover the timeout.c / xargs.c Ctrl+C path siblings.

Fix:
  Add a side-table mapping a stable non-zero surrogate pid (derived from
  the HANDLE value) -> HANDLE.  mingw_spawn registers; waitpid looks up;
  the table is consulted only when is_win9x_proc().  busybox is
  single-threaded so a flat 64-slot array is plenty (no concurrent
  inserts/lookups).  NT path is untouched.

  Side-table entry is released (CloseHandle) when waitpid sees
  WAIT_OBJECT_0 (child exited); a WAIT_TIMEOUT (WNOHANG and still
  running) leaves the entry alive so the next call can wait again.

Three edits to win32/process.c:
  1. Insert side-table + helpers between is_win9x_proc and waitpid.
  2. Replace OpenProcess() in waitpid/mingw_wait3 body with a Win9x-
     branched lookup.
  3. Replace the trailing GetProcessId() in mingw_spawn with a Win9x-
     branched register.

Usage (run inside the toolchain-builder container):
    cd /work/src/busybox-w32
    # ensure 0001-0012 are applied on top of HEAD
    python3 /work/patches/busybox-w32/master/.gen-0013-patch.py
"""
import subprocess
import sys
from pathlib import Path

EDITS = []


def edit(src, old, new):
    EDITS.append((Path(src), old, new))


# ---- 1. win32/process.c : insert side-table machinery after is_win9x_proc -
edit(
    "win32/process.c",
    "\t\t         osvi.dwPlatformId == VER_PLATFORM_WIN32_WINDOWS;\n"
    "\t}\n"
    "\treturn cached;\n"
    "}\n"
    "\n"
    "pid_t FAST_FUNC waitpid(pid_t pid, int *status, int options)\n",
    "\t\t         osvi.dwPlatformId == VER_PLATFORM_WIN32_WINDOWS;\n"
    "\t}\n"
    "\treturn cached;\n"
    "}\n"
    "\n"
    "/* Win9x surrogate-pid <-> HANDLE side-table.  GetProcessId() is Vista+;\n"
    " * our win98-compat shim returns 0 for any non-current-process handle.\n"
    " * So on Win9x mingw_spawn() can't hand a real PID back to wait4pid() --\n"
    " * the value would be 0 and wait4pid() short-circuits at `pid <= 0`\n"
    " * before WaitForSingleObject.  Instead we derive a non-zero surrogate\n"
    " * pid from the HANDLE at spawn time, store it here, and let waitpid()\n"
    " * look the HANDLE back up.  busybox is single-threaded so a flat\n"
    " * table is plenty.  NT path is unaffected -- this is only consulted\n"
    " * when is_win9x_proc(). */\n"
    "#define WIN9X_PROC_TABLE_SIZE 64\n"
    "static struct {\n"
    "\tpid_t pid;\n"
    "\tHANDLE handle;\n"
    "} win9x_proc_table[WIN9X_PROC_TABLE_SIZE];\n"
    "\n"
    "static pid_t win9x_register_proc(HANDLE h)\n"
    "{\n"
    "\tpid_t pid = (pid_t)(((uintptr_t)h & 0x7FFFFFFF) | 1);\n"
    "\tint i;\n"
    "\tfor (i = 0; i < WIN9X_PROC_TABLE_SIZE; i++) {\n"
    "\t\tif (win9x_proc_table[i].pid == 0) {\n"
    "\t\t\twin9x_proc_table[i].pid = pid;\n"
    "\t\t\twin9x_proc_table[i].handle = h;\n"
    "\t\t\treturn pid;\n"
    "\t\t}\n"
    "\t}\n"
    "\t/* Table full -- caller still gets a surrogate so a non-waiting\n"
    "\t * spawn (e.g. spawn-and-detach paths) keeps working; only\n"
    "\t * wait4pid() will fail (HANDLE not recoverable). */\n"
    "\treturn pid;\n"
    "}\n"
    "\n"
    "static HANDLE win9x_lookup_proc(pid_t pid)\n"
    "{\n"
    "\tint i;\n"
    "\tfor (i = 0; i < WIN9X_PROC_TABLE_SIZE; i++) {\n"
    "\t\tif (win9x_proc_table[i].pid == pid)\n"
    "\t\t\treturn win9x_proc_table[i].handle;\n"
    "\t}\n"
    "\treturn NULL;\n"
    "}\n"
    "\n"
    "static void win9x_release_proc(pid_t pid)\n"
    "{\n"
    "\tint i;\n"
    "\tfor (i = 0; i < WIN9X_PROC_TABLE_SIZE; i++) {\n"
    "\t\tif (win9x_proc_table[i].pid == pid) {\n"
    "\t\t\tCloseHandle(win9x_proc_table[i].handle);\n"
    "\t\t\twin9x_proc_table[i].pid = 0;\n"
    "\t\t\twin9x_proc_table[i].handle = NULL;\n"
    "\t\t\treturn;\n"
    "\t\t}\n"
    "\t}\n"
    "}\n"
    "\n"
    "pid_t FAST_FUNC waitpid(pid_t pid, int *status, int options)\n",
)

# ---- 2. win32/process.c : waitpid/mingw_wait3 body -- Win9x lookup branch -
#
# The body is shared between waitpid (when ENABLE_TIME=0) and mingw_wait3
# (when ENABLE_TIME=1); the #if structure means we only need to patch the
# body once.  The OpenProcess + CloseHandle pair becomes a Win9x-branched
# lookup + conditional release.
edit(
    "win32/process.c",
    "\t/* Windows does not understand parent-child */\n"
    "\tif (pid > 0 && (options == 0 || options == WNOHANG)) {\n"
    "\t\tif ( (proc=OpenProcess(SYNCHRONIZE|PROCESS_QUERY_INFORMATION,\n"
    "\t\t\t\t\t\tFALSE, pid)) != NULL ) {\n"
    "\t\t\twaitcode = WaitForSingleObject(proc, options == WNOHANG ? 0 : INFINITE);\n"
    "\t\t\tif (status)\n"
    "\t\t\t\tGetExitCodeProcess(proc, &code);\n",
    "\t/* Windows does not understand parent-child */\n"
    "\tif (pid > 0 && (options == 0 || options == WNOHANG)) {\n"
    "\t\tint win9x = is_win9x_proc();\n"
    "\t\tif (win9x) {\n"
    "\t\t\t/* `pid` is a surrogate value registered by mingw_spawn();\n"
    "\t\t\t * recover the HANDLE from the side-table instead of\n"
    "\t\t\t * OpenProcess (which wants a real PID, doesn't exist for\n"
    "\t\t\t * our surrogates). */\n"
    "\t\t\tproc = win9x_lookup_proc(pid);\n"
    "\t\t} else {\n"
    "\t\t\tproc = OpenProcess(SYNCHRONIZE|PROCESS_QUERY_INFORMATION,\n"
    "\t\t\t\t\t\tFALSE, pid);\n"
    "\t\t}\n"
    "\t\tif (proc != NULL) {\n"
    "\t\t\twaitcode = WaitForSingleObject(proc, options == WNOHANG ? 0 : INFINITE);\n"
    "\t\t\tif (status)\n"
    "\t\t\t\tGetExitCodeProcess(proc, &code);\n",
)

# Replace the CloseHandle in the same body with a Win9x-aware release.
edit(
    "win32/process.c",
    "\t\t\tCloseHandle(proc);\n"
    "\t\t\tif (status)\n"
    "\t\t\t\t*status = exit_code_to_wait_status(code);\n"
    "\t\t\tif (waitcode == WAIT_TIMEOUT)\n"
    "\t\t\t\treturn 0;\n"
    "\t\t\treturn pid;\n"
    "\t\t}\n"
    "\t}\n"
    "\terrno = pid < 0 ? ENOSYS : EINVAL;\n"
    "\treturn -1;\n"
    "}\n",
    "\t\t\tif (win9x) {\n"
    "\t\t\t\t/* Process actually exited -> release the side-table\n"
    "\t\t\t\t * entry (CloseHandle).  WNOHANG-still-running keeps\n"
    "\t\t\t\t * the entry alive for the next call. */\n"
    "\t\t\t\tif (waitcode != WAIT_TIMEOUT)\n"
    "\t\t\t\t\twin9x_release_proc(pid);\n"
    "\t\t\t} else {\n"
    "\t\t\t\tCloseHandle(proc);\n"
    "\t\t\t}\n"
    "\t\t\tif (status)\n"
    "\t\t\t\t*status = exit_code_to_wait_status(code);\n"
    "\t\t\tif (waitcode == WAIT_TIMEOUT)\n"
    "\t\t\t\treturn 0;\n"
    "\t\t\treturn pid;\n"
    "\t\t}\n"
    "\t}\n"
    "\terrno = pid < 0 ? ENOSYS : EINVAL;\n"
    "\treturn -1;\n"
    "}\n",
)

# ---- 3. win32/process.c : mingw_spawn -- register HANDLE on Win9x --------
edit(
    "win32/process.c",
    "pid_t FAST_FUNC\n"
    "mingw_spawn(char **argv)\n"
    "{\n"
    "\tintptr_t ret;\n"
    "\n"
    "\tret = mingw_spawnvp(P_NOWAIT, argv[0], (char *const *)argv);\n"
    "\n"
    "\treturn ret == -1 ? (pid_t)-1 : (pid_t)GetProcessId((HANDLE)ret);\n"
    "}\n",
    "pid_t FAST_FUNC\n"
    "mingw_spawn(char **argv)\n"
    "{\n"
    "\tintptr_t ret;\n"
    "\n"
    "\tret = mingw_spawnvp(P_NOWAIT, argv[0], (char *const *)argv);\n"
    "\n"
    "\tif (ret == -1)\n"
    "\t\treturn (pid_t)-1;\n"
    "\t/* On Win9x GetProcessId() returns 0 (win98-compat shim fallback),\n"
    "\t * which would make wait4pid() short-circuit to -1 before any wait.\n"
    "\t * Register the HANDLE in the side-table keyed by a non-zero\n"
    "\t * surrogate pid derived from the handle value; waitpid() resolves\n"
    "\t * the surrogate back to the HANDLE.  See win9x_register_proc(). */\n"
    "\tif (is_win9x_proc())\n"
    "\t\treturn win9x_register_proc((HANDLE)ret);\n"
    "\treturn (pid_t)GetProcessId((HANDLE)ret);\n"
    "}\n",
)


def main():
    src_root = Path("/work/src/busybox-w32")
    if not src_root.exists():
        sys.exit(f"error: source root {src_root} does not exist")

    work = Path("/tmp/bb-0013-edit")
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
        "/work/patches/busybox-w32/master/0013-spawn-waitpid-handle-table-on-win9x.patch"
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
        "Subject: [PATCH] spawn/waitpid: surrogate-pid side-table on Win9x\n"
        "\n"
        "mingw_spawn() returned 0 on Win9x (win98-compat's GetProcessId\n"
        "shim's documented fallback), and wait4pid() short-circuits at\n"
        "`pid <= 0` before WaitForSingleObject -- so every busybox applet\n"
        "that does `pid = spawn(argv); ret = wait4pid(pid);` (or the\n"
        "libbb spawn_and_wait wrapper) reported failure regardless of\n"
        "what the child actually did.  Affected applets enabled in our\n"
        "config: find -exec, xargs single-process, flock, install -o/-g,\n"
        "inotifyd, watch, crontab, time.\n"
        "\n"
        "Fix: maintain a small side-table mapping a non-zero surrogate\n"
        "pid (derived from the HANDLE value) -> HANDLE.  mingw_spawn\n"
        "registers on Win9x; waitpid/mingw_wait3 look up; the entry is\n"
        "released (CloseHandle) on WAIT_OBJECT_0 and kept alive on\n"
        "WAIT_TIMEOUT (WNOHANG and still running).  busybox is single-\n"
        "threaded so a flat 64-slot array suffices.  NT path untouched.\n"
        "\n"
        "Companion to patch 0008 (ash forkparent/waitpid_child); see\n"
        "repro/docs/win9x-shim-audit.md for the full GetProcessId site\n"
        "list and reasoning.\n"
        "\n"
        "---\n"
    )
    patch_text = header + "\n".join(chunks)
    patch_path.write_text(patch_text)
    print(f"\nwrote {patch_path} ({len(touched)} file(s), {len(patch_text)} bytes)")


if __name__ == "__main__":
    main()
