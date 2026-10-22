"""Regression guard: Windows WSL preflight must not depend on a text manifest."""
from pathlib import Path
import re
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "scripts" / "windows.ps1").read_text(encoding="utf-8-sig")


class WslWorkspaceDispatchTests(unittest.TestCase):
    def test_docker_preflight_uses_native_wsl_condition_probes(self):
        match = re.search(r"function Assert-DockerConfig\([^\n]*\)\s*\{(?P<body>.*?)\n\}", SOURCE, re.S)
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn("Test-WslWorkspaceAccess $Config $Mode", body)
        self.assertNotIn("Invoke-WslWorkspacePreflight $Config $Mode", body)

    def test_default_workspace_assignment_is_executable_not_comment(self):
        match = re.search(r"function Assert-DockerConfig\([^\n]*\)\s*\{(?P<body>.*?)\n\}", SOURCE, re.S)
        self.assertIsNotNone(match)
        statements = [line.strip() for line in match.group("body").splitlines()
                      if line.strip() and not line.lstrip().startswith("#")]
        self.assertIn("$defaultWs = Get-Workspace $Config $Config.DefaultWorkspace", statements)
        self.assertIn("Test-WslWorkspaceAccess $Config $Mode", statements)
        self.assertNotIn(r"\n", match.group("body"))

    def test_ro_and_rw_access_are_checked(self):
        section = SOURCE.split("function Test-WslWorkspaceAccess", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("Test-WslCondition '-r' $source", section)
        self.assertIn("Test-WslCondition '-x' $source", section)
        self.assertIn("Test-WslCondition '-w' $source", section)


if __name__ == "__main__":
    unittest.main()
