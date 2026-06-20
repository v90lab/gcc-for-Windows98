#!/usr/bin/env python3
"""Build and write a GCC-for-Windows98 toolchain manifest."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Dict


def load_compiler_features(compiler_features_path: Path) -> Dict[str, str]:
    features = {
        "threading_model": "unverified",
        "pthread": "unverified",
        "std_thread": "unverified",
        "file_io": "unverified",
    }
    if compiler_features_path.exists():
        with compiler_features_path.open("r", encoding="utf-8") as f:
            loaded = json.load(f)
        if isinstance(loaded, dict):
            features.update({k: str(v).strip() for k, v in loaded.items()})
    return features


def build_manifest(
    *,
    artifact_filename: str,
    artifact_sha256: str,
    artifact_size: int,
    gcc_version: str,
    target: str,
    package_kind: str,
    compiler_features: Dict[str, str],
) -> Dict[str, Any]:
    detected_threading = str(compiler_features.get("threading_model", "unverified"))
    return {
        "artifact": {
            "filename": artifact_filename,
            "sha256": artifact_sha256,
            "size": artifact_size,
        },
        "toolchain": {
            "gcc_version": gcc_version,
            "target": target,
            "package_kind": package_kind,
            "crt": "msvcrt",
            "threading": detected_threading,
        },
        "compiler_features": compiler_features,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-path", required=True, type=Path)
    parser.add_argument("--artifact-filename", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--gcc-version", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--package-kind", required=True)
    parser.add_argument("--compiler-features-path", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    compiler_features = load_compiler_features(args.compiler_features_path)
    artifact_size = args.artifact_path.stat().st_size

    manifest = build_manifest(
        artifact_filename=args.artifact_filename,
        artifact_sha256=args.sha256,
        artifact_size=artifact_size,
        gcc_version=args.gcc_version,
        target=args.target,
        package_kind=args.package_kind,
        compiler_features=compiler_features,
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)

    print(f"Manifest written to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(__import__("sys").argv[1:]))
