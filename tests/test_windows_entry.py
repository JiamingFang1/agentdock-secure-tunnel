"""Offline Windows CMD/PowerShell 5.1 regression tests; no Docker or real keys."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WINDOWS = os.name == "nt"


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8-sig" if path.suffix == ".ps1" else "utf-8")


class StaticEntryTests(unittest.TestCase):
    def test_cmd_encoding_and_single_dispatch(self):
        raw = (ROOT / "agentdock.cmd").read_bytes()
        text = raw.decode("ascii").replace("\r\n", "\n")
        self.assertNotIn("\x00", text)
        self.assertEqual(text.count("-File"), 1)
        self.assertIn("DisableDelayedExpansion", text)
        self.assertIn('"%~dp0scripts\\windows-entry.ps1" %*', text)
        self.assertRegex(text, r"(?s)\(\s+.*-File.*\n\s+call exit /b %%errorlevel%%\s+\)")
        self.assertIn("*.cmd text eol=crlf", (ROOT / ".gitattributes").read_text())
    def test_windows_entry_does_not_manage_wsl_lifetime(self):
        text = (ROOT / "scripts/windows-entry.ps1").read_text(encoding="utf-8-sig")
        self.assertNotIn("Start-AgentDockWslSession", text)
        self.assertNotIn("Stop-AgentDockWslSession", text)
        self.assertNotIn("windows-wsl-session.ps1", text)



@unittest.skipUnless(WINDOWS, "Requires real Windows CMD and Windows PowerShell 5.1")
class WindowsEntryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="agentdock-entry-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "space 中文 (QA) & bang!"
        self.scripts = self.root / "scripts"
        self.scripts.mkdir(parents=True)
        # Match the CRLF checkout produced by .gitattributes.
        cmd = (ROOT / "agentdock.cmd").read_text().replace("\r\n", "\n")
        (self.root / "agentdock.cmd").write_bytes(cmd.replace("\n", "\r\n").encode("ascii"))
        self.env = os.environ.copy()
        self.env.update({"ENTRY_TRACE": str(self.root / "trace.txt"), "ENTRY_CODE": "0", "BOOT_CODE": "0", "MAIN_CODE": "0", "POLL_STATE": "connected"})
        self.ps = str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
        write(self.scripts / "bootstrap-tunnel.ps1", "exit 0\n")

    def run_cmd(self, arguments="restart"):
        cmd = str(Path(os.environ["SystemRoot"]) / "System32/cmd.exe")
        command = f'"{cmd}" /d /s /v:off /c ""{self.root / "agentdock.cmd"}" {arguments}"'
        return subprocess.run(command, cwd=self.tmp.name, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)

    def run_ps(self, path):
        return subprocess.run([self.ps, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(path)], cwd=self.tmp.name, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)

    def fake_entry(self):
        write(self.scripts / "windows-entry.ps1", r'''
[IO.File]::WriteAllText($env:ENTRY_TRACE, (ConvertTo-Json -InputObject @($args) -Compress))
Write-Output 'ENTRY_REACHED'
exit ([int]$env:ENTRY_CODE)
''')

    def real_entry(self):
        shutil.copyfile(ROOT / "scripts/windows-entry.ps1", self.scripts / "windows-entry.ps1")
        write(self.scripts / "windows-runtime-checks.ps1", r'''
function Configure-TunnelProxy {
    Add-Content $env:ENTRY_TRACE 'proxy'
    $env:ENTRY_PROXY_READY = 'yes'
}
function Test-ControlPlaneConnected([string]$RuntimeDir) { return ($env:POLL_STATE -eq 'connected') }
function Wait-ControlPlaneConnected([string]$RuntimeDir) { return (Test-ControlPlaneConnected $RuntimeDir) }
''')
        write(self.scripts / "bootstrap-tunnel.ps1", r'''
Add-Content $env:ENTRY_TRACE "bootstrap:$env:ENTRY_PROXY_READY"
exit ([int]$env:BOOT_CODE)
''')
        write(self.scripts / "windows.ps1", r'''
Add-Content $env:ENTRY_TRACE "main:$($args[0])"
if ($env:MAIN_THROW -eq 'yes') { throw 'SIMULATED_MAIN_FAILURE' }
if ([int]$env:MAIN_CODE -ne 0) { exit ([int]$env:MAIN_CODE) }
Write-Output 'LOCAL_COMMAND_DONE'
exit 0
''')

    def trace(self):
        p = self.root / "trace.txt"
        return p.read_text(encoding="utf-8-sig").strip().splitlines() if p.exists() else []

    def test_cmd_forwards_arguments_once_from_special_path(self):
        self.fake_entry()
        result = self.run_cmd('restart "two words"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.root / "trace.txt").read_text()), ["restart", "two words"])
        self.assertEqual(result.stdout.count(b"ENTRY_REACHED"), 1)
        self.assertEqual(result.stderr, b"")

    def test_cmd_preserves_nonzero_exit(self):
        self.fake_entry()
        self.env["ENTRY_CODE"] = "37"
        self.assertEqual(self.run_cmd().returncode, 37)

    def test_cmd_does_not_parse_tail_after_child_rewrites_launcher(self):
        write(self.scripts / "windows-entry.ps1", r'''
$batch = Join-Path (Split-Path -Parent $PSScriptRoot) 'agentdock.cmd'
[IO.File]::WriteAllText($batch, (("BAD_TAIL_SENTINEL`r`n" * 300) + '.ps1" restart'), [Text.Encoding]::ASCII)
Write-Output 'ENTRY_REACHED'
exit 0
''')
        result = self.run_cmd()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        self.assertNotIn(b"BAD_TAIL_SENTINEL", result.stdout)
        self.assertEqual(result.stdout.count(b"ENTRY_REACHED"), 1)

    def test_restart_runs_each_stage_once(self):
        self.real_entry()
        result = self.run_cmd()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.trace(), ["proxy", "bootstrap:yes", "main:restart"])
        self.assertIn(b"Control Plane : CONNECTED", result.stdout)

    def test_local_commands_do_not_bootstrap(self):
        for command in ("help", "status", "stop", "logs"):
            with self.subTest(command=command):
                self.real_entry()
                (self.root / "trace.txt").unlink(missing_ok=True)
                (self.scripts / "bootstrap-tunnel.ps1").unlink()
                result = self.run_cmd(command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.trace(), ["main:" + command])

    def test_direct_ps_entry_also_prepares_runtime(self):
        self.real_entry()
        result = subprocess.run([self.ps, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(self.scripts / "windows-entry.ps1"), "start"], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.trace(), ["proxy", "bootstrap:yes", "main:start"])

    def test_bootstrap_failure_does_not_run_main(self):
        self.real_entry()
        self.env["BOOT_CODE"] = "23"
        result = self.run_cmd()
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(self.trace(), ["proxy", "bootstrap:yes"])
        self.assertNotIn(b"CONNECTED", result.stdout)

    def test_main_failure_is_propagated(self):
        self.real_entry()
        self.env["MAIN_CODE"] = "17"
        result = self.run_cmd()
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertNotIn(b"CONNECTED", result.stdout)

    def test_throw_is_reported_without_automatic_log_dump(self):
        self.real_entry()
        self.env["MAIN_THROW"] = "yes"
        result = self.run_cmd()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"SIMULATED_MAIN_FAILURE", result.stderr)
        self.assertNotIn("main:logs", self.trace())
        self.assertNotIn(b"CONNECTED", result.stdout)

    def test_unverified_control_plane_does_not_stop_services(self):
        self.real_entry()
        self.env["POLL_STATE"] = "unverified"
        result = self.run_cmd()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(b"Control Plane : UNVERIFIED", result.stdout)
        self.assertIn(b"NOT been stopped", result.stderr)
        self.assertEqual(self.trace(), ["proxy", "bootstrap:yes", "main:restart"])

    def test_invalid_command_does_not_install(self):
        self.real_entry()
        result = self.run_cmd("typo")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.trace(), [])

    def test_missing_main_reports_failure(self):
        self.real_entry()
        (self.scripts / "windows.ps1").unlink()
        result = self.run_cmd("status")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"Missing script", result.stderr)

    def test_config_and_runtime_are_not_deleted_by_entry(self):
        self.real_entry()
        write(self.root / "config.yaml", "do-not-replace")
        write(self.root / ".runtime/agentdock.token", "test-token-only")
        self.env["MAIN_CODE"] = "1"
        self.run_cmd()
        self.assertEqual((self.root / "config.yaml").read_text(), "do-not-replace")
        self.assertEqual((self.root / ".runtime/agentdock.token").read_text(), "test-token-only")

    def test_metrics_require_current_process_owner_and_fresh_timestamp(self):
        shutil.copyfile(ROOT / "scripts/windows-runtime-checks.ps1", self.scripts / "checks.ps1")
        harness = self.scripts / "checks-test.ps1"
        write(harness, r'''
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'checks.ps1')
$runtime = Join-Path $PSScriptRoot 'runtime'
New-Item -ItemType Directory -Force $runtime | Out-Null
Set-Content (Join-Path $runtime 'tunnel-client.pid') '4242'
$script:FakePath = Join-Path $runtime 'bin\tunnel-client.exe'
$script:FakeStart = [DateTime]::Now.AddMinutes(-1)
$script:Owner = 4242
$epoch = [DateTime]::SpecifyKind([DateTime]'1970-01-01', [DateTimeKind]::Utc)
$script:Stamp = ([DateTime]::UtcNow - $epoch).TotalSeconds
function Get-Process { param($Id, $ErrorAction); return [pscustomobject]@{ Path=$script:FakePath; StartTime=$script:FakeStart } }
function Get-NetTCPConnection { param($LocalPort, $State, $ErrorAction); return [pscustomobject]@{ OwningProcess=$script:Owner } }
function Read-LocalTunnelMetrics { return 'commands_poll_last_successful_timestamp_seconds ' + $script:Stamp.ToString([Globalization.CultureInfo]::InvariantCulture) }
if (-not (Test-ControlPlaneConnected $runtime)) { throw 'fresh poll should pass' }
$script:Owner = 9999
if (Test-ControlPlaneConnected $runtime) { throw 'foreign metrics owner accepted' }
$script:Owner = 4242
$script:FakePath = 'C:\other\tunnel-client.exe'
if (Test-ControlPlaneConnected $runtime) { throw 'reused PID accepted' }
$script:FakePath = Join-Path $runtime 'bin\tunnel-client.exe'
$script:Stamp -= 600
if (Test-ControlPlaneConnected $runtime) { throw 'stale poll accepted' }
$script:Stamp += 960
if (Test-ControlPlaneConnected $runtime) { throw 'future poll accepted' }
Set-Content (Join-Path $runtime 'tunnel-client.pid') 'not-a-pid'
if (Test-ControlPlaneConnected $runtime) { throw 'malformed PID accepted' }
Remove-Item (Join-Path $runtime 'tunnel-client.pid')
if (Test-ControlPlaneConnected $runtime) { throw 'missing PID accepted' }
if ((Get-PollTimestamp 'garbage') -ne 0) { throw 'bad metrics parsed' }
if ((Get-PollTimestamp 'commands_poll_last_successful_timestamp_seconds{channel="main"} 1.23e3') -ne 1230) { throw 'labelled metrics failed' }
Write-Output 'CHECKS_PASSED'
''')
        result = self.run_ps(harness)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"CHECKS_PASSED", result.stdout)

    def test_proxy_credentials_are_not_printed(self):
        shutil.copyfile(ROOT / "scripts/windows-runtime-checks.ps1", self.scripts / "checks.ps1")
        harness = self.scripts / "proxy-test.ps1"
        write(harness, r'''
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'checks.ps1')
$env:HTTPS_PROXY = 'http://alice:secret-password@127.0.0.1:7890'
$env:HTTP_PROXY = ''
$env:NO_PROXY = 'example.test'
Configure-TunnelProxy
if ($env:HTTP_PROXY -ne $env:HTTPS_PROXY) { throw 'proxy not propagated' }
foreach ($hostName in @('example.test','127.0.0.1','localhost','::1')) {
    if ($hostName -notin ($env:NO_PROXY -split ',')) { throw 'missing bypass' }
}
Write-Output 'PROXY_PASSED'
''')
        result = self.run_ps(harness)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"PROXY_PASSED", result.stdout)
        self.assertNotIn(b"secret-password", result.stdout + result.stderr)
        self.assertNotIn(b"alice", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
