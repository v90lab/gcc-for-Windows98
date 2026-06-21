#!/usr/bin/env python3
"""
Regenerator for 0009-bbdbg-wansi-instrumentation.patch.

Background:
  Round 4 confirmed the sh hang is fixed (patch 0008).  Remaining Win98
  bugs: backspace prints raw `<-[1D` (literal CSI cursor-back) and
  `ls --color` emits raw ANSI color escapes.  Both symptoms point to the
  ANSI-to-Console-API translator in win32/winansi.c either getting
  bypassed or taking the wrong branch.

  ansi_emulate / ansi_emulate_write gate console-API translation on
  `!(terminal_mode(FALSE) & VT_OUTPUT)`.  On Win9x patch 0005 forces
  mode=0 (VT_OUTPUT bit clear) so the console-API branch should fire and
  the escape should be interpreted.  But we're seeing raw escapes, so
  one of these is true:
    - `is_console(fd)` returns false -> winansi_X falls back to raw fwrite
    - `terminal_mode(FALSE) & VT_OUTPUT` is set -> VT pass-through wins
    - The escapes are written via a path that bypasses winansi entirely
    - is_win9x() returns false on real Win98 (Wine returns true; we never
      confirmed on a real DOS box)

  Instrument winansi.c to log every write entry + the branch decision,
  so the BBLOG.TXT from a round-5 test pinpoints which of these is
  happening.

Edits:
  1. After is_win9x() : add wansi_log_enabled(), wansi_log_busy guard,
     wansi_log(), wansi_log_startup_once() helpers.
  2. winansi_write     : log entry.
  3. winansi_fwrite    : log entry.
  4. winansi_fputs     : log entry.
  5. winansi_fputc     : log entry (every char, including ASCII).
  6. winansi_vfprintf  : log entry + log post-vsnprintf rendered buf.
  7. ansi_emulate      : log early-out + per-iter console-api / vt-pass.
  8. ansi_emulate_write: same three branch logs.

  Gated on `BB_WANSI_LOG` env var so casual sh use stays quiet.
  Recursion-guarded so bbdbg_log's own fprintf going back through
  winansi_fprintf doesn't infinite-loop.

  Depends on patch 0007 for bbdbg_log() infrastructure -- 0007 must
  precede 0009 in series.txt.

Usage (run inside the toolchain-builder container, with 0001-0008
applied on top of HEAD):
    python3 /work/patches/busybox-w32/master/.gen-0009-patch.py
"""
import subprocess
import sys
from pathlib import Path

EDITS = []


def edit(src, old, new):
    EDITS.append((Path(src), old, new))


# ---- 1. winansi.c : helpers, right after is_win9x() ---------------------
edit(
    "win32/winansi.c",
    "static int is_win9x(void)\n"
    "{\n"
    "\tstatic int cached = -1;\n"
    "\tif (cached == -1) {\n"
    "\t\tOSVERSIONINFOA osvi;\n"
    "\t\tosvi.dwOSVersionInfoSize = sizeof(osvi);\n"
    "\t\tcached = GetVersionExA(&osvi) &&\n"
    "\t\t\t osvi.dwPlatformId == VER_PLATFORM_WIN32_WINDOWS;\n"
    "\t}\n"
    "\treturn cached;\n"
    "}\n",
    "static int is_win9x(void)\n"
    "{\n"
    "\tstatic int cached = -1;\n"
    "\tif (cached == -1) {\n"
    "\t\tOSVERSIONINFOA osvi;\n"
    "\t\tosvi.dwOSVersionInfoSize = sizeof(osvi);\n"
    "\t\tcached = GetVersionExA(&osvi) &&\n"
    "\t\t\t osvi.dwPlatformId == VER_PLATFORM_WIN32_WINDOWS;\n"
    "\t}\n"
    "\treturn cached;\n"
    "}\n"
    "\n"
    "/* === BEGIN patch 0009: winansi write-path instrumentation ===\n"
    " * Logs every winansi entry-point + the branch decision inside\n"
    " * ansi_emulate{,_write} to C:\\BBLOG.TXT (via bbdbg_log from patch\n"
    " * 0007).  Gated on `BB_WANSI_LOG` env var so casual sh use stays\n"
    " * quiet.  Recursion guard prevents bbdbg_log's own fprintf to\n"
    " * BBLOG -> winansi_fprintf -> wansi_log -> bbdbg_log infinite loop\n"
    " * when the helper itself reaches the macro-redirected stdio path.\n"
    " */\n"
    "static int wansi_log_enabled(void)\n"
    "{\n"
    "\tstatic int cached = -1;\n"
    "\tif (cached == -1)\n"
    "\t\tcached = getenv(\"BB_WANSI_LOG\") != NULL;\n"
    "\treturn cached;\n"
    "}\n"
    "\n"
    "static int wansi_log_busy = 0;\n"
    "\n"
    "static void wansi_log(const char *func, int fd, const void *buf,\n"
    "\t\t\t\tsize_t count, const char *branch)\n"
    "{\n"
    "\tint isatty_r, iscon, mode;\n"
    "\tchar preview[3*16 + 1];\n"
    "\tconst unsigned char *p = (const unsigned char *)buf;\n"
    "\tsize_t n, i;\n"
    "\n"
    "\tif (!wansi_log_enabled() || wansi_log_busy)\n"
    "\t\treturn;\n"
    "\twansi_log_busy = 1;\n"
    "\tisatty_r = (fd >= 0) ? mingw_isatty(fd) : 0;\n"
    "\tiscon = (fd >= 0) ? is_console(fd) : 0;\n"
    "\tmode = terminal_mode(FALSE);\n"
    "\tpreview[0] = '\\0';\n"
    "\tn = count < 16 ? count : 16;\n"
    "\tfor (i = 0; i < n; i++)\n"
    "\t\tsprintf(preview + i*3, \"%02x \", p[i]);\n"
    "\tbbdbg_log(\"WANSI %s fd=%d cnt=%lu isatty=%d iscon=%d mode=%d \"\n"
    "\t\t\"vtout=%d branch=%s hex=[%s]\",\n"
    "\t\tfunc, fd, (unsigned long)count, isatty_r, iscon, mode,\n"
    "\t\t(mode & VT_OUTPUT) != 0, branch ? branch : \"-\", preview);\n"
    "\twansi_log_busy = 0;\n"
    "}\n"
    "\n"
    "static void wansi_log_startup_once(void)\n"
    "{\n"
    "\tstatic int done = 0;\n"
    "\tconst char *tm, *skip;\n"
    "\tOSVERSIONINFOA osvi;\n"
    "\n"
    "\tif (done || !wansi_log_enabled())\n"
    "\t\treturn;\n"
    "\tdone = 1;\n"
    "\twansi_log_busy = 1;\n"
    "\ttm = getenv(\"BB_TERMINAL_MODE\");\n"
    "\tskip = getenv(\"BB_SKIP_ANSI_EMULATION\");\n"
    "\tosvi.dwOSVersionInfoSize = sizeof(osvi);\n"
    "\tif (!GetVersionExA(&osvi)) {\n"
    "\t\tosvi.dwPlatformId = 0;\n"
    "\t\tosvi.dwMajorVersion = 0;\n"
    "\t\tosvi.dwMinorVersion = 0;\n"
    "\t\tosvi.dwBuildNumber = 0;\n"
    "\t}\n"
    "\tbbdbg_log(\"WANSI startup BB_TERMINAL_MODE=%s BB_SKIP_ANSI_EMULATION=%s \"\n"
    "\t\t\"platformId=%lu (is_win9x=%d) ver=%lu.%lu build=%lu \"\n"
    "\t\t\"CONFIG_TERMINAL_MODE=%d cur_mode=%d\",\n"
    "\t\ttm ? tm : \"(null)\", skip ? skip : \"(null)\",\n"
    "\t\t(unsigned long)osvi.dwPlatformId,\n"
    "\t\tosvi.dwPlatformId == VER_PLATFORM_WIN32_WINDOWS,\n"
    "\t\t(unsigned long)osvi.dwMajorVersion,\n"
    "\t\t(unsigned long)osvi.dwMinorVersion,\n"
    "\t\t(unsigned long)osvi.dwBuildNumber,\n"
    "\t\tCONFIG_TERMINAL_MODE, terminal_mode(FALSE));\n"
    "\twansi_log_busy = 0;\n"
    "}\n"
    "/* === END patch 0009 === */\n",
)

# ---- 2. winansi_write entry --------------------------------------------
edit(
    "win32/winansi.c",
    "int FAST_FUNC winansi_write(int fd, const void *buf, size_t count)\n"
    "{\n"
    "\tif (!is_console(fd)) {\n",
    "int FAST_FUNC winansi_write(int fd, const void *buf, size_t count)\n"
    "{\n"
    "\twansi_log_startup_once();\n"
    "\twansi_log(\"winansi_write\", fd, buf, count, NULL);\n"
    "\tif (!is_console(fd)) {\n",
)

# ---- 3. winansi_fwrite entry -------------------------------------------
edit(
    "win32/winansi.c",
    "size_t FAST_FUNC\n"
    "winansi_fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream)\n"
    "{\n"
    "\tsize_t lsize, lmemb, ret;\n"
    "\tchar *str;\n"
    "\tint rv;\n"
    "\n"
    "\tlsize = MIN(size, nmemb);\n",
    "size_t FAST_FUNC\n"
    "winansi_fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream)\n"
    "{\n"
    "\tsize_t lsize, lmemb, ret;\n"
    "\tchar *str;\n"
    "\tint rv;\n"
    "\n"
    "\twansi_log_startup_once();\n"
    "\twansi_log(\"winansi_fwrite\", fileno(stream), ptr, size * nmemb, NULL);\n"
    "\tlsize = MIN(size, nmemb);\n",
)

# ---- 4. winansi_fputs entry --------------------------------------------
edit(
    "win32/winansi.c",
    "int FAST_FUNC winansi_fputs(const char *str, FILE *stream)\n"
    "{\n"
    "\tint ret;\n"
    "\n"
    "\tif (!is_console(fileno(stream))) {\n",
    "int FAST_FUNC winansi_fputs(const char *str, FILE *stream)\n"
    "{\n"
    "\tint ret;\n"
    "\n"
    "\twansi_log_startup_once();\n"
    "\twansi_log(\"winansi_fputs\", fileno(stream), str, strlen(str), NULL);\n"
    "\tif (!is_console(fileno(stream))) {\n",
)

# ---- 5. winansi_fputc entry --------------------------------------------
edit(
    "win32/winansi.c",
    "int FAST_FUNC winansi_fputc(int c, FILE *stream)\n"
    "{\n"
    "\tint ret;\n"
    "\tchar t = c;\n"
    "\tchar *s = &t;\n"
    "\n"
    "\tif ((unsigned char)c <= 0x7f || !is_console(fileno(stream))) {\n",
    "int FAST_FUNC winansi_fputc(int c, FILE *stream)\n"
    "{\n"
    "\tint ret;\n"
    "\tchar t = c;\n"
    "\tchar *s = &t;\n"
    "\n"
    "\twansi_log_startup_once();\n"
    "\twansi_log(\"winansi_fputc\", fileno(stream), &t, 1, NULL);\n"
    "\tif ((unsigned char)c <= 0x7f || !is_console(fileno(stream))) {\n",
)

# ---- 6a. winansi_vfprintf entry ----------------------------------------
edit(
    "win32/winansi.c",
    "int FAST_FUNC winansi_vfprintf(FILE *stream, const char *format, va_list list)\n"
    "{\n"
    "\tint len, rv;\n"
    "\tchar small_buf[256];\n"
    "\tchar *buf = small_buf;\n"
    "\tva_list cp;\n"
    "\n"
    "\tif (!is_console(fileno(stream)))\n"
    "\t\tgoto abort;\n",
    "int FAST_FUNC winansi_vfprintf(FILE *stream, const char *format, va_list list)\n"
    "{\n"
    "\tint len, rv;\n"
    "\tchar small_buf[256];\n"
    "\tchar *buf = small_buf;\n"
    "\tva_list cp;\n"
    "\n"
    "\twansi_log_startup_once();\n"
    "\twansi_log(\"winansi_vfprintf-entry\", fileno(stream),\n"
    "\t\tformat, strlen(format), NULL);\n"
    "\tif (!is_console(fileno(stream)))\n"
    "\t\tgoto abort;\n",
)

# ---- 6b. winansi_vfprintf post-vsnprintf -------------------------------
edit(
    "win32/winansi.c",
    "\tif (len == -1)\n"
    "\t\tgoto abort;\n"
    "\n"
    "\trv = ansi_emulate(buf, stream);\n",
    "\tif (len == -1)\n"
    "\t\tgoto abort;\n"
    "\n"
    "\twansi_log(\"winansi_vfprintf-rendered\", fileno(stream),\n"
    "\t\tbuf, (size_t)len, NULL);\n"
    "\trv = ansi_emulate(buf, stream);\n",
)

# ---- 7a. ansi_emulate early-out ----------------------------------------
edit(
    "win32/winansi.c",
    "\tif ( *t == '\\0' ) {\n"
    "\t\treturn fputs(s, stream) == EOF ? EOF : strlen(s);\n"
    "\t}\n",
    "\tif ( *t == '\\0' ) {\n"
    "\t\twansi_log(\"ansi_emulate\", fileno(stream), s, strlen(s),\n"
    "\t\t\t\"early-out-no-special\");\n"
    "\t\treturn fputs(s, stream) == EOF ? EOF : strlen(s);\n"
    "\t}\n",
)

# ---- 7b. ansi_emulate console-api branch -------------------------------
# NB: wansi_log call must come AFTER the `size_t len = pos - str;` decl,
# busybox builds with -Wdeclaration-after-statement.
edit(
    "win32/winansi.c",
    "\twhile (*pos) {\n"
    "\t\tpos = strchr(str, '\\033');\n"
    "\t\tif (pos && !(terminal_mode(FALSE) & VT_OUTPUT)) {\n"
    "\t\t\tsize_t len = pos - str;\n"
    "\n"
    "\t\t\tif (len) {\n",
    "\twhile (*pos) {\n"
    "\t\tpos = strchr(str, '\\033');\n"
    "\t\tif (pos && !(terminal_mode(FALSE) & VT_OUTPUT)) {\n"
    "\t\t\tsize_t len = pos - str;\n"
    "\n"
    "\t\t\twansi_log(\"ansi_emulate\", fileno(stream), str,\n"
    "\t\t\t\tstrlen(str), \"esc-via-console-api\");\n"
    "\t\t\tif (len) {\n",
)

# ---- 7c. ansi_emulate vt-passthrough / tail-plain branch ---------------
edit(
    "win32/winansi.c",
    "\t\t} else {\n"
    "\t\t\tsize_t len = strlen(str);\n"
    "\t\t\trv += len;\n"
    "\t\t\treturn conv_fwriteCon(stream, str, len) == EOF ? EOF : rv;\n"
    "\t\t}\n"
    "\t}\n"
    "\treturn rv;\n"
    "}\n",
    "\t\t} else {\n"
    "\t\t\tsize_t len = strlen(str);\n"
    "\t\t\twansi_log(\"ansi_emulate\", fileno(stream), str, len,\n"
    "\t\t\t\tpos ? \"esc-via-vt-passthrough\" : \"tail-plain\");\n"
    "\t\t\trv += len;\n"
    "\t\t\treturn conv_fwriteCon(stream, str, len) == EOF ? EOF : rv;\n"
    "\t\t}\n"
    "\t}\n"
    "\treturn rv;\n"
    "}\n",
)

# ---- 8a. ansi_emulate_write early-out ----------------------------------
edit(
    "win32/winansi.c",
    "\tif ( !special || has_null ) {\n"
    "\t\treturn write(fd, buf, count);\n"
    "\t}\n",
    "\tif ( !special || has_null ) {\n"
    "\t\twansi_log(\"ansi_emulate_write\", fd, buf, count,\n"
    "\t\t\t\"early-out-no-special\");\n"
    "\t\treturn write(fd, buf, count);\n"
    "\t}\n",
)

# ---- 8b. ansi_emulate_write console-api branch -------------------------
edit(
    "win32/winansi.c",
    "\twhile (*pos) {\n"
    "\t\tpos = strchr(str, '\\033');\n"
    "\t\tif (pos && !(terminal_mode(FALSE) & VT_OUTPUT)) {\n"
    "\t\t\tlen = pos - str;\n",
    "\twhile (*pos) {\n"
    "\t\tpos = strchr(str, '\\033');\n"
    "\t\tif (pos && !(terminal_mode(FALSE) & VT_OUTPUT)) {\n"
    "\t\t\twansi_log(\"ansi_emulate_write\", fd, str, strlen(str),\n"
    "\t\t\t\t\"esc-via-console-api\");\n"
    "\t\t\tlen = pos - str;\n",
)

# ---- 8c. ansi_emulate_write vt-passthrough / tail-plain branch ---------
edit(
    "win32/winansi.c",
    "\t\t} else {\n"
    "\t\t\tlen = strlen(str);\n"
    "\t\t\tout_len = conv_writeCon(fd, str, len);\n"
    "\t\t\treturn (out_len == -1) ? -1 : rv+out_len;\n"
    "\t\t}\n"
    "\t}\n"
    "\treturn rv;\n"
    "}\n",
    "\t\t} else {\n"
    "\t\t\tlen = strlen(str);\n"
    "\t\t\twansi_log(\"ansi_emulate_write\", fd, str, len,\n"
    "\t\t\t\tpos ? \"esc-via-vt-passthrough\" : \"tail-plain\");\n"
    "\t\t\tout_len = conv_writeCon(fd, str, len);\n"
    "\t\t\treturn (out_len == -1) ? -1 : rv+out_len;\n"
    "\t\t}\n"
    "\t}\n"
    "\treturn rv;\n"
    "}\n",
)


def main():
    src_root = Path("/work/src/busybox-w32")
    if not src_root.exists():
        sys.exit(f"error: source root {src_root} does not exist")

    # Backup the originals before editing -- enables `diff -uN` reconstruction.
    work = Path("/tmp/bb-0009-edit")
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
            sys.exit(
                f"error: anchor not found in {relpath}\n"
                f"--- expected ---\n{old}\n----------------"
            )

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
    patch_path = Path(
        "/work/patches/busybox-w32/master/0009-bbdbg-wansi-instrumentation.patch"
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
        "Subject: [PATCH] winansi: instrument write paths to trace raw-escape bug\n"
        "\n"
        "Round-4 fixed the sh hang.  Remaining Win98 symptoms: backspace\n"
        "prints raw `<-[1D` and `ls --color` emits raw color escapes.\n"
        "Both indicate the ANSI-to-Console-API translator in winansi.c is\n"
        "either bypassed or taking the wrong branch.  Add bbdbg_log()\n"
        "calls at every winansi entry point and at the ansi_emulate /\n"
        "ansi_emulate_write branch decisions, gated on BB_WANSI_LOG, so a\n"
        "round-5 BBLOG.TXT can pinpoint which fork is happening.  Also\n"
        "log the startup state (env vars, GetVersionEx platform/version,\n"
        "terminal_mode result) so we can confirm patch 0005's mode=0\n"
        "branch is firing on real Win9x and is_console() is returning\n"
        "true for stdout/stderr.\n"
        "\n"
        "Depends on patch 0007 for the bbdbg_log() helper.  Both 0007 and\n"
        "0009 should be removed from series.txt before shipping a stable\n"
        "release.\n"
        "\n"
        "---\n"
    )
    patch_text = header + "\n".join(chunks)
    patch_path.write_text(patch_text)
    print(f"\nwrote {patch_path} ({len(touched)} file(s), {len(patch_text)} bytes)")


if __name__ == "__main__":
    main()
