#!/usr/bin/env python3
# Regenerates 0004-forkshell-named-mapping.patch.
#
# Run inside the toolchain-builder container, against a clean
# /work/src/busybox-w32 checkout (revert via git if you've applied this
# patch already).  Anchor-based splice; emits unified diff via `git diff`.

import os, subprocess, sys, shutil, pathlib

SRC = "/work/src/busybox-w32/shell/ash.c"
PATCH_OUT = "/work/patches/busybox-w32/master/0004-forkshell-named-mapping.patch"

EDITS = [
    # (old, new)
    (
        "static struct forkshell* forkshell_prepare(struct forkshell *fs);",
        "static struct forkshell* forkshell_prepare(struct forkshell *fs, char *map_name_out);",
    ),
    (
        """static void
spawn_forkshell(struct forkshell *fs, struct job *jp, union node *n, int mode)
{
\tstruct forkshell *new;
\tchar buf[32];
\tconst char *argv[] = { "sh", "--fs", NULL, NULL };
\tintptr_t ret;

\tnew = forkshell_prepare(fs);
\tif (new == NULL)
\t\tgoto fail;

\tnew->mode = mode;
\tnew->nprocs = jp == NULL ? 0 : jp->nprocs;
#if JOBS_WIN32
\tnew->jpnull = jp == NULL;
#endif
\tsprintf(buf, "%p", new->hMapFile);
\targv[2] = buf;
\tret = mingw_spawn_applet(P_NOWAIT, (char *const *)argv, NULL);""",
        """static void
spawn_forkshell(struct forkshell *fs, struct job *jp, union node *n, int mode)
{
\tstruct forkshell *new;
\tchar map_name[64];
\tconst char *argv[] = { "sh", "--fs", map_name, NULL };
\tintptr_t ret;

\tnew = forkshell_prepare(fs, map_name);
\tif (new == NULL)
\t\tgoto fail;

\tnew->mode = mode;
\tnew->nprocs = jp == NULL ? 0 : jp->nprocs;
#if JOBS_WIN32
\tnew->jpnull = jp == NULL;
#endif
\tret = mingw_spawn_applet(P_NOWAIT, (char *const *)argv, NULL);""",
    ),
    (
        """static struct forkshell *
forkshell_prepare(struct forkshell *fs)
{
\tstruct forkshell *new;
\tstruct datasize ds;
\tint size, relocatesize, bitmapsize;
\tHANDLE h;
\tSECURITY_ATTRIBUTES sa;""",
        """static struct forkshell *
forkshell_prepare(struct forkshell *fs, char *map_name_out)
{
\tstruct forkshell *new;
\tstruct datasize ds;
\tint size, relocatesize, bitmapsize;
\tHANDLE h;
\tSECURITY_ATTRIBUTES sa;
\tstatic unsigned fs_counter = 0;""",
    ),
    (
        """\tsa.bInheritHandle = TRUE;
\th = CreateFileMapping(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE, 0,
\t\t\tsize+bitmapsize, NULL);""",
        """\tsa.bInheritHandle = TRUE;
\t/* Use a NAMED file mapping.  On Win9x, unnamed mapping handles aren't
\t * shareable across CreateProcess by raw HANDLE value (the value is
\t * per-process and not inherited at the same numeric slot), so the
\t * child cannot MapViewOfFile the parent's handle even though it was
\t * created inheritable.  A named mapping lives in a cross-process
\t * namespace and the child opens it by name.  bInheritHandle=TRUE
\t * still gives refcount keepalive across the parent's CloseHandle on
\t * NT (via inheritance through spawnve's CreateProcess call). */
\tsprintf(map_name_out, "busybox-fs-%lu-%u",
\t\t(unsigned long)GetCurrentProcessId(), ++fs_counter);
\th = CreateFileMapping(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE, 0,
\t\t\tsize+bitmapsize, map_name_out);""",
    ),
    (
        """forkshell_init(const char *idstr)
{
\tstruct forkshell *fs;
\tvoid *map_handle;
\tHANDLE h;
\tint i;
\tchar **ptr;
\tchar *lrelocate;

\tif (sscanf(idstr, "%p", &map_handle) != 1)
\t\treturn;

\th = (HANDLE)map_handle;
\tfs = (struct forkshell *)MapViewOfFile(h, FILE_MAP_WRITE, 0,0, 0);
\tif (!fs)
\t\treturn;""",
        """forkshell_init(const char *idstr)
{
\tstruct forkshell *fs;
\tHANDLE h;
\tint i;
\tchar **ptr;
\tchar *lrelocate;

\t/* idstr is the named-mapping name produced by forkshell_prepare in
\t * the parent.  OpenFileMapping by name works on both NT and Win9x;
\t * the previous mechanism (handle value passed as hex through argv)
\t * is NT-only because Win9x HANDLE values are not cross-process. */
\th = OpenFileMapping(FILE_MAP_WRITE, FALSE, idstr);
\tif (!h)
\t\treturn;
\tfs = (struct forkshell *)MapViewOfFile(h, FILE_MAP_WRITE, 0, 0, 0);
\tif (!fs)
\t\treturn;""",
    ),
]


def main():
    src_dir = pathlib.Path(SRC).parent.parent
    src = pathlib.Path(SRC).read_text()
    for i, (old, new) in enumerate(EDITS, 1):
        cnt = src.count(old)
        if cnt != 1:
            sys.exit(f"ERROR: edit #{i} anchor count {cnt} (expected 1)")
        src = src.replace(old, new)
    pathlib.Path(SRC).write_text(src)
    print(f"applied {len(EDITS)} edits to ash.c")

    rel = "shell/ash.c"
    diff = subprocess.run(
        ["git", "-C", str(src_dir), "diff", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", rel],
        capture_output=True, text=True, check=True,
    ).stdout
    if not diff.strip():
        sys.exit("ERROR: empty diff from git")
    os.makedirs(os.path.dirname(PATCH_OUT), exist_ok=True)
    with open(PATCH_OUT, "w", newline="\n") as f:
        f.write(diff)
    print(f"wrote {PATCH_OUT} ({len(diff.splitlines())} lines)")


if __name__ == "__main__":
    main()
