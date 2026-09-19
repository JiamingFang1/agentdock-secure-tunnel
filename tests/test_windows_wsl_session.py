"""Windows entry integration with a simulated WSL backend; no downloads or keys."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == 'nt', 'Requires Windows PowerShell')
class WindowsWslDispatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='wsl-entry-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'space (QA) & bang!'
        self.scripts = self.root / 'scripts'
        self.scripts.mkdir(parents=True)
        self.runtime = self.root / '.runtime'
        self.runtime.mkdir()
        (self.runtime / 'deployment.txt').write_text('docker-wsl')
        self.env = os.environ.copy()
        self.env.update(TRACE=str(self.root / 'trace.txt'), MAIN_CODE='0', POLL_STATE='yes', HOLDER_FAIL='no')
        self.ps = str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe')
        shutil.copyfile(ROOT / 'scripts/windows-entry.ps1', self.scripts / 'windows-entry.ps1')
        self.write('windows-runtime-checks.ps1', '''
function Configure-TunnelProxy { Add-Content $env:TRACE 'proxy' }
function Wait-ControlPlaneConnected { param($RuntimeDir); return ($env:POLL_STATE -eq 'yes') }
function Test-ControlPlaneConnected { param($RuntimeDir); return ($env:POLL_STATE -eq 'yes') }
''')
        self.write('bootstrap-tunnel.ps1', "Add-Content $env:TRACE 'bootstrap'; exit 0\n")
        self.write('windows.ps1', '''
Add-Content $env:TRACE ('main:' + $args[0])
exit ([int]$env:MAIN_CODE)
''')
        self.write('windows-wsl-session.ps1', '''
function Start-AgentDockWslSession {
    param($RuntimeDir,$HelperScript)
    Add-Content $env:TRACE 'holder:start'
    if ($env:HOLDER_FAIL -eq 'yes') { throw 'simulated holder failure' }
}
function Stop-AgentDockWslSession { param($RuntimeDir); Add-Content $env:TRACE 'holder:stop' }
function Show-AgentDockWslSession { param($RuntimeDir); Add-Content $env:TRACE 'holder:status' }
function Assert-WslSessionDefault { param($RuntimeDir); return 'Ubuntu-22.04' }
''')

    def write(self, name, content):
        (self.scripts / name).write_text(content, encoding='utf-8-sig')

    def run_entry(self, command):
        result = subprocess.run([self.ps, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(self.scripts / 'windows-entry.ps1'), command], env=self.env, cwd=self.tmp.name, capture_output=True, timeout=20)
        trace = Path(self.env['TRACE'])
        lines = trace.read_text(encoding='utf-8-sig').strip().splitlines() if trace.exists() else []
        return result, lines

    def test_holder_precedes_start_restart_and_apply(self):
        for command in ('start', 'restart', 'apply'):
            with self.subTest(command=command):
                Path(self.env['TRACE']).unlink(missing_ok=True)
                result, lines = self.run_entry(command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(lines, ['proxy', 'bootstrap', 'holder:start', 'main:' + command])

    def test_stop_releases_holder_after_services_stop(self):
        result, lines = self.run_entry('stop')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(lines, ['main:stop', 'holder:stop'])

    def test_failed_stop_keeps_holder(self):
        self.env['MAIN_CODE'] = '17'
        result, lines = self.run_entry('stop')
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(lines, ['main:stop'])

    def test_status_does_not_start_holder_or_bootstrap(self):
        result, lines = self.run_entry('status')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(lines, ['main:status', 'holder:status'])

    def test_failed_holder_prevents_docker_and_tunnel_start(self):
        self.env['HOLDER_FAIL'] = 'yes'
        result, lines = self.run_entry('start')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('main:start', lines)
        self.assertNotIn('holder:stop', lines)

    def test_unverified_tunnel_keeps_holder(self):
        self.env['POLL_STATE'] = 'no'
        result, lines = self.run_entry('start')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertNotIn('holder:stop', lines)

    def test_docker_desktop_and_native_do_not_start_wsl(self):
        for mode in ('docker-windows', 'native'):
            with self.subTest(mode=mode):
                (self.runtime / 'deployment.txt').write_text(mode)
                Path(self.env['TRACE']).unlink(missing_ok=True)
                result, lines = self.run_entry('start')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(lines, ['proxy', 'bootstrap', 'main:start'])


if __name__ == '__main__':
    unittest.main()
