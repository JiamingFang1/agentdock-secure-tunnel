#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
trap 'rc=$?; printf "ERROR: tunnel-client bootstrap failed (exit %s). See the message above.\n" "$rc" >&2; exit "$rc"' ERR

if ! command -v python3 >/dev/null 2>&1; then
  printf 'ERROR: Python 3 is required to parse release metadata safely. Install Python 3, then retry.\n' >&2
  exit 1
fi
mkdir -p "$ROOT_DIR/.runtime/bin"
chmod 700 "$ROOT_DIR/.runtime"
exec python3 "$ROOT_DIR/scripts/download-release.py" tunnel-client "$ROOT_DIR/.runtime/bin/tunnel-client"
