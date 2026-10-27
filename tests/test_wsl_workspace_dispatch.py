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

    def test_sshfs_checks_are_bounded_and_optional_workspace_is_skipped(self):
        probes = SOURCE.split("function Test-WslCondition", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("'timeout','-k','2s','5s','test'", probes)
        workspace = SOURCE.split("function Test-WslWorkspaceAccess", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("$ws.Name -eq $Config.DefaultWorkspace", workspace)
        self.assertIn("Skipping unavailable optional workspace", workspace)
        self.assertIn("$script:AvailableWorkspaces", workspace)

    def test_compose_only_mounts_available_workspaces_in_wsl(self):
        compose = SOURCE.split("function Write-Compose", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("$script:AvailableWorkspaces", compose)
        self.assertIn("foreach ($ws in $workspaceMounts)", compose)

    def test_final_compose_uses_validated_workspace_mounts(self):
        normalize = SOURCE.split("function Get-WslEffectiveComposeFile", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("Get-WslComposeConfig $baseArgs", normalize)
        self.assertIn("Get-WslComposeConfig $localArgs", normalize)
        self.assertIn('$root = \'/home/agentdock/AgentDock/workspaces/\'', normalize)
        self.assertIn("$merged.services.agentdock.volumes = @($kept) + @($managed)", normalize)
        self.assertIn("compose.effective.json", normalize)
        dispatch = SOURCE.split("function Invoke-Compose", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("Get-WslEffectiveComposeFile $override", dispatch)
        self.assertIn("$files = @('-f', $resolved)", dispatch)

    def test_custom_mount_hook_has_timeout_and_warns_on_failure(self):
        hook = SOURCE.split("function Invoke-OptionalWslInitialization", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("timeout -k 3s 20s bash $wslHook", hook)
        self.assertIn("Write-Warning", hook)

    def test_ro_and_rw_access_are_checked(self):
        section = SOURCE.split("function Test-WslWorkspaceAccess", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("Test-WslCondition '-r' $source", section)
        self.assertIn("Test-WslCondition '-x' $source", section)
        self.assertIn("Test-WslCondition '-w' $source", section)


if __name__ == "__main__":
    unittest.main()
