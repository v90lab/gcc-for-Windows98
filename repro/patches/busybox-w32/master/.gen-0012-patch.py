#!/usr/bin/env python3
"""
Regenerator for 0012-mingw-stat-win9x-uid-defaults.patch.

Background:
  Round 7 BBLOG.TXT (consdiag/run_7/BBLOG.TXT) proved that PATH-relative
  non-applet binaries (`ctags`, `make`, `gdb`, `muon`, `diff`, `patch`)
  fail with "permission denied" inside busybox sh on Win98 because of an
  interaction between mingw_stat and ash's find_command::test_exec:

    1. mingw_stat (do_lstat in win32/mingw.c) for any non-device,
       non-recall file does CreateFile(..., READ_CONTROL, ...) to probe
       NT security info.  On Win9x there are no security descriptors, so
       this call predictably FAILS.

    2. The existing failure-branch sets st_uid = st_gid = 0 and strips
       S_IRWXO from st_mode.

    3. ash's getuid() on Win98 returns DEFAULT_UID (4095), not 0.
       (See _WIN98_PORT branch of elevation_state() in mingw.c.)

    4. ash's test_exec runs:
         if ((st_mode & ANY_IX) == ANY_IX) return 1;  // S_IXOTH=0, miss
         euid = get_cached_euid();                    // = 4095
         if (euid == 0)             stmode = ANY_IX;  // 4095, miss
         else if (st_uid == euid)   stmode = S_IXUSR; // 0 != 4095, miss
         else if (st_gid == egid)   stmode = S_IXGRP; // 0 != 4095, miss
         ... falls through to stmode = S_IXOTH;
         return st_mode & stmode;                     // 0 -- "denied"

    5. PATH search exhausts all entries with the same EACCES,
       ash prints "<cmd>: Permission denied".  Full-path invocations
       bypass find_command entirely and go straight to spawnveq, whose
       check is just S_ISREG && S_IXUSR (S_IXUSR IS set in 0770) so
       they succeed.

  Wine doesn't reproduce this because under Wine CreateFile with
  READ_CONTROL succeeds, the if-branch sets a real uid via file_owner,
  and ash's test_exec passes the st_uid == euid arm.

Fix:
  In the do_lstat else-branch (CreateFile probe failed), special-case
  Win9x: use DEFAULT_UID/GID (so it matches getuid()) and don't strip
  S_IRWXO (Win9x has no concept of restricted-to-other; every file is
  world-accessible).  The minimal diff -- the else-branch is the only
  place that needed changing, and on NT the existing behavior is
  preserved verbatim.

  Detection via is_win9x_proc() which is already declared in mingw.h
  (added in patch 0006) and lazy-cached.

One edit in win32/mingw.c.

Usage (run inside the toolchain-builder container, with 0001-0011
applied):
    python3 /work/patches/busybox-w32/master/.gen-0012-patch.py
"""
import subprocess
import sys
from pathlib import Path

EDITS = []


def edit(src, old, new):
    EDITS.append((Path(src), old, new))


# ---- 1. win32/mingw.c : do_lstat else-branch on Win9x ------------------
edit(
    "win32/mingw.c",
    "\t\t\t\tbuf->st_uid = buf->st_gid = file_owner(fh, buf);\n"
    "\t\t\t\tCloseHandle(fh);\n"
    "\t\t\t} else {\n"
    "\t\t\t\tbuf->st_uid = buf->st_gid = 0;\n"
    "\t\t\t\tbuf->st_mode &= ~S_IRWXO;\n"
    "\t\t\t}\n",
    "\t\t\t\tbuf->st_uid = buf->st_gid = file_owner(fh, buf);\n"
    "\t\t\t\tCloseHandle(fh);\n"
    "\t\t\t} else if (is_win9x_proc()) {\n"
    "\t\t\t\t/* Win9x has no NT security descriptors; the\n"
    "\t\t\t\t * READ_CONTROL CreateFile probe predictably\n"
    "\t\t\t\t * fails.  The original else-branch sets st_uid=0\n"
    "\t\t\t\t * + strips S_IRWXO, which on Win9x then mismatches\n"
    "\t\t\t\t * getuid()=DEFAULT_UID and makes ash's find_command\n"
    "\t\t\t\t * test_exec reject every PATH-resolved executable\n"
    "\t\t\t\t * with \"Permission denied\".  Use sensible Win9x\n"
    "\t\t\t\t * defaults: match the uid getuid() reports, and\n"
    "\t\t\t\t * leave S_IRWXO alone (every Win9x file is in\n"
    "\t\t\t\t * fact world-accessible -- no security model). */\n"
    "\t\t\t\tbuf->st_uid = buf->st_gid = DEFAULT_UID;\n"
    "\t\t\t} else {\n"
    "\t\t\t\tbuf->st_uid = buf->st_gid = 0;\n"
    "\t\t\t\tbuf->st_mode &= ~S_IRWXO;\n"
    "\t\t\t}\n",
)


def main():
    src_root = Path("/work/src/busybox-w32")
    if not src_root.exists():
        sys.exit(f"error: source root {src_root} does not exist")

    work = Path("/tmp/bb-0012-edit")
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
                f"error: anchor not found in {relpath}\n"
                f"--- expected ---\n{old}\n----------------"
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
        "/work/patches/busybox-w32/master/0012-mingw-stat-win9x-uid-defaults.patch"
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
        "Subject: [PATCH] mingw_stat: Win9x-correct uid/perm defaults\n"
        "\n"
        "do_lstat's READ_CONTROL CreateFile probe (gated on\n"
        "ENABLE_FEATURE_EXTRA_FILE_DATA) predictably fails on Win9x --\n"
        "there are no NT security descriptors to query.  The existing\n"
        "failure-branch sets st_uid=0 and strips S_IRWXO, but on Win9x\n"
        "this creates two problems:\n"
        "\n"
        "  1. getuid() returns DEFAULT_UID (4095) on Win9x (via\n"
        "     elevation_state()'s _WIN98_PORT branch), so st_uid=0\n"
        "     doesn't match any uid-based access check.\n"
        "\n"
        "  2. Stripping S_IRWXO is semantically wrong on Win9x -- every\n"
        "     file IS world-accessible; there is no access-restriction\n"
        "     model to defer to.\n"
        "\n"
        "Net effect: ash's find_command::test_exec rejects every\n"
        "PATH-resolved executable on Win9x with EACCES (`<cmd>: Permission\n"
        "denied`).  Full-path invocations bypass find_command entirely\n"
        "and reach spawnveq, whose check is just S_ISREG && S_IXUSR\n"
        "(passes -- S_IXUSR is still set in 0770), so they work fine.\n"
        "That's the asymmetry users saw: `ctags` fails, but\n"
        "`/opt/extras/bin/ctags.exe` runs.  Round 7 BBLOG.TXT\n"
        "(consdiag/run_7) traced it definitively.\n"
        "\n"
        "Wine doesn't reproduce: under Wine CreateFile with READ_CONTROL\n"
        "succeeds, the if-branch sets a real uid via file_owner, and\n"
        "test_exec's `st_uid == euid` arm passes.  Real Win98 only.\n"
        "\n"
        "Add an `else if (is_win9x_proc())` arm that uses DEFAULT_UID/GID\n"
        "(to match getuid()) and leaves S_IRWXO alone.  NT behavior\n"
        "preserved verbatim.\n"
        "\n"
        "---\n"
    )
    patch_text = header + "\n".join(chunks)
    patch_path.write_text(patch_text)
    print(f"\nwrote {patch_path} ({len(touched)} file(s), {len(patch_text)} bytes)")


if __name__ == "__main__":
    main()
