"""HTTP security smoke tests for the GitHub-developed loopback manager."""
import http.client
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "scripts" / "manage.py"


def load_manager():
    spec = importlib.util.spec_from_file_location("manager_http_under_test", SOURCE)
    manager = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(manager)
    return manager


class HTTPManagerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.module = load_manager()
        self.root = Path(self.temp.name)
        (self.root / "config.yaml").write_text(
            "default_workspace: 'alpha'\nworkspaces:\n"
            "  - name: 'alpha'\n    path: '/tmp/alpha'\n    mode: 'rw'\n"
            "  - name: 'beta'\n    path: '/tmp/beta'\n    mode: 'ro'\n",
            encoding="utf-8",
        )
        self.old_root = self.module.ROOT
        self.module.ROOT = self.root
        self.addCleanup(setattr, self.module, "ROOT", self.old_root)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self.module.Manager)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.port = self.server.server_port

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request(method, path, body=body, headers=headers or {})
        res = conn.getresponse()
        value = res.read()
        headers_out = dict(res.getheaders())
        conn.close()
        return res.status, headers_out, value

    def test_requires_cookie_for_state(self):
        status, _, _ = self.request("GET", "/api/state")
        self.assertEqual(status, 403)

    def test_cookie_only_from_homepage_and_state_is_sanitized(self):
        status, headers, _ = self.request("GET", "/")
        self.assertEqual(status, 200)
        cookie = headers["Set-Cookie"].split(";", 1)[0]
        self.assertIn("HttpOnly", headers["Set-Cookie"])
        status, _, body = self.request("GET", "/api/state", headers={"Cookie": cookie})
        self.assertEqual(status, 200)
        state = json.loads(body)
        self.assertEqual(state["default_workspace"], "alpha")
        self.assertEqual([x["name"] for x in state["workspaces"]], ["alpha", "beta"])
        self.assertNotIn("runtime_api_key", state)

    def test_post_rejects_bad_origin_and_unknown_action(self):
        _, headers, _ = self.request("GET", "/")
        cookie = headers["Set-Cookie"].split(";", 1)[0]
        payload = json.dumps({"action": "anything"}).encode()
        base = {"Cookie": cookie, "Content-Type": "application/json"}
        status, _, _ = self.request("POST", "/api/action", body=payload, headers={**base, "Origin": "http://evil.invalid"})
        self.assertEqual(status, 403)
        status, _, _ = self.request("POST", "/api/action", body=payload,
                                    headers={**base, "Origin": "http://127.0.0.1:18880"})
        self.assertEqual(status, 400)

    def test_readonly_workspace_cannot_be_default(self):
        _, headers, _ = self.request("GET", "/")
        cookie = headers["Set-Cookie"].split(";", 1)[0]
        payload = json.dumps({"name": "beta"}).encode()
        status, _, _ = self.request("POST", "/api/workspace", body=payload, headers={
            "Cookie": cookie, "Content-Type": "application/json", "Origin": "http://127.0.0.1:18880"
        })
        self.assertEqual(status, 400)
        self.assertIn("default_workspace: 'alpha'", (self.root / "config.yaml").read_text())


if __name__ == "__main__":
    unittest.main()
