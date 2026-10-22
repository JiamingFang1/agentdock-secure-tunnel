"""Offline sanity checks for the standalone remote-developed Web Manager."""
import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "scripts" / "manage.py"


def load_manager():
    spec = importlib.util.spec_from_file_location("agentdock_manager_test", SRC)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ManagerTests(unittest.TestCase):
    def test_action_allowlist(self):
        module = load_manager()
        self.assertNotIn("logs", module.ALLOWED)
        self.assertNotIn("update", module.ALLOWED)
        with self.assertRaises(ValueError):
            module.execute("arbitrary command")

    def test_workspace_parser_and_default(self):
        module = load_manager()
        text = """deployment_mode: 'docker'
default_workspace: 'first'
workspaces:
  - path: '/home/example/first'
    mode: 'rw'
  - name: 'second'
    path: '/home/example/other'
    mode: 'ro'
"""
        names = module.list_workspaces(text)
        self.assertEqual([v["name"] for v in names], ["first", "second"])
        self.assertEqual(module.get_selected_workspace(text), "first")
        self.assertIn("default_workspace: 'first'", module.set_selected_workspace(text, "first"))
        with self.assertRaises(ValueError):
            module.set_selected_workspace(text, "second")
        with self.assertRaises(ValueError):
            module.set_selected_workspace(text, "missing")

    def test_status_is_redacted_to_known_labels(self):
        module = load_manager()
        from unittest.mock import patch
        from subprocess import CompletedProcess
        secret = "KEY_DO_NOT_RETURN_TEST"
        output = "AgentDock : RUNNING\nTunnel    : RUNNING\nControl Plane : CONNECTED\n" + secret
        with patch.object(module.subprocess, "run", return_value=CompletedProcess([], 0, output, "")):
            result = module.execute("status")
        self.assertEqual(result["agentdock"], "RUNNING")
        self.assertEqual(result["tunnel"], "RUNNING")
        self.assertEqual(result["control_plane"], "CONNECTED")
        self.assertNotIn(secret, repr(result))

    def test_static_assets_present(self):
        for path in ("index.html", "app.js", "style.css"):
            self.assertTrue((ROOT / "scripts" / "manager" / path).is_file())


if __name__ == "__main__":
    unittest.main()
