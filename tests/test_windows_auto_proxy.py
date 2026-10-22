"""Regression checks for independently implemented Windows automatic-proxy discovery."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts" / "windows-runtime-checks.ps1"


class ProxySourceTests(unittest.TestCase):
    def test_automatic_proxy_discovery_is_present(self):
        source = SOURCE.read_text(encoding="utf-8-sig")
        self.assertIn("GetSystemWebProxy()", source)
        self.assertIn("GetSystemWebProxy()", source)
        self.assertIn("GetProxy($target)", source)
        self.assertIn("resolved.Scheme -notin", source)


@unittest.skipUnless(os.name == "nt", "Windows PowerShell 5.1 required")
class ProxyWindowsTests(unittest.TestCase):
    def test_manual_proxy_and_environment_take_precedence(self):
        ps = Path(os.environ["SystemRoot"]) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
        script = r"""
$ErrorActionPreference = 'Stop'
. '__SOURCE__'
$env:HTTPS_PROXY = 'http://127.0.0.1:8899'
$env:HTTP_PROXY = ''
$env:NO_PROXY = ''
Configure-TunnelProxy
if ($env:HTTPS_PROXY -ne $env:HTTP_PROXY) { throw 'environment precedence failed' }
foreach ($name in @('127.0.0.1','localhost','::1')) {
    if ($name -notin ($env:NO_PROXY -split ',')) { throw 'loopback bypass failed' }
}
"""
        with tempfile.TemporaryDirectory() as td:
            harness = Path(td) / "proxy-check.ps1"
            harness.write_text(script.replace("__SOURCE__", str(SOURCE).replace("'", "''")), encoding="utf-8-sig")
            env = dict(os.environ)
            env["HTTPS_PROXY"] = "http://127.0.0.1:8899"
            env["HTTP_PROXY"] = ""
            result = subprocess.run(
                [str(ps), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(harness)],
                capture_output=True, timeout=20, env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))


if __name__ == "__main__":
    unittest.main()
