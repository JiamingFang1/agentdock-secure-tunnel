"""Workspace evidence must describe the live process, not edited config."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class NativeStateTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("native_state", ROOT / "scripts/native-state.py")
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name) / "state.json"

    def test_snapshot_tracks_original_workspace_and_path(self):
        with patch.object(self.module, "process_identity", return_value="process-one"):
            self.module.record(self.state, 123, "alpha", "/tmp/space 中文")
            self.assertEqual(self.module.running(self.state, 123, {"alpha": "/tmp/space 中文"}), "alpha")
            self.assertEqual(self.module.running(self.state, 123, {"alpha": "/tmp/changed"}), "CUSTOM")
            self.assertEqual(self.module.running(self.state, 123, {"beta": "/tmp/other"}), "CUSTOM")

    def test_missing_dead_reused_or_malformed_snapshot_is_unknown(self):
        self.assertEqual(self.module.running(self.state, 123, {}), "UNKNOWN")

        with patch.object(self.module, "process_identity", return_value="old-process"):
            self.module.record(self.state, 123, "alpha", "/tmp/alpha")
        for identity in (None, "replacement-process"):
            with patch.object(self.module, "process_identity", return_value=identity):
                self.assertEqual(self.module.running(self.state, 123, {"alpha": "/tmp/alpha"}), "UNKNOWN")
        with patch.object(self.module, "process_identity", return_value="old-process"):
            self.assertEqual(self.module.running(self.state, 456, {}), "UNKNOWN")
        self.state.write_text("broken json")
        self.assertEqual(self.module.running(self.state, 123, {}), "UNKNOWN")

    @unittest.skipUnless(os.name == "posix", "POSIX process identity required")
    def test_live_process_identity_can_be_recorded_and_read(self):
        self.module.record(self.state, os.getpid(), "alpha", "/tmp/alpha")
        self.assertEqual(self.module.running(self.state, os.getpid(), {"alpha": "/tmp/alpha"}), "alpha")


@unittest.skipUnless(os.name == "posix", "POSIX shell required")
class PosixWorkspaceTests(unittest.TestCase):
    def run_function(self, body):
        source = (ROOT / "scripts/agentdock.sh").read_text().rsplit('case "${1:-help}" in', 1)[0]
        return subprocess.run(["bash", "-c", source + "\n" + body], capture_output=True, text=True, timeout=10)

    def test_status_reports_workspace_match_mismatch_and_stopped(self):
        for live, actual, expected in ((True, "alpha", "YES"), (True, "beta", "NO"),
                                       (True, "UNKNOWN", "UNKNOWN"), (False, "alpha", "NO")):
            with self.subTest(live=live, actual=actual):
                body = '''
load_config() { DEFAULT_WORKSPACE=alpha; PORT=18765; }
curl() { return %s; }
pid_alive() { return 1; }
running_workspace() { echo %s; }
status_cmd
''' % (0 if live else 1, actual)
                result = self.run_function(body)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Default (Configured) : alpha", result.stdout)
                self.assertIn("Default (Running)    : " + (actual if live else "STOPPED"), result.stdout)
                self.assertIn("Config Applied       : " + expected, result.stdout)

    def test_docker_status_requires_live_container(self):
        for live, expected in (("true", "alpha"), ("false", "UNAVAILABLE")):
            result = self.run_function('''
docker() { printf '%s\\n'; }
running_workspace docker
''' % (live + "\nAGENTDOCK_DEFAULT_DIR=/home/agentdock/AgentDock/workspaces/alpha"))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), expected)


if __name__ == "__main__":
    unittest.main()
