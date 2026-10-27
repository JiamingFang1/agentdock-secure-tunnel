#!/usr/bin/env python3
"""Process-bound native workspace evidence; never read or print process secrets."""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def process_identity(pid):
    if pid <= 0:
        return None
    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "lstart=", "-o", "comm="],
            capture_output=True, text=True, timeout=3, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def record(target, pid, workspace, path):
    identity = process_identity(pid)
    if not identity:
        raise RuntimeError("native process identity unavailable")
    data = {"pid": pid, "identity": identity, "workspace": workspace, "path": path}
    temporary = target.with_suffix(".tmp")
    temporary.write_text(json.dumps(data), encoding="utf-8")
    temporary.replace(target)


def running(target, pid, workspaces):
    try:
        data = json.loads(target.read_text(encoding="utf-8"))
        identity = process_identity(pid)
        if not identity or data["pid"] != pid or data["identity"] != identity:
            return "UNKNOWN"
        name = data["workspace"]
        if workspaces.get(name) != data["path"]:
            return "CUSTOM"
        return name
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError):
        return "UNKNOWN"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("record", "running"))
    parser.add_argument("state", type=Path)
    parser.add_argument("pid", type=int)
    parser.add_argument("workspace", nargs="?")
    parser.add_argument("path", nargs="?")
    args = parser.parse_args()
    if args.action == "record":
        try:
            record(args.state, args.pid, args.workspace, args.path)
        except (OSError, RuntimeError):
            print("Native workspace evidence could not be saved.", file=sys.stderr)
            return 1
    else:
        workspaces = {}
        for line in sys.stdin:
            name, path, _mode = line.rstrip("\n").split("|", 2)
            workspaces[name] = path
        print(running(args.state, args.pid, workspaces))


if __name__ == "__main__":
    sys.exit(main())
