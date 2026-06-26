#!/usr/bin/env python3
"""Emit shell export assignments for selected matrix entry in config.json."""

from __future__ import annotations

import argparse
import shlex
import sys
from pathlib import Path
from typing import Any, Dict, Iterable

from matrix_config import load_config, select_matrix_entry


MAPPING = {
    "gcc": "GCC",
    "binutils": "BINUTILS",
    "mingw-w64": "MINGW_W64",
    "pthread9x": "PTHREAD9X",
    "busybox-w32": "BUSYBOX_W32",
    "make": "MAKE",
    "ctags": "CTAGS",
    "diffutils": "DIFFUTILS",
    "patch": "PATCH",
    "muon": "MUON",
    "jq": "JQ",
    "tinycc": "TINYCC",
}

VERSION_ONLY_MAPPING = {
    "gmp": "GMP_VERSION",
    "mpfr": "MPFR_VERSION",
    "mpc": "MPC_VERSION",
}


def _collect_components(selected: dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    components: Dict[str, Dict[str, Any]] = {}
    for entry in selected.get("components") or []:
        if not isinstance(entry, dict):
            continue
        for key, value in entry.items():
            if isinstance(value, dict):
                components[key] = value
    return components


def build_exports(config: Dict[str, Any], selector: str) -> Dict[str, str]:
    selected = select_matrix_entry(config, selector)

    exports: Dict[str, str] = {}
    selected_label = str(selected.get("version", ""))
    if selected_label:
        exports["MATRIX_SELECTED_LABEL"] = selected_label

    components = _collect_components(selected)
    for key, prefix in MAPPING.items():
        comp = components.get(key)
        if not comp:
            continue
        source = comp.get("source")
        commit = comp.get("commit")
        version = comp.get("version")
        if source:
            exports[f"{prefix}_FETCH_SOURCE"] = str(source)
        if commit:
            exports[f"{prefix}_FETCH_REF"] = str(commit)
        if version:
            exports[f"{prefix}_COMPONENT_VERSION"] = str(version)

        # Optional tarball metadata. When tarball_url is present,
        # fetch-sources.sh will prefer the tarball over a git clone for
        # this component. tarball_sha512 (or _sha256) is optional; if set,
        # the download is verified. tarball_strip defaults to 1 (the
        # standard "drop the top-level versioned dir" behavior).
        tarball = comp.get("tarball")
        if isinstance(tarball, dict):
            t_url = tarball.get("url")
            t_sha512 = tarball.get("sha512")
            t_sha256 = tarball.get("sha256")
            t_strip = tarball.get("strip")
            if t_url:
                exports[f"{prefix}_TARBALL_URL"] = str(t_url)
            if t_sha512:
                exports[f"{prefix}_TARBALL_SHA512"] = str(t_sha512)
            if t_sha256:
                exports[f"{prefix}_TARBALL_SHA256"] = str(t_sha256)
            if t_strip is not None:
                exports[f"{prefix}_TARBALL_STRIP"] = str(t_strip)

    for key, export_name in VERSION_ONLY_MAPPING.items():
        comp = components.get(key)
        if not comp:
            continue
        version = comp.get("version")
        if version:
            exports[export_name] = str(version)

    return exports


def format_exports_lines(exports: Dict[str, str]) -> Iterable[str]:
    for key in sorted(exports.keys()):
        yield f"{key}={shlex.quote(exports[key])}"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path, help="Path to config.json")
    parser.add_argument("selector", nargs="?", default="0", help="Matrix index or version label")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        config = load_config(args.config)
        exports = build_exports(config, args.selector)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    for line in format_exports_lines(exports):
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
