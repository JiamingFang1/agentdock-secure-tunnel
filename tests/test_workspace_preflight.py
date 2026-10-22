"""Offline workspace preflight integration tests; only temporary directories."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-workspaces.sh"


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "bash required")
class WorkspacePreflightTests(unittest.TestCase):
    def invoke(self, lines):
        return subprocess.run(
            ["bash", str(SCRIPT)], input=lines, text=True,
            capture_output=True, timeout=15, check=False,
        )

    def test_existing_workspace_can_be_checked(self):
        with tempfile.TemporaryDirectory() as td:
            result = self.invoke("ro\t" + td + "\n")
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_utf8_manifest_path_preserves_unicode(self):
        with tempfile.TemporaryDirectory(prefix="workspace-检查-") as td:
            manifest = Path(td) / "manifest.txt"
            manifest.write_text("ro\t" + td + "\n", encoding="utf-8")
            result = subprocess.run(
                ["bash", str(SCRIPT), str(manifest)], text=True,
                capture_output=True, timeout=15, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_workspace_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            result = self.invoke("rw\t" + str(Path(td) / "absent") + "\n")
            self.assertEqual(result.returncode, 1)

    def test_invalid_mode_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            self.assertEqual(self.invoke("root\t" + td + "\n").returncode, 2)

    def test_relative_path_is_rejected(self):
        self.assertEqual(self.invoke("rw\trelative/path\n").returncode, 2)

    def test_two_workspaces_are_validated(self):
        with tempfile.TemporaryDirectory() as td:
            missing = Path(td) / "absent"
            result = self.invoke("ro\t" + td + "\nrw\t" + str(missing) + "\n")
            self.assertEqual(result.returncode, 1)
            self.assertIn("1 workspace(s)", result.stderr)


if __name__ == "__main__":
    unittest.main()
