#!/usr/bin/env python3
"""Verified, bounded-time release downloads for macOS/Linux (Python 3.8+).

No OpenAI key is read from config.yaml or sent to GitHub. curl is used so the
caller's HTTPS_PROXY/ALL_PROXY settings continue to work. No third-party Python
modules, grep pipelines, or external archive commands are required.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from urllib.parse import quote, urlparse
import zipfile


class DownloadError(Exception):
    pass


def log(message):
    print(message, file=sys.stderr, flush=True)


def positive_env(name, default):
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError:
        raise DownloadError('{} must be a positive integer.'.format(name))
    if value < 1 or value > 86400:
        raise DownloadError('{} must be between 1 and 86400 seconds.'.format(name))
    return value


def detect_platform():
    systems = {'Darwin': 'darwin', 'Linux': 'linux'}
    machines = {'x86_64': 'amd64', 'amd64': 'amd64', 'arm64': 'arm64', 'aarch64': 'arm64'}
    system, machine = platform.system(), platform.machine().lower()
    if system not in systems or machine not in machines:
        raise DownloadError('Unsupported platform: {}/{}'.format(system, machine))
    return systems[system], machines[machine]


def fetch(url, target, archive=False):
    """At most two bounded attempts. Never log credentials or curl command lines."""
    if shutil.which('curl') is None:
        raise DownloadError('curl is required; install it before retrying.')
    connect = positive_env('AGENTDOCK_CONNECT_TIMEOUT', 10)
    timeout = positive_env('AGENTDOCK_DOWNLOAD_TIMEOUT' if archive else 'AGENTDOCK_METADATA_TIMEOUT',
                           600 if archive else 45)
    for attempt in (1, 2):
        log('  Request {}/2 (connect {}s, transfer {}s): {}'.format(attempt, connect, timeout, url))
        args = ['curl', '--fail', '--location', '--show-error',
                '--proto', '=https', '--proto-redir', '=https',
                '--connect-timeout', str(connect), '--max-time', str(timeout),
                '--header', 'User-Agent: agentdock-secure-tunnel',
                '--output', str(target), '--write-out', '%{http_code}']
        args += ['--progress-bar'] if archive else ['--silent']
        args.append(url)
        try:
            # stderr is inherited for curl progress/errors; no --verbose or auth
            # headers are used. Python adds a wall-clock bound as a final guard.
            result = subprocess.run(args, stdout=subprocess.PIPE, timeout=timeout + 10)
            status = result.stdout.decode('ascii', errors='replace').strip()
            code = result.returncode
        except subprocess.TimeoutExpired:
            code, status = 28, '000'
        if code == 0 and status == '200':
            return
        retryable = code in (5, 6, 7, 18, 28, 35, 52, 55, 56) or status in ('408', '429', '500', '502', '503', '504')
        if attempt == 1 and retryable:
            log('  Request failed (curl {}, HTTP {}); retrying once.'.format(code, status))
            time.sleep(2)
            continue
        if status in ('403', '429'):
            hint = 'GitHub denied or rate-limited the request. Retry later; do not use your OpenAI API key as a GitHub token.'
        elif code == 60:
            hint = 'TLS certificate validation failed. Fix the CA/proxy configuration; do not disable TLS verification.'
        elif code in (5, 6, 7, 28, 35, 52, 55, 56):
            hint = 'Check terminal DNS/network and HTTPS_PROXY/ALL_PROXY. Browser connectivity does not prove terminal connectivity.'
        else:
            hint = 'Check the release URL and network response.'
        raise DownloadError('Download failed (curl {}, HTTP {}). {}'.format(code, status, hint))


def release_url(repo, version):
    if version == 'latest':
        suffix = 'latest'
    else:
        tag = version if version.startswith('v') else 'v' + version
        if not re.fullmatch(r'v[0-9][A-Za-z0-9._-]*', tag):
            raise DownloadError('Invalid release version: use latest or a tag such as v0.0.14.')
        suffix = 'tags/' + quote(tag, safe='')
    return 'https://api.github.com/repos/{}/releases/{}'.format(repo, suffix)


def parse_release(path):
    try:
        release = json.loads(path.read_text(encoding='utf-8'))
    except (ValueError, UnicodeError):
        raise DownloadError('GitHub returned invalid JSON (possibly a proxy error page).')
    if not isinstance(release, dict) or not isinstance(release.get('assets'), list):
        raise DownloadError('GitHub response has no release assets; check API access or rate limits.')
    tag = release.get('tag_name', '')
    if not isinstance(tag, str) or not re.fullmatch(r'v?[0-9][A-Za-z0-9._-]*', tag):
        raise DownloadError('GitHub response has an invalid release tag.')
    return release


def select_asset(release, component, system, arch):
    if component == 'tunnel-client':
        name = 'tunnel-client-runtime-cloudflared-{}-{}-{}.zip'.format(release['tag_name'], system, arch)
    else:
        name = 'agentdock_{}_{}.tar.gz'.format(system, arch)
    matches = [a for a in release['assets'] if isinstance(a, dict) and a.get('name') == name]
    if len(matches) != 1:
        raise DownloadError('Expected exactly one release asset: {} (found {}).'.format(name, len(matches)))
    return matches[0]


def asset_url(asset, repo):
    value = asset.get('browser_download_url', '')
    if not isinstance(value, str):
        raise DownloadError('Release asset has no download URL.')
    url = urlparse(value)
    if (url.scheme != 'https' or url.netloc != 'github.com'
            or not url.path.startswith('/{}/releases/download/'.format(repo))
            or url.query or url.fragment):
        raise DownloadError('Refusing an unexpected release asset URL.')
    return value


def expected_digest(release, asset, repo, temp):
    digest = asset.get('digest')
    if isinstance(digest, str) and re.fullmatch(r'sha256:[0-9a-fA-F]{64}', digest):
        return digest.split(':', 1)[1].lower()
    # Older GitHub API versions may omit digest. Use upstream checksum files.
    for name in (asset['name'] + '.sha256', 'SHA256SUMS.txt'):
        choices = [a for a in release['assets'] if isinstance(a, dict) and a.get('name') == name]
        if len(choices) != 1:
            continue
        checksum_file = temp / 'checksums.txt'
        fetch(asset_url(choices[0], repo), checksum_file)
        hashes = []
        for line in checksum_file.read_text(encoding='utf-8').splitlines():
            match = re.fullmatch(r'([0-9a-fA-F]{64})\s+\*?(.+)', line.strip())
            if match and PurePosixPath(match.group(2)).name == asset['name']:
                hashes.append(match.group(1).lower())
            elif name.endswith('.sha256') and re.fullmatch(r'[0-9a-fA-F]{64}', line.strip()):
                hashes.append(line.strip().lower())
        if len(set(hashes)) == 1:
            return hashes[0]
    raise DownloadError('No verifiable SHA-256 found for {}. Refusing to install.'.format(asset['name']))


def verify_digest(path, expected):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    if digest.hexdigest() != expected.lower():
        raise DownloadError('SHA-256 mismatch. Existing installation was not replaced.')


def binary_member(name, component):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or '\\' in name:
        return False
    base = path.name
    if component == 'agentdock':
        return base == 'agentdock'
    if base in ('tunnel-client', 'tunnel-client-runtime-cloudflared'):
        return True
    return bool(re.fullmatch(r'tunnel-client(?:-runtime-cloudflared)?-(?:v[0-9][A-Za-z0-9._-]*-)?(?:darwin|linux)-(?:amd64|arm64)', base))


def extract_binary(archive, output, component):
    """Extract just the regular executable, never unpack arbitrary archive paths."""
    if archive.name.endswith('.zip'):
        with zipfile.ZipFile(archive) as bundle:
            members = [m for m in bundle.infolist() if not m.is_dir()
                       and not stat.S_ISLNK(m.external_attr >> 16)
                       and binary_member(m.filename, component)]
            if len(members) != 1:
                raise DownloadError('Archive must contain exactly one regular {} executable (found {}).'.format(component, len(members)))
            if members[0].file_size > 256 * 1024 * 1024:
                raise DownloadError('Executable exceeds the 256 MiB safety limit.')
            with bundle.open(members[0]) as src, output.open('wb') as dest:
                shutil.copyfileobj(src, dest)
    else:
        with tarfile.open(archive, 'r:gz') as bundle:
            members = [m for m in bundle.getmembers() if m.isfile() and binary_member(m.name, component)]
            if len(members) != 1:
                raise DownloadError('Archive must contain exactly one regular {} executable (found {}).'.format(component, len(members)))
            if members[0].size > 256 * 1024 * 1024:
                raise DownloadError('Executable exceeds the 256 MiB safety limit.')
            with bundle.extractfile(members[0]) as src, output.open('wb') as dest:
                shutil.copyfileobj(src, dest)
    output.chmod(0o755)


def binary_version(path):
    try:
        result = subprocess.run([str(path), '--version'], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    text = result.stdout.decode('utf-8', errors='replace').strip()
    if result.returncode == 0 and re.search(r'\d+\.\d+', text):
        return text.splitlines()[0][:300]
    return None


def install(component, output, force=False):
    output = Path(os.path.abspath(str(output)))
    if output.is_symlink():
        raise DownloadError('Refusing to replace a symlink at the executable path.')
    repo = 'openai/tunnel-client' if component == 'tunnel-client' else 'uvwt/agentdock'
    system, arch = detect_platform()
    log('==> {} platform: {}/{}'.format(component, system, arch))
    if output.is_file() and not force:
        version = binary_version(output)
        if version:
            log('Using existing {}: {}'.format(component, version))
            return
        log('Existing {} is not runnable; attempting a verified replacement.'.format(component))
    version_name = 'TUNNEL_CLIENT_VERSION' if component == 'tunnel-client' else 'AGENTDOCK_VERSION'
    requested_version = os.environ.get(version_name, 'latest')
    output.parent.mkdir(parents=True, exist_ok=True)
    # Temporary files stay on the same filesystem, so promotion is atomic.
    with tempfile.TemporaryDirectory(prefix='.download-', dir=str(output.parent)) as tmp:
        temp = Path(tmp)
        metadata = temp / 'release.json'
        log('==> Querying GitHub release ({}: {})'.format(repo, requested_version))
        fetch(release_url(repo, requested_version), metadata)
        release = parse_release(metadata)
        asset = select_asset(release, component, system, arch)
        checksum = expected_digest(release, asset, repo, temp)
        log('==> Downloading {}'.format(asset['name']))
        archive = temp / asset['name']
        fetch(asset_url(asset, repo), archive, archive=True)
        verify_digest(archive, checksum)
        log('SHA-256 OK')
        staged = temp / component
        extract_binary(archive, staged, component)
        version = binary_version(staged)
        if version is None:
            raise DownloadError('Downloaded executable failed --version. Check OS/CPU compatibility or macOS security messages. Existing installation was not replaced.')
        os.replace(str(staged), str(output))
    log('Installed {}: {}'.format(component, version))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('component', choices=('tunnel-client', 'agentdock'))
    parser.add_argument('output', type=Path)
    parser.add_argument('--force', action='store_true', help='replace even a working cached executable')
    args = parser.parse_args()
    try:
        install(args.component, args.output, args.force)
    except KeyboardInterrupt:
        log('ERROR: Download cancelled. Existing installation was not replaced.')
        return 130
    except (DownloadError, OSError, ValueError, tarfile.TarError, zipfile.BadZipFile) as error:
        log('ERROR: {}'.format(error))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
