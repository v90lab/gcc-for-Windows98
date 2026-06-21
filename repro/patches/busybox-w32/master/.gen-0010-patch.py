#!/usr/bin/env python3
"""
Regenerator for 0010-winansi-vsnprintf-fix-win9x.patch.

Background:
  Round-5 BBLOG.TXT (consdiag/run_5/BBLOG.TXT) proved that backspace and
  `ls --color` raw-escape symptoms are caused by winansi_vsnprintf, not
  by any of the patches 0005-0008.  Trace shows:

    winansi_vfprintf-entry fd=1 ... hex=[1b 5b 25 75 3b 25 75 6d]
    (no follow-up winansi_vfprintf-rendered, no follow-up ansi_emulate)

  The format string is logged at entry, then control silently goes to
  `goto abort` (which calls real libc vfprintf, bypassing ansi_emulate).

Root cause (two stacked bugs):
  1. winansi_vsnprintf calls `_vsnprintf(NULL, 0, format, list)` to probe
     the would-be-written length.  That's a Windows 7+ msvcrt extension;
     on Win98 SE's msvcrt it returns -1.

  2. The return value is assigned to `size_t len`, so -1 becomes SIZE_MAX.
     The guard `if (len < 0)` is unreachable (size_t is unsigned).  The
     function then writes the actual buffer correctly via _vsnprintf(buf,
     size, ...) but returns SIZE_MAX -- which casts to -1 on the int
     return.  winansi_vfprintf sees -1 and either goes straight to abort
     OR enters the "need bigger buffer" branch which calls xmalloc(0)
     and a second vsnprintf with size 0 (writes past buf[-1]).  Either
     way the rendered output never reaches ansi_emulate.

Fix:
  Replace winansi_vsnprintf with an implementation that doesn't depend on
  the (NULL, 0) length-probe.  Try the caller's buffer first; if
  _vsnprintf returns -1 (truncation), grow a scratch buffer until it
  fits, and return the true length.

  Also add a defensive `if (len == -1) goto abort;` after the first
  vsnprintf call in winansi_vfprintf -- with the new winansi_vsnprintf
  this should only fire on real errors (OOM, format > 16MB), but it
  hardens the path against the `len > sizeof(small_buf) - 1` signed/
  unsigned comparison trap that the original code falls into when len
  is -1.

Two edits, both in win32/winansi.c.

Usage (run inside the toolchain-builder container):
    cd /work/src/busybox-w32
    # ensure 0001-0009 are applied
    python3 /work/patches/busybox-w32/master/.gen-0010-patch.py
"""
import subprocess
import sys
from pathlib import Path

EDITS = []


def edit(src, old, new):
    EDITS.append((Path(src), old, new))


# ---- 1. win32/winansi.c : rewrite winansi_vsnprintf ---------------------
edit(
    "win32/winansi.c",
    "int FAST_FUNC\n"
    "winansi_vsnprintf(char *buf, size_t size, const char *format, va_list list)\n"
    "{\n"
    "\tsize_t len;\n"
    "\tva_list list2;\n"
    "\n"
    "\tva_copy(list2, list);\n"
    "\tlen = _vsnprintf(NULL, 0, format, list2);\n"
    "\tva_end(list2);\n"
    "\tif (len < 0)\n"
    "\t\treturn -1;\n"
    "\n"
    "\t_vsnprintf(buf, size, format, list);\n"
    "\tbuf[size-1] = '\\0';\n"
    "\treturn len;\n"
    "}\n",
    "int FAST_FUNC\n"
    "winansi_vsnprintf(char *buf, size_t size, const char *format, va_list list)\n"
    "{\n"
    "\t/* Original code probed length with _vsnprintf(NULL, 0, ...) -- a\n"
    "\t * Windows 7+ msvcrt extension that returns -1 on Win98 SE msvcrt.\n"
    "\t * That cascaded into winansi_vfprintf's `goto abort` path (since\n"
    "\t * the original assigned _vsnprintf's int return into a size_t,\n"
    "\t * making the `if (len < 0)` guard unreachable but still surfacing\n"
    "\t * SIZE_MAX -> -1 to the caller), causing backspace + ls --color\n"
    "\t * raw escapes on Win98.  Strategy: try the caller's buffer first;\n"
    "\t * on truncation, grow a scratch buffer until _vsnprintf fits and\n"
    "\t * return the true length.  Patch 0010 (round 5 BBLOG.TXT proof). */\n"
    "\tva_list list2;\n"
    "\tint len = -1;\n"
    "\tsize_t probe;\n"
    "\tchar *scratch;\n"
    "\n"
    "\tif (buf != NULL && size > 0) {\n"
    "\t\tva_copy(list2, list);\n"
    "\t\tlen = _vsnprintf(buf, size, format, list2);\n"
    "\t\tva_end(list2);\n"
    "\t\tbuf[size - 1] = '\\0';\n"
    "\t\tif (len >= 0 && (size_t)len < size)\n"
    "\t\t\treturn len;\n"
    "\t}\n"
    "\n"
    "\tprobe = (size > 256) ? size * 2 : 512;\n"
    "\tfor (;;) {\n"
    "\t\tscratch = malloc(probe);\n"
    "\t\tif (scratch == NULL)\n"
    "\t\t\treturn -1;\n"
    "\t\tva_copy(list2, list);\n"
    "\t\tlen = _vsnprintf(scratch, probe, format, list2);\n"
    "\t\tva_end(list2);\n"
    "\t\tif (len >= 0 && (size_t)len < probe) {\n"
    "\t\t\tif (buf != NULL && size > 0) {\n"
    "\t\t\t\tsize_t copy;\n"
    "\t\t\t\tcopy = ((size_t)len < size - 1) ? (size_t)len : size - 1;\n"
    "\t\t\t\tmemcpy(buf, scratch, copy);\n"
    "\t\t\t\tbuf[copy] = '\\0';\n"
    "\t\t\t}\n"
    "\t\t\tfree(scratch);\n"
    "\t\t\treturn len;\n"
    "\t\t}\n"
    "\t\tfree(scratch);\n"
    "\t\tprobe *= 2;\n"
    "\t\tif (probe > 16u * 1024u * 1024u)\n"
    "\t\t\treturn -1;\n"
    "\t}\n"
    "}\n",
)

# ---- 2. win32/winansi.c : winansi_vfprintf -- defensive -1 check --------
# After the first vsnprintf into small_buf, bail to abort on -1 BEFORE
# the `len > sizeof(small_buf) - 1` size_t comparison (which would
# otherwise treat -1 as SIZE_MAX and enter the malloc branch with
# xmalloc(0) + second vsnprintf(buf, 0, ...)).  With the new
# winansi_vsnprintf this rarely fires, but the original code is
# defenseless here so we close it.
edit(
    "win32/winansi.c",
    "\tva_copy(cp, list);\n"
    "\tlen = vsnprintf(small_buf, sizeof(small_buf), format, cp);\n"
    "\tva_end(cp);\n"
    "\n"
    "\tif (len > sizeof(small_buf) - 1) {\n",
    "\tva_copy(cp, list);\n"
    "\tlen = vsnprintf(small_buf, sizeof(small_buf), format, cp);\n"
    "\tva_end(cp);\n"
    "\n"
    "\tif (len == -1)\n"
    "\t\tgoto abort;\n"
    "\n"
    "\tif (len > sizeof(small_buf) - 1) {\n",
)


def main():
    src_root = Path("/work/src/busybox-w32")
    if not src_root.exists():
        sys.exit(f"error: source root {src_root} does not exist")

    work = Path("/tmp/bb-0010-edit")
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
            sys.exit(f"error: anchor not found in {relpath}\n--- expected ---\n{old}\n----------------")

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

    patch_path = Path("/work/patches/busybox-w32/master/0010-winansi-vsnprintf-fix-win9x.patch")
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
        "Subject: [PATCH] winansi: fix vsnprintf length-probe for Win9x msvcrt\n"
        "\n"
        "Win98 SE msvcrt's _vsnprintf does not support the (NULL, 0) length\n"
        "probe -- it returns -1 instead of the would-be-written length (which\n"
        "is a Windows 7+ extension).  busybox-w32's winansi_vsnprintf depends\n"
        "on that probe and on top stores the int return in a size_t, making\n"
        "its `if (len < 0)` guard unreachable.  Net effect: the function\n"
        "returns -1, winansi_vfprintf treats that as `buffer too small`,\n"
        "calls xmalloc(0) + _vsnprintf(buf, 0, ...), still gets -1, and\n"
        "goto-aborts to the real libc vfprintf -- which writes raw output\n"
        "to the FILE* WITHOUT going through ansi_emulate.  That's why on\n"
        "Win98 SE typing Backspace in sh prints `<-[1D` and `ls --color`\n"
        "emits raw color codes despite patch 0005 forcing terminal_mode=0.\n"
        "Round 5 BBLOG.TXT (consdiag/run_5) is the proof: every\n"
        "winansi_vfprintf-entry log for a format string carrying \\e[...\n"
        "has NO follow-up winansi_vfprintf-rendered / ansi_emulate log.\n"
        "Plain-text writes via winansi_fputs (no vsnprintf in the path)\n"
        "always reach ansi_emulate and render correctly.\n"
        "\n"
        "Replace winansi_vsnprintf with an implementation that doesn't need\n"
        "the (NULL, 0) probe: try the caller's buffer first; on truncation,\n"
        "grow a scratch buffer until _vsnprintf fits.  Also harden\n"
        "winansi_vfprintf to bail on -1 BEFORE the size_t comparison that\n"
        "would otherwise wrap -1 to SIZE_MAX and enter the broken malloc\n"
        "path.  Both edits live in win32/winansi.c.\n"
        "\n"
        "---\n"
    )
    patch_text = header + "\n".join(chunks)
    patch_path.write_text(patch_text)
    print(f"\nwrote {patch_path} ({len(touched)} file(s), {len(patch_text)} bytes)")


if __name__ == "__main__":
    main()
