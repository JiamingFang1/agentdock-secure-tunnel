set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT_DIR/.runtime"
BIN_DIR="$RUNTIME/bin"
DEST="$BIN_DIR/tunnel-client"

[ -x "$DEST" ] && exit 0

os_name() {
  case "$(uname -s)" in
    Darwin) echo darwin ;;
    Linux) echo linux ;;
    *) echo "Unsupported OS" >&2; exit 1 ;;
  esac
}

arch_name() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    arm64|aarch64) echo arm64 ;;
    *) echo "Unsupported architecture" >&2; exit 1 ;;
  esac
}

mkdir -p "$RUNTIME" "$BIN_DIR"
os="$(os_name)"
arch="$(arch_name)"
asset_url="$(curl -fsSL -H 'User-Agent: agentdock-secure-tunnel' https://api.github.com/repos/openai/tunnel-client/releases/latest \
  | grep 'browser_download_url' \
  | cut -d '"' -f 4 \
  | grep -E "tunnel-client-runtime-cloudflared-v.+-${os}-${arch}\\.zip$" \
  | head -n1)"

[ -n "$asset_url" ] || { echo "Unable to locate tunnel-client runtime-cloudflared asset for ${os}/${arch}" >&2; exit 1; }

echo "Installing OpenAI tunnel-client..."
archive="$RUNTIME/tunnel-client.zip"
extract="$RUNTIME/tunnel-client-extract"
rm -rf "$archive" "$extract"
mkdir -p "$extract"
curl -fL "$asset_url" -o "$archive"

if command -v unzip >/dev/null 2>&1; then
  unzip -q "$archive" -d "$extract"
else
  python3 -m zipfile -e "$archive" "$extract"
fi

bin="$(find "$extract" -type f -name 'tunnel-client-runtime-cloudflared*' | head -n1)"
[ -n "$bin" ] || bin="$(find "$extract" -type f -name 'tunnel-client*' | head -n1)"
[ -n "$bin" ] || { echo "No tunnel-client binary found in archive" >&2; find "$extract" -type f >&2; exit 1; }

cp "$bin" "$DEST"
chmod +x "$DEST"
rm -rf "$archive" "$extract"
"$DEST" --version
