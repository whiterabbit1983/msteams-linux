"""Exercise the launcher with shell stubs, without running the Linux app."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "scripts/appimage-apprun.sh"


class AppImageLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.appdir = root / "AppDir with spaces"
        self.cwd = root / "unrelated empty directory"
        self.cwd.mkdir()
        self.executable("AppRun", SOURCE.read_text())
        self.executable("usr/AppRun", '#!/bin/sh\necho "Error: No .desktop files found" >&2\nexit 97\n')
        self.executable("usr/bin/msteams-tauri", '#!/bin/sh\nprintf "%s\\n" "native-app" "$APPDIR" "$WEBKIT_EXEC_PATH" "$WEBKIT_INJECTED_BUNDLE_PATH" "$LD_LIBRARY_PATH" "${HOOK_LOADED:-}" "$@"\n')
        self.executable("usr/libexec/msteams-webrtc-smoke", '#!/bin/sh\nprintf "synthetic=%s\\n" "$MSTEAMS_WEBRTC_SYNTHETIC"\n')

    def executable(self, name, text):
        path = self.appdir / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)
        return path

    def launch(self, *args):
        return subprocess.run(
            [str(self.appdir / "AppRun"), *args], cwd=self.cwd,
            env={**os.environ, "LD_LIBRARY_PATH": "upstream", "APPDIR": "/wrong/inherited/value"},
            capture_output=True, text=True, check=False,
        )

    def test_launches_native_app_without_searching_for_desktop_files(self):
        # The relocated generic AppRun deliberately fails. It must never run.
        result = self.launch("--argument", "two words")
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], "native-app")
        self.assertEqual(lines[1], str(self.appdir))
        self.assertEqual(lines[2], str(self.appdir / "usr/libexec/webkit2gtk-4.1"))
        self.assertEqual(lines[3], str(self.appdir / "usr/lib/webkit2gtk-4.1/injected-bundle"))
        self.assertEqual(lines[4], f"{self.appdir}/usr/lib:upstream")
        self.assertEqual(lines[-2:], ["--argument", "two words"])
        self.assertFalse(list(self.cwd.glob("*.desktop")))

    def test_apprun_wrapped_layout_still_uses_the_appdir_root(self):
        wrapped = self.appdir / "AppRun.wrapped"
        shutil.copyfile(SOURCE, wrapped)
        wrapped.chmod(0o755)
        result = subprocess.run([str(wrapped)], cwd=self.cwd, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[1], str(self.appdir))

    def test_linuxdeploy_hooks_are_loaded(self):
        hook = self.appdir / "apprun-hooks/gtk.sh"
        hook.parent.mkdir()
        hook.write_text('export HOOK_LOADED="gtk hook loaded"\n')
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("gtk hook loaded", result.stdout)

    def test_optional_webrtc_mode_keeps_the_synthetic_source_flag(self):
        result = self.launch("--webrtc-smoke")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "synthetic=1")


if __name__ == "__main__":
    unittest.main()
