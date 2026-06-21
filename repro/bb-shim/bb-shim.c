/*
 * bb-shim — tiny re-exec stub for busybox applets on FAT32.
 *
 * FAT32 has no symlinks and no hardlinks, so the usual busybox convention
 * of one .exe per applet name (each a link back to busybox.exe, dispatched
 * via argv[0]) doesn't work on Win98.  Two alternatives — full copies of
 * busybox.exe per applet (~700 KB × N) and .bat wrappers (won't work from
 * inside busybox sh) — are both bad.  This shim is the third option: a
 * ~5–10 KB binary that reads its own filename, derives the applet name,
 * locates busybox.exe in the same directory, and spawns it.
 *
 * Build once, copy-rename per applet.  Works from command.com AND from
 * inside busybox sh (it's a real .exe, not a script).  Exit code propagates.
 *
 * Win98-clean: msvcrt-only, no Vista+ APIs.  PE-checked at build time.
 */

#include <windows.h>
#include <process.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *applet_name_from_exe(const char *exe_path, char *out, size_t out_sz)
{
    const char *bs = strrchr(exe_path, '\\');
    const char *fs = strrchr(exe_path, '/');
    const char *base = bs && (!fs || bs > fs) ? bs + 1 :
                       fs                     ? fs + 1 : exe_path;

    size_t len = strlen(base);
    if (len + 1 > out_sz) return NULL;
    memcpy(out, base, len + 1);

    char *dot = strrchr(out, '.');
    if (dot && _stricmp(dot, ".exe") == 0) *dot = '\0';

    /* Lowercase the applet name.  command.com on Win98 hands GetModuleFileName
     * back the 8.3 SHORT name in uppercase (e.g. C:\OPT\EXTRAS\BIN\LS.EXE),
     * even when the file's LFN is "ls.exe".  busybox's applet table is
     * case-sensitive and all entries are lowercase, so without this we'd
     * ask for applet "LS" and get "LS: applet not found". */
    _strlwr(out);
    return out;
}

int main(int argc, char **argv)
{
    char exe_path[MAX_PATH];
    DWORD len = GetModuleFileNameA(NULL, exe_path, sizeof(exe_path));
    if (len == 0 || len >= sizeof(exe_path)) {
        fprintf(stderr, "bb-shim: GetModuleFileName failed (err=%lu)\n",
                (unsigned long)GetLastError());
        return 1;
    }

    /* Resolve any 8.3 SHORT name components to their LFN form.  On Win98
     * FAT32, applet names longer than 8 characters get a generated 6+~1
     * short name (e.g. sha256sum.exe → SHA256~1.EXE); command.com hands
     * GetModuleFileName back the short form, and without this call we'd
     * derive applet name "sha256~1" and busybox would reject it.
     * GetLongPathNameA is in the Win98 SE allowlist. */
    char long_path[MAX_PATH];
    DWORD long_len = GetLongPathNameA(exe_path, long_path, sizeof(long_path));
    const char *resolved = (long_len > 0 && long_len < sizeof(long_path))
                           ? long_path : exe_path;

    char applet[64];
    if (!applet_name_from_exe(resolved, applet, sizeof(applet))) {
        fprintf(stderr, "bb-shim: applet name too long\n");
        return 1;
    }

    /* Build sibling busybox.exe path.  Use the LFN-resolved form so the
     * directory portion is consistent with what the user sees on disk. */
    char bb_path[MAX_PATH];
    size_t exe_len = strlen(resolved);
    if (exe_len >= sizeof(bb_path)) {
        fprintf(stderr, "bb-shim: exe path too long\n");
        return 1;
    }
    memcpy(bb_path, resolved, exe_len + 1);
    char *bb_bs = strrchr(bb_path, '\\');
    char *bb_fs = strrchr(bb_path, '/');
    char *bb_sep = bb_bs && (!bb_fs || bb_bs > bb_fs) ? bb_bs : bb_fs;
    if (!bb_sep) {
        /* No directory — execute "busybox.exe" via PATH search. */
        bb_sep = bb_path - 1;
    }
    if ((bb_sep - bb_path) + 1 + strlen("busybox.exe") + 1 > sizeof(bb_path)) {
        fprintf(stderr, "bb-shim: assembled busybox.exe path too long\n");
        return 1;
    }
    strcpy(bb_sep + 1, "busybox.exe");

    /* New argv: [busybox.exe, applet, argv[1..]] — busybox dispatches on argv[1]
     * the same way it does on POSIX when argv[0] is a known applet symlink. */
    const char **new_argv = (const char **)malloc(sizeof(char *) * (argc + 2));
    if (!new_argv) {
        fprintf(stderr, "bb-shim: out of memory\n");
        return 1;
    }
    new_argv[0] = bb_path;
    new_argv[1] = applet;
    for (int i = 1; i < argc; i++) new_argv[i + 1] = argv[i];
    new_argv[argc + 1] = NULL;

    /* _P_WAIT: spawn child synchronously, propagate exit code.  Avoids the
     * Windows _execv pitfall where the parent terminates before the child
     * completes (which would let cmd.com print its prompt before the
     * applet finishes).  Returns the child's exit code as intptr_t. */
    intptr_t rc = _spawnv(_P_WAIT, bb_path, new_argv);
    if (rc == -1) {
        fprintf(stderr, "bb-shim: spawn %s failed: ", bb_path);
        perror(NULL);
        free(new_argv);
        return 1;
    }
    free(new_argv);
    return (int)rc;
}
