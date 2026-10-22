"""Ensure Windows localhost health checks bypass the system proxy."""
from pathlib import Path
import re
import unittest

SRC = (Path(__file__).resolve().parents[1] / "scripts" / "windows.ps1").read_text(encoding="utf-8-sig")


class WindowsHealthTests(unittest.TestCase):
    def test_direct_health_probe_disables_proxy(self):
        fn = SRC.split("function Test-LocalAgentDockHealth", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("http://127.0.0.1:$Port/healthz", fn)
        self.assertRegex(fn, r"\$request\.Proxy\s*=\s*\$null")
        self.assertIn("$request.GetResponse()", fn)

    def test_status_uses_direct_probe(self):
        fn = SRC.split("function Status-Command", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("Test-LocalAgentDockHealth $cfg.Port", fn)
        self.assertNotIn("Invoke-WebRequest", fn)

    def test_start_uses_same_direct_probe(self):
        fn = SRC.split("function Wait-AgentDock", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("Test-LocalAgentDockHealth $Port", fn)
        self.assertNotIn("Invoke-WebRequest", fn)


if __name__ == "__main__":
    unittest.main()
