"""PowerShell native workspace evidence and cross-platform wiring checks."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PS = shutil.which("powershell.exe") or shutil.which("pwsh")


class WindowsStateWiringTests(unittest.TestCase):
    def test_native_status_uses_process_bound_evidence(self):
        source = (ROOT / "scripts/windows.ps1").read_text(encoding="utf-8-sig")
        native = source.split("function Start-Native", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("Save-NativeWorkspace", native)
        running = source.split("function Get-RunningDefaultWorkspace", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("Get-NativeWorkspace", running)
        self.assertIn(".State.Running", running)


@unittest.skipUnless(PS, "Requires PowerShell")
class WindowsNativeStateTests(unittest.TestCase):
    def test_snapshot_matches_live_process_and_detects_edits_and_pid_reuse(self):
        with tempfile.TemporaryDirectory() as td:
            helper = ROOT / "scripts/windows-native-state.ps1"
            harness = Path(td) / "test.ps1"
            harness.write_text(r'''
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $args[0]
$NativeState = Join-Path $args[1] 'state.json'
$NativePid = Join-Path $args[1] 'native.pid'
$AgentDockExe = 'C:\runtime\agentdock.exe'
$script:FakeProcess = [pscustomobject]@{ Id=123; Path=$AgentDockExe; StartTime=[datetime]'2026-10-27T10:00:00' }
function Get-Process { param($Id, $ErrorAction); return $script:FakeProcess }
Set-Content $NativePid 123
$config = [pscustomobject]@{ DefaultWorkspace='alpha'; Workspaces=@([pscustomobject]@{ Name='alpha'; Path='C:\workspace 中文'; Mode='rw' }) }
Save-NativeWorkspace $script:FakeProcess $config.Workspaces[0]
if ((Get-NativeWorkspace $config) -ne 'alpha') { throw 'matching workspace failed' }
$config.Workspaces[0].Path = 'C:\changed'
if ((Get-NativeWorkspace $config) -ne 'CUSTOM') { throw 'edited path accepted' }
$config.Workspaces[0].Path = 'C:\workspace 中文'
$script:FakeProcess.StartTime = $script:FakeProcess.StartTime.AddSeconds(1)
if ((Get-NativeWorkspace $config) -ne 'UNKNOWN') { throw 'reused PID accepted' }
$script:FakeProcess.StartTime = $script:FakeProcess.StartTime.AddSeconds(-1)
$script:FakeProcess.Path = 'C:\other.exe'
if ((Get-NativeWorkspace $config) -ne 'UNKNOWN') { throw 'foreign executable accepted' }
Remove-Item $NativeState
if ((Get-NativeWorkspace $config) -ne 'UNKNOWN') { throw 'missing evidence accepted' }
Write-Output 'PASSED'
''', encoding="utf-8-sig")
            result = subprocess.run([PS, "-NoProfile", "-File", str(harness), str(helper), td], capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(b"PASSED", result.stdout)
