import json
import tempfile
import unittest
from pathlib import Path

import sys

THIS_DIR = Path(__file__).resolve().parent
LIB_DIR = THIS_DIR.parent
sys.path.insert(0, str(LIB_DIR))

from toolchain_manifest import build_manifest, load_compiler_features, main


class ToolchainManifestTests(unittest.TestCase):
    def test_load_compiler_features_defaults(self):
        with tempfile.TemporaryDirectory() as td:
            missing = Path(td) / "missing.json"
            features = load_compiler_features(missing)
            self.assertEqual(features["threading_model"], "unverified")
            self.assertEqual(features["pthread"], "unverified")
            self.assertEqual(features["std_thread"], "unverified")
            self.assertEqual(features["file_io"], "unverified")

    def test_load_compiler_features_override(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "status.json"
            path.write_text(json.dumps({"threading_model": "posix", "pthread": "pass"}), encoding="utf-8")
            features = load_compiler_features(path)
            self.assertEqual(features["threading_model"], "posix")
            self.assertEqual(features["pthread"], "pass")
            self.assertEqual(features["std_thread"], "unverified")

    def test_build_manifest_structure(self):
        manifest = build_manifest(
            artifact_filename="toolchain.tar.xz",
            artifact_sha256="deadbeef",
            artifact_size=123,
            gcc_version="11.1.0",
            target="i686-w64-mingw32",
            package_kind="cross-toolchain",
            compiler_features={"threading_model": "posix", "pthread": "pass", "std_thread": "pass", "file_io": "pass"},
        )
        self.assertEqual(manifest["artifact"]["filename"], "toolchain.tar.xz")
        self.assertEqual(manifest["toolchain"]["gcc_version"], "11.1.0")
        self.assertEqual(manifest["toolchain"]["package_kind"], "cross-toolchain")
        self.assertEqual(manifest["toolchain"]["threading"], "posix")
        self.assertEqual(manifest["compiler_features"]["pthread"], "pass")

    def test_build_manifest_native_structure(self):
        manifest = build_manifest(
            artifact_filename="gcc-win98-native-toolset.zip",
            artifact_sha256="beadfeed",
            artifact_size=456,
            gcc_version="11.1.0",
            target="i686-w64-mingw32",
            package_kind="native-toolset",
            compiler_features={"threading_model": "posix", "pthread": "unverified", "std_thread": "unverified", "file_io": "unverified"},
        )
        self.assertEqual(manifest["artifact"]["filename"], "gcc-win98-native-toolset.zip")
        self.assertEqual(manifest["toolchain"]["package_kind"], "native-toolset")

    def test_main_writes_output(self):
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            artifact = td_path / "gcc-win98-toolchain.tar.xz"
            artifact.write_bytes(b"abc")
            features = td_path / "features.json"
            features.write_text(json.dumps({"threading_model": "posix", "pthread": "ok", "file_io": "ok"}), encoding="utf-8")
            out = td_path / "manifest.json"

            rc = main(
                [
                    "--artifact-path",
                    str(artifact),
                    "--artifact-filename",
                    artifact.name,
                    "--sha256",
                    "hash",
                    "--gcc-version",
                    "11.1.0",
                    "--target",
                    "i686-w64-mingw32",
                    "--package-kind",
                    "cross-toolchain",
                    "--compiler-features-path",
                    str(features),
                    "--output",
                    str(out),
                ]
            )

            self.assertEqual(rc, 0)
            data = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(data["artifact"]["size"], 3)
            self.assertEqual(data["toolchain"]["package_kind"], "cross-toolchain")
            self.assertEqual(data["toolchain"]["threading"], "posix")
            self.assertEqual(data["compiler_features"]["pthread"], "ok")


if __name__ == "__main__":
    unittest.main()
