#!/usr/bin/env python3
# ============================================================================
# generate-win98-api-allowlist.py — emit a JSON snapshot of the Win98 SE API
#                                   surface for the PE verifier to consume
# ============================================================================
# Reads every PE DLL under repro/data/DLLs/, extracts the exported symbol
# names via `objdump -p`, and writes the result to
# repro/data/win98se-api-allowlist.json.
#
# Re-run this only when refreshing the snapshot (e.g. swapping DLLs from a
# different Win98 install). The JSON is checked in so builds don't need the
# DLLs themselves.
# ============================================================================

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
DLL_DIR = REPO_ROOT / "repro" / "data" / "DLLs"
OUTPUT = REPO_ROOT / "repro" / "data" / "win98se-api-allowlist.json"

NAME_PTR_HEADER = re.compile(r"\[Ordinal/Name Pointer\] Table")
NAME_PTR_ROW = re.compile(
    r"^\s*\[\s*\d+\]\s+\+base\[\s*\d+\]\s+[0-9a-fA-F]+\s+(\S+)\s*$"
)


def find_objdump(explicit: str | None) -> str:
    if explicit:
        return explicit
    env = os.environ.get("OBJDUMP")
    if env:
        return env
    for candidate in ("objdump", "i686-w64-mingw32-objdump"):
        path = shutil.which(candidate)
        if path:
            return path
    sys.exit("error: no objdump found (set OBJDUMP or pass --objdump)")


def extract_exports(objdump: str, dll: Path) -> list[str]:
    try:
        out = subprocess.run(
            [objdump, "-p", str(dll)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    except subprocess.CalledProcessError as e:
        sys.exit(f"error: objdump failed on {dll.name}: {e.stderr.strip()}")

    in_name_table = False
    names: list[str] = []
    for line in out.splitlines():
        if not in_name_table:
            if NAME_PTR_HEADER.search(line):
                in_name_table = True
            continue
        if line.startswith("\t") or line.startswith(" "):
            m = NAME_PTR_ROW.match(line)
            if m:
                names.append(m.group(1))
            elif "Ordinal" in line and "Name" in line:
                continue
            elif line.strip() == "":
                break
        else:
            break
    if not names:
        sys.exit(f"error: no exports parsed from {dll.name} (objdump format change?)")
    return sorted(set(names))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dll-dir", type=Path, default=DLL_DIR)
    ap.add_argument("--output", type=Path, default=OUTPUT)
    ap.add_argument("--objdump", help="path to objdump (else $OBJDUMP, else PATH)")
    ap.add_argument("--label", default="Win98 SE 4.10.2222B (fully patched)",
                    help="human-readable snapshot label embedded in the JSON")
    args = ap.parse_args()

    objdump = find_objdump(args.objdump)
    dll_dir: Path = args.dll_dir
    if not dll_dir.is_dir():
        sys.exit(f"error: DLL directory not found: {dll_dir}")

    dlls = sorted(p for p in dll_dir.iterdir() if p.suffix.lower() == ".dll")
    if not dlls:
        sys.exit(f"error: no *.dll files in {dll_dir}")

    snapshot: dict[str, list[str]] = {}
    for dll in dlls:
        key = dll.name.lower()
        snapshot[key] = extract_exports(objdump, dll)
        print(f"  {key}: {len(snapshot[key])} exports", file=sys.stderr)

    payload = {
        "snapshot": {
            "label": args.label,
            "dll_count": len(snapshot),
            "total_exports": sum(len(v) for v in snapshot.values()),
        },
        "dlls": snapshot,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n",
                            encoding="utf-8")
    print(f"wrote {args.output} "
          f"({payload['snapshot']['dll_count']} DLLs, "
          f"{payload['snapshot']['total_exports']} exports)",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
