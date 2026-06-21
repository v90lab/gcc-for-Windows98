#!/usr/bin/env python3
"""
Regenerator for 0011-bbdbg-spawn-instrumentation.patch.

Background:
  From inside busybox sh on real Win98, running any non-applet binary by
  bare name (ctags, make, gdb, muon, diff, patch, ...) fails with
  "permission denied".  Full-path invocation works
  (/opt/extras/bin/ctags.exe is fine).  bb-shim applets (ls, cp, vi, ...)
  also work, because they short-circuit at the top of mingw_spawnvp via
  find_applet_by_name -> mingw_spawn_applet, never touching the PATH
  walk or spawnveq.

  User PATH is Windows-style:
    C:\\Windows;C:\\Windows\\Command;C:\\opt\\gcc\\bin;C:\\opt\\extras\\bin

  So find_executable joins entries via '%.*s/%s' and produces mixed-slash
  paths like  C:\\opt\\extras\\bin/ctags.exe .  Both stat() inside
  file_is_executable AND stat() inside spawnveq use the same mingw_stat
  on the same string, so in theory they should agree -- yet spawnveq is
  the one reporting EACCES.  Something is asymmetric.

Edits (3, all in win32/process.c):
  1. mingw_spawnvp entry  : log cmd, has_path, unix_path, applet lookup.
  2. mingw_spawnvp PATH-resolved branch  : log path returned by
     find_first_executable BEFORE handing to mingw_spawn_interpreter
     (and log NULL path / ENOENT exit when both branches miss).
  3. spawnveq stat-check  : replace the if/else block with a diagnostic
     version that records stat rc, errno, st_mode (S_ISREG + S_IXUSR
     bits broken out), and the final verdict (OK / EACCES-mode / stat-
     failed).

All logging goes to C:\\BBLOG.TXT via bbdbg_log() (patch 0007).  Cheap
(spawns are infrequent vs winansi writes), so no env gate -- just
append-on-every-spawn.  Same recursion concern as 0009 does NOT apply
here because process.c doesn't go back through the macro-redirected
stdio path (bbdbg_log's own fprintf in mingw.c uses the real libc).

Depends on patch 0007 for bbdbg_log().  Like 0007/0009, remove this
patch before shipping a stable release.

Usage (run inside the toolchain-builder container, with 0001-0010
applied):
    python3 /work/patches/busybox-w32/master/.gen-0011-patch.py
"""
import subprocess
import sys
from pathlib import Path

EDITS = []


def edit(src, old, new):
    EDITS.append((Path(src), old, new))


# ---- 1. mingw_spawnvp entry --------------------------------------------
edit(
    "win32/process.c",
    "static intptr_t\n"
    "mingw_spawnvp(int mode, const char *cmd, char *const *argv)\n"
    "{\n"
    "\tchar *path;\n"
    "\tintptr_t ret;\n"
    "\n"
    "#if ENABLE_FEATURE_PREFER_APPLETS && NUM_APPLETS > 1\n"
    "\tif ((!has_path(cmd) || unix_path(cmd)) &&\n"
    "\t\t\tfind_applet_by_name(bb_basename(cmd)) >= 0)\n"
    "\t\treturn mingw_spawn_applet(mode, argv, NULL);\n"
    "#endif\n"
    "\tif (has_path(cmd)) {\n",
    "static intptr_t\n"
    "mingw_spawnvp(int mode, const char *cmd, char *const *argv)\n"
    "{\n"
    "\tchar *path;\n"
    "\tintptr_t ret;\n"
    "\n"
    "\t/* patch 0011: spawn trace */\n"
    "\tbbdbg_log(\"SPAWN mingw_spawnvp ENTRY cmd=\\\"%s\\\" has_path=%d \"\n"
    "\t\t\"unix_path=%d applet=%d\",\n"
    "\t\tcmd ? cmd : \"(null)\",\n"
    "\t\tcmd ? has_path(cmd) : -1,\n"
    "\t\tcmd ? unix_path(cmd) : -1,\n"
    "\t\tcmd ? (find_applet_by_name(bb_basename(cmd)) >= 0) : -1);\n"
    "\n"
    "#if ENABLE_FEATURE_PREFER_APPLETS && NUM_APPLETS > 1\n"
    "\tif ((!has_path(cmd) || unix_path(cmd)) &&\n"
    "\t\t\tfind_applet_by_name(bb_basename(cmd)) >= 0)\n"
    "\t\treturn mingw_spawn_applet(mode, argv, NULL);\n"
    "#endif\n"
    "\tif (has_path(cmd)) {\n",
)

# ---- 2. mingw_spawnvp has_path branch (file_is_win32_exe result) -------
edit(
    "win32/process.c",
    "\tif (has_path(cmd)) {\n"
    "\t\tpath = file_is_win32_exe(cmd);\n"
    "\t\tif (path) {\n"
    "\t\t\tret = mingw_spawn_interpreter(mode, path, argv, NULL, 0);\n"
    "\t\t\tfree(path);\n"
    "\t\t\treturn ret;\n"
    "\t\t}\n"
    "\t\tif (unix_path(cmd))\n"
    "\t\t\tcmd = bb_basename(cmd);\n"
    "\t}\n"
    "\n"
    "\tif (!has_path(cmd) && (path = find_first_executable(cmd)) != NULL) {\n"
    "\t\tret = mingw_spawn_interpreter(mode, path, argv, NULL, 0);\n"
    "\t\tfree(path);\n"
    "\t\treturn ret;\n"
    "\t}\n"
    "\n"
    "\terrno = ENOENT;\n"
    "\treturn -1;\n"
    "}\n",
    "\tif (has_path(cmd)) {\n"
    "\t\tpath = file_is_win32_exe(cmd);\n"
    "\t\tbbdbg_log(\"SPAWN mingw_spawnvp has_path-branch cmd=\\\"%s\\\" \"\n"
    "\t\t\t\"file_is_win32_exe=\\\"%s\\\"\",\n"
    "\t\t\tcmd ? cmd : \"(null)\", path ? path : \"(null)\");\n"
    "\t\tif (path) {\n"
    "\t\t\tret = mingw_spawn_interpreter(mode, path, argv, NULL, 0);\n"
    "\t\t\tfree(path);\n"
    "\t\t\treturn ret;\n"
    "\t\t}\n"
    "\t\tif (unix_path(cmd))\n"
    "\t\t\tcmd = bb_basename(cmd);\n"
    "\t}\n"
    "\n"
    "\tif (!has_path(cmd)) {\n"
    "\t\tpath = find_first_executable(cmd);\n"
    "\t\tbbdbg_log(\"SPAWN mingw_spawnvp PATH-branch cmd=\\\"%s\\\" \"\n"
    "\t\t\t\"find_first_executable=\\\"%s\\\"\",\n"
    "\t\t\tcmd ? cmd : \"(null)\", path ? path : \"(null)\");\n"
    "\t\tif (path != NULL) {\n"
    "\t\t\tret = mingw_spawn_interpreter(mode, path, argv, NULL, 0);\n"
    "\t\t\tfree(path);\n"
    "\t\t\treturn ret;\n"
    "\t\t}\n"
    "\t}\n"
    "\n"
    "\tbbdbg_log(\"SPAWN mingw_spawnvp EXIT-ENOENT cmd=\\\"%s\\\"\",\n"
    "\t\tcmd ? cmd : \"(null)\");\n"
    "\terrno = ENOENT;\n"
    "\treturn -1;\n"
    "}\n",
)

# ---- 3. spawnveq stat-check : diagnostic replacement ------------------
edit(
    "win32/process.c",
    "\t/*\n"
    "\t * Require that the file exists, is a regular file and is executable.\n"
    "\t * It may still contain garbage but we let spawnve deal with that.\n"
    "\t */\n"
    "\tif (stat(path, &st) == 0) {\n"
    "\t\tif (!S_ISREG(st.st_mode) || !(st.st_mode&S_IXUSR)) {\n"
    "\t\t\terrno = EACCES;\n"
    "\t\t\treturn -1;\n"
    "\t\t}\n"
    "\t}\n"
    "\telse {\n"
    "\t\treturn -1;\n"
    "\t}\n",
    "\t/*\n"
    "\t * Require that the file exists, is a regular file and is executable.\n"
    "\t * It may still contain garbage but we let spawnve deal with that.\n"
    "\t */\n"
    "\t{\n"
    "\t\t/* patch 0011: spawn trace */\n"
    "\t\tint sret, serrno, sisreg, sixusr;\n"
    "\t\tunsigned smode;\n"
    "\t\terrno = 0;\n"
    "\t\tsret = stat(path, &st);\n"
    "\t\tserrno = errno;\n"
    "\t\tsmode = (sret == 0) ? (unsigned)st.st_mode : 0u;\n"
    "\t\tsisreg = (sret == 0) ? !!S_ISREG(st.st_mode) : -1;\n"
    "\t\tsixusr = (sret == 0) ? !!(st.st_mode & S_IXUSR) : -1;\n"
    "\t\tbbdbg_log(\"SPAWN spawnveq path=\\\"%s\\\" stat=%d errno=%d \"\n"
    "\t\t\t\"st_mode=0%o S_ISREG=%d S_IXUSR=%d\",\n"
    "\t\t\tpath ? path : \"(null)\", sret, serrno, smode,\n"
    "\t\t\tsisreg, sixusr);\n"
    "\t\tif (sret == 0) {\n"
    "\t\t\tif (!S_ISREG(st.st_mode) || !(st.st_mode&S_IXUSR)) {\n"
    "\t\t\t\tbbdbg_log(\"SPAWN spawnveq VERDICT=EACCES-mode path=\\\"%s\\\"\",\n"
    "\t\t\t\t\tpath ? path : \"(null)\");\n"
    "\t\t\t\terrno = EACCES;\n"
    "\t\t\t\treturn -1;\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "\t\telse {\n"
    "\t\t\tbbdbg_log(\"SPAWN spawnveq VERDICT=stat-failed errno=%d path=\\\"%s\\\"\",\n"
    "\t\t\t\tserrno, path ? path : \"(null)\");\n"
    "\t\t\terrno = serrno;\n"
    "\t\t\treturn -1;\n"
    "\t\t}\n"
    "\t}\n",
)


def main():
    src_root = Path("/work/src/busybox-w32")
    if not src_root.exists():
        sys.exit(f"error: source root {src_root} does not exist")

    work = Path("/tmp/bb-0011-edit")
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
        "/work/patches/busybox-w32/master/0011-bbdbg-spawn-instrumentation.patch"
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
        "Subject: [PATCH] process: instrument spawnvp + spawnveq for Win98 trace\n"
        "\n"
        "From inside busybox sh on Win98 SE, any non-applet binary invoked\n"
        "by PATH-relative name (ctags, make, gdb, muon, diff, patch, ...)\n"
        "fails with `permission denied`.  Full-path invocation works.\n"
        "bb-shim applets (ls, cp, vi, ...) short-circuit through\n"
        "mingw_spawn_applet and bypass the PATH walk + stat-check entirely,\n"
        "which is why they're unaffected.\n"
        "\n"
        "Add bbdbg_log() calls at three points in win32/process.c:\n"
        "  * mingw_spawnvp entry  -- cmd, has_path, unix_path, applet hit\n"
        "  * mingw_spawnvp per-branch  -- the path string returned by\n"
        "    file_is_win32_exe (has-path branch) and find_first_executable\n"
        "    (PATH branch), plus the ENOENT-exit case\n"
        "  * spawnveq stat-check  -- replace the if/else block with a\n"
        "    diagnostic version that records the stat rc, errno, st_mode\n"
        "    (S_ISREG and S_IXUSR bits broken out), and the verdict\n"
        "    (OK / EACCES-mode / stat-failed)\n"
        "\n"
        "All output goes to C:\\BBLOG.TXT via bbdbg_log (patch 0007).  No\n"
        "env gate -- spawn calls are low frequency compared to winansi\n"
        "writes so unconditional logging is cheap.  Depends on patch 0007;\n"
        "remove with 0007/0009 before shipping a stable release.\n"
        "\n"
        "---\n"
    )
    patch_text = header + "\n".join(chunks)
    patch_path.write_text(patch_text)
    print(f"\nwrote {patch_path} ({len(touched)} file(s), {len(patch_text)} bytes)")


if __name__ == "__main__":
    main()
