"""Test the early dependency gate without running or building the Linux app."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-webrtc-deps.sh"


class WebRTCDependencyTests(unittest.TestCase):
    def run_gate(self, *, cflags_status=0, libs_status=0, compiler_status=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pkg_config = root / "pkg-config"
            pkg_config.write_text(
                '#!/bin/sh\n'
                'case "$*" in\n'
                f'  *--cflags*) echo "-I/test/include"; exit {cflags_status} ;;\n'
                f'  *--libs*) exit {libs_status} ;;\n'
                '  *) exit 99 ;;\n'
                'esac\n'
            )
            compiler = root / "test-cc"
            compiler.write_text(
                '#!/bin/sh\n'
                f'printf "%s\\n" "$@" > "{root / "compiler-args"}"\n'
                f'cat > "{root / "compiler-input"}"\n'
                f'exit {compiler_status}\n'
            )
            pkg_config.chmod(0o755)
            compiler.chmod(0o755)
            result = subprocess.run(
                ["bash", str(SCRIPT)],
                env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}", "CC": str(compiler)},
                capture_output=True,
                text=True,
                check=False,
            )
            called = (root / "compiler-args").exists()
            args = (root / "compiler-args").read_text() if called else ""
            source = (root / "compiler-input").read_text() if called else ""
            return result, called, args, source

    def test_missing_transitive_metadata_stops_before_compiler(self):
        result, called, _, _ = self.run_gate(cflags_status=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(called)
        self.assertIn("incomplete WebRTC development dependencies", result.stderr)

    def test_broken_library_metadata_stops_before_compiler(self):
        result, called, _, _ = self.run_gate(libs_status=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(called)

    def test_missing_headers_fail_the_gate(self):
        result, called, _, _ = self.run_gate(compiler_status=1)
        self.assertTrue(called)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("dependencies: OK", result.stdout)

    def test_success_checks_gstreamer_and_webrtc_headers(self):
        result, called, args, source = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(called)
        self.assertIn("-I/test/include", args)
        self.assertIn("-fsyntax-only", args)
        self.assertIn("<gst/gst.h>", source)
        self.assertIn("<gst/webrtc/webrtc.h>", source)
        self.assertIn("<openssl/ssl.h>", source)
        self.assertIn("dependencies: OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
