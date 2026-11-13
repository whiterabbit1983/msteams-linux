"""Validate binary archive handling with mock ELF headers, never Linux binaries."""

import importlib.util
import io
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("webkit_bundle", ROOT / "scripts/webkit-bundle.py")
bundle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundle)
ELF = b"\x7fELF\x02\x01" + bytes(12) + b"\x3e\x00" + bytes(44)


class WebKitBundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.prefix = self.root / "original"
        self.destination = self.root / "downloaded"
        for name in bundle.REQUIRED:
            path = self.prefix / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(ELF)
            path.chmod(0o755)

    def archive(self):
        return bundle.pack(self.prefix, self.root / "archives")

    def copied_recipe(self):
        root = self.root / "recipe"
        (root / "scripts").mkdir(parents=True)
        for name in ("webkit-profile.json", "webkitgtk-relocatable.patch", "webrtc-packages.sh"):
            shutil.copyfile(ROOT / "scripts" / name, root / "scripts" / name)
        return root

    def test_roundtrip_preserves_elf_files_symlinks_and_permissions(self):
        library = self.prefix / bundle.REQUIRED[0]
        library.rename(library.with_suffix(".so.0"))
        library.symlink_to(library.with_suffix(".so.0").name)
        archive = self.archive()
        bundle.unpack(archive, self.destination)
        bundle.check(self.destination)
        self.assertTrue((self.destination / bundle.REQUIRED[0]).is_symlink())
        self.assertEqual((self.destination / bundle.REQUIRED[-1]).stat().st_mode & 0o777, 0o755)
        metadata = json.loads((self.destination / bundle.MANIFEST).read_text())
        self.assertEqual(metadata["identity"], bundle.identity())

    def test_checksum_mismatch_does_not_create_an_install(self):
        archive = self.archive()
        archive.write_bytes(archive.read_bytes() + b"corruption")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            bundle.unpack(archive, self.destination)
        self.assertFalse(self.destination.exists())

    def test_different_build_profile_cannot_be_installed(self):
        archive = self.archive()
        root = self.copied_recipe()
        path = root / "scripts/webkit-profile.json"
        profile = json.loads(path.read_text())
        profile["build_revision"] += 1
        path.write_text(json.dumps(profile))
        with self.assertRaisesRegex(ValueError, "profile mismatch"):
            bundle.unpack(archive, self.destination, root)
        self.assertFalse(self.destination.exists())

    def test_existing_install_is_not_overwritten(self):
        archive = self.archive()
        with self.assertRaises(FileExistsError):
            bundle.unpack(archive, self.prefix)
        bundle.check(self.prefix)

    def test_missing_library_and_wrong_architecture_fail_validation(self):
        path = self.prefix / bundle.REQUIRED[0]
        path.write_bytes(ELF[:18] + b"\xb7\x00" + ELF[20:])  # AArch64, not x86-64
        with self.assertRaisesRegex(ValueError, "x86-64"):
            self.archive()
        path.unlink()
        with self.assertRaises(FileNotFoundError):
            self.archive()

    def test_required_library_must_not_escape_the_prefix(self):
        path = self.prefix / bundle.REQUIRED[0]
        path.unlink()
        outside = self.root / "outside.so"
        outside.write_bytes(ELF)
        path.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "escapes"):
            self.archive()

    def test_archive_traversal_is_rejected_even_with_a_valid_checksum(self):
        archive = self.root / "malicious.tar.gz"
        with tarfile.open(archive, "w:gz") as source:
            entry = tarfile.TarInfo("../../escaped")
            entry.size = 1
            source.addfile(entry, io.BytesIO(b"x"))
        archive.with_suffix(".gz.sha256").write_text(f"{bundle.sha256(archive)}  {archive.name}\n")
        with self.assertRaises(tarfile.FilterError):
            bundle.unpack(archive, self.destination)
        self.assertFalse((self.root / "escaped").exists())
        self.assertFalse(self.destination.exists())

    def test_identity_tracks_profile_patch_and_dependencies_not_build_driver(self):
        root = self.copied_recipe()
        first = bundle.identity(root)
        (root / "scripts/build-webrtc-webkit.sh").write_text("# driver-only change\n")
        self.assertEqual(first, bundle.identity(root))
        for name in ("webkitgtk-relocatable.patch", "webrtc-packages.sh"):
            path = root / "scripts" / name
            original = path.read_bytes()
            path.write_bytes(original + b"\n")
            self.assertNotEqual(first, bundle.identity(root))
            path.write_bytes(original)
        self.assertEqual(first, bundle.identity(root))

    def test_profile_keeps_the_required_webrtc_options(self):
        options = bundle.profile()["cmake_options"]
        for flag in ("-DENABLE_WEB_RTC=ON", "-DENABLE_MEDIA_STREAM=ON", "-DUSE_GSTREAMER_WEBRTC=ON"):
            self.assertIn(flag, options)

    def test_profile_cannot_silently_disable_webrtc_with_an_override(self):
        root = self.copied_recipe()
        path = root / "scripts/webkit-profile.json"
        profile = json.loads(path.read_text())
        profile["cmake_options"].append("-DENABLE_WEB_RTC=OFF")
        path.write_text(json.dumps(profile))
        with self.assertRaisesRegex(ValueError, "must preserve"):
            bundle.identity(root)

    def test_parallelism_respects_cpu_and_memory_limits(self):
        gib = 1024 ** 3
        self.assertEqual(bundle.parallel_jobs(4, 16 * gib), 4)
        self.assertEqual(bundle.parallel_jobs(2, 7 * gib), 2)
        self.assertEqual(bundle.parallel_jobs(32, 4 * gib), 1)
        self.assertEqual(bundle.parallel_jobs(32, 512 * 1024 ** 2), 1)


if __name__ == "__main__":
    unittest.main()
