#!/usr/bin/env python3
"""Loopback-only management API for AgentDock Secure Tunnel.

No third-party dependencies. Does not expose tokens, logs, arbitrary shell,
filesystem browsing, or a generic command execution endpoint.
"""
from __future__ import annotations

import argparse
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
UI = Path(__file__).resolve().parent / "manager"
ALLOWED = frozenset(("start", "stop", "restart", "apply", "status"))
MAX_BODY = 4096
PORT = 18880
SESSION = secrets.token_urlsafe(32)


def list_workspaces(config_text):
    names = []
    inside = False
    current = None
    for line in config_text.splitlines():
        t = line.strip()
        if t == "workspaces:":
            inside = True
        elif inside and t.startswith("- "):
            if current:
                names.append(current)
            current = {"name": "", "path": "", "mode": "rw"}
            t = t[2:]
            if ":" in t:
                k, v = t.split(":", 1)
                if k.strip() in current:
                    current[k.strip()] = v.strip().strip("'\"")
        elif inside and current and ":" in t and not t.startswith("#"):
            k, v = t.split(":", 1)
            if k.strip() in current:
                current[k.strip()] = v.strip().strip("'\"")
    if current:
        names.append(current)
    for item in names:
        if not item["name"]:
            item["name"] = item["path"].rstrip("/\\").replace("\\", "/").split("/")[-1]
    return names


def get_selected_workspace(text):
    for line in text.splitlines():
        m = re.match(r"^default_workspace:\s*['\"]?([A-Za-z0-9._-]+)", line.strip())
        if m:
            return m.group(1)
    return ""


def set_selected_workspace(text, name):
    candidates = {ws["name"] for ws in list_workspaces(text) if ws["mode"] == "rw"}
    if name not in candidates:
        raise ValueError("workspace must be a configured read/write workspace")
    pattern = r"(?m)^(default_workspace:\s*)(?:'[^']*'|\"[^\"]*\"|[^#\r\n]+)"
    if len(re.findall(pattern, text)) != 1:
        raise ValueError("default_workspace must occur exactly once")
    return re.sub(pattern, lambda m: m.group(1) + "'" + name + "'", text, count=1)


def read_config():
    return (ROOT / "config.yaml").read_text(encoding="utf-8-sig")


def modify_default(name):
    target = ROOT / "config.yaml"
    old = read_config()
    new = set_selected_workspace(old, name)
    if new == old:
        return
    tmp = target.with_name(".config-web-" + secrets.token_hex(6))
    try:
        with tmp.open("x", encoding="utf-8", newline="\n") as fh:
            fh.write(new)
        os.replace(tmp, target)
    finally:
        tmp.unlink(missing_ok=True)


def execute(command):
    if command not in ALLOWED:
        raise ValueError("unsupported action")
    launcher = ROOT / "agentdock.cmd" if os.name == "nt" else ROOT / "agentdock"
    if not launcher.is_file():
        raise RuntimeError("AgentDock launcher not found")
    arguments = [str(launcher), command]
    if os.name != "nt":
        arguments.insert(0, "bash")
    result = subprocess.run(
        arguments, cwd=str(ROOT), capture_output=True, text=True, errors="replace",
        stdin=subprocess.DEVNULL, timeout=120, check=False,
    )
    # Never return potentially sensitive command output through the Web API.
    summary = {"ok": result.returncode == 0, "exit_code": result.returncode}
    for label, key in (("AgentDock", "agentdock"),
                       ("Tunnel", "tunnel"),
                       ("Control Plane", "control_plane")):
        pattern = r"(?m)^" + re.escape(label) + r"\s*:\s*(RUNNING|STOPPED|CONNECTED|UNVERIFIED)\s*$"
        found = re.search(pattern, result.stdout)
        if found:
            summary[key] = found.group(1)
        elif command == "status":
            summary[key] = "UNKNOWN"
    for label, key in (("Default (Configured)", "configured_workspace"),
                       ("Default (Running)", "running_workspace"),
                       ("Config Applied", "config_applied")):
        found = re.search(r"(?m)^" + re.escape(label) + r"\s*:\s*([A-Za-z0-9._-]+)\s*$", result.stdout)
        if found:
            summary[key] = found.group(1)
        elif command == "status":
            summary[key] = "UNVERIFIED" if key == "config_applied" else "UNKNOWN"
    if command in ("start", "restart", "apply") and summary["ok"]:
        # Verify running state separately instead of trusting a successful process exit.
        verified = execute("status")
        summary.update({key: verified[key] for key in
                        ("configured_workspace", "running_workspace", "config_applied")})
        if summary["config_applied"] != "YES":
            summary["ok"] = False
            summary["error"] = "running workspace differs from configuration or could not be verified"
    return summary


class Manager(BaseHTTPRequestHandler):
    server_version = "AgentDockManager/1.0"

    def log_message(self, fmt, *args):
        return  # No path/query/cookie logging.

    def _send(self, code, body, mime="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        if self.path == "/":
            self.send_header("Set-Cookie", "agentdock_session=" + SESSION + "; HttpOnly; SameSite=Strict; Path=/")
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self):
        cookie = self.headers.get("Cookie", "")
        tokens = [x.strip().split("=", 1)[1] for x in cookie.split(";")
                  if x.strip().startswith("agentdock_session=")]
        return len(tokens) == 1 and hmac.compare_digest(tokens[0], SESSION)

    def _local_origin(self):
        origin = self.headers.get("Origin", "")
        try:
            p = urlsplit(origin)
            return p.scheme == "http" and p.hostname in ("127.0.0.1", "localhost") and p.port == PORT
        except ValueError:
            return False

    def do_GET(self):
        if self.path == "/":
            self._send(200, (UI / "index.html").read_bytes(), "text/html; charset=utf-8")
        elif self.path in ("/app.js", "/style.css"):
            kind = "text/javascript" if self.path.endswith(".js") else "text/css"
            self._send(200, (UI / self.path[1:]).read_bytes(), kind + "; charset=utf-8")
        elif self.path == "/api/state":
            if not self._authorized():
                return self._send(403, {"error": "unauthorized"})
            try:
                text = read_config()
                status = execute("status")
                self._send(200, {"workspaces": list_workspaces(text),
                                 "default_workspace": get_selected_workspace(text),
                                 "configured_workspace": status["configured_workspace"],
                                 "running_workspace": status["running_workspace"],
                                 "config_applied": status["config_applied"]})
            except (OSError, UnicodeError):
                self._send(503, {"error": "configuration unavailable"})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._authorized() or not self._local_origin():
            return self._send(403, {"error": "forbidden"})
        if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
            return self._send(415, {"error": "JSON required"})
        try:
            size = int(self.headers.get("Content-Length", "-1"))
            if size < 0 or size > MAX_BODY:
                return self._send(413, {"error": "invalid size"})
            payload = json.loads(self.rfile.read(size))
            if not isinstance(payload, dict):
                raise ValueError("object expected")
            if self.path == "/api/action":
                result = execute(payload.get("action"))
            elif self.path == "/api/workspace":
                name = payload.get("name")
                if not isinstance(name, str):
                    raise ValueError("workspace name expected")
                modify_default(name)
                result = {"ok": True, "requires_apply": True}
            else:
                return self._send(404, {"error": "not found"})
            self._send(200, result)
        except (ValueError, TypeError, json.JSONDecodeError):
            self._send(400, {"error": "invalid request"})
        except (OSError, RuntimeError, subprocess.TimeoutExpired):
            self._send(500, {"error": "operation failed; use the CLI for diagnostics"})


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=PORT)
    args = p.parse_args()
    if args.port != PORT:
        p.error("management port is fixed to 18880 for origin enforcement")
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Manager)
    print("AgentDock Web Manager: http://127.0.0.1:18880/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
