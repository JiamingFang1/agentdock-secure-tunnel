"""Offline regression tests; never use real credentials, Docker or GitHub."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('download_release', ROOT / 'scripts/download-release.py')
dl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dl)
BINARY = b'#!/bin/sh\nprintf "0.0.14 test-runtime\\n"\n'


def make_zip(path, entries=None):
    if entries is None:
        entries = {'bin/tunnel-client-runtime-cloudflared': BINARY,
                   'licenses/tunnel-client-licenses.txt': b'not executable',
                   'tunnel-client.spdx.json': b'{}'}
    with zipfile.ZipFile(path, 'w') as archive:
        for name, value in entries.items():
            archive.writestr(name, value)


def metadata(archive):
    name = 'tunnel-client-runtime-cloudflared-v0.0.14-darwin-arm64.zip'
    return {'tag_name': 'v0.0.14', 'assets': [{
        'name': name, 'browser_download_url': 'https://github.com/openai/tunnel-client/releases/download/v0.0.14/' + name,
        'digest': 'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest()}]}


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='agentdock-test-')
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.env = mock.patch.dict(os.environ, {}, clear=False)
        self.env.start()
        self.addCleanup(self.env.stop)
        for name in ('TUNNEL_CLIENT_VERSION', 'AGENTDOCK_VERSION', 'AGENTDOCK_CONNECT_TIMEOUT',
                     'AGENTDOCK_DOWNLOAD_TIMEOUT', 'AGENTDOCK_METADATA_TIMEOUT'):
            os.environ.pop(name, None)

    def test_macos_arm_and_linux_platforms(self):
        for system, machine, expected in [('Darwin','arm64',('darwin','arm64')),
                                          ('Darwin','x86_64',('darwin','amd64')),
                                          ('Linux','aarch64',('linux','arm64'))]:
            with self.subTest(system=system, machine=machine), mock.patch.object(dl.platform,'system',return_value=system), mock.patch.object(dl.platform,'machine',return_value=machine):
                self.assertEqual(dl.detect_platform(), expected)

    def test_json_pretty_and_compact(self):
        archive = self.root / 'fake.zip'; make_zip(archive)
        data = metadata(archive)
        for indent in (None, 2):
            path = self.root / 'release.json'; path.write_text(json.dumps(data, indent=indent))
            asset = dl.select_asset(dl.parse_release(path), 'tunnel-client', 'darwin', 'arm64')
            self.assertTrue(asset['name'].endswith('darwin-arm64.zip'))

    def test_invalid_json_has_clear_error(self):
        path = self.root / 'release.json'; path.write_text('<html>proxy error</html>')
        with self.assertRaisesRegex(dl.DownloadError, 'invalid JSON'):
            dl.parse_release(path)

    def test_api_error_is_not_release(self):
        path = self.root / 'release.json'; path.write_text('{"message":"rate limit"}')
        with self.assertRaisesRegex(dl.DownloadError, 'no release assets'):
            dl.parse_release(path)

    def test_missing_asset_is_not_silent(self):
        with self.assertRaisesRegex(dl.DownloadError, 'darwin-arm64.zip'):
            dl.select_asset({'tag_name':'v0.0.14','assets':[]}, 'tunnel-client', 'darwin', 'arm64')

    def test_asset_url_cannot_point_to_other_host(self):
        for url in ('http://github.com/openai/tunnel-client/releases/download/x/a.zip',
                    'https://example.com/a.zip', 'https://github.com/other/repo/releases/download/x/a.zip'):
            with self.subTest(url=url), self.assertRaises(dl.DownloadError):
                dl.asset_url({'browser_download_url':url},'openai/tunnel-client')

    def test_select_executable_not_license(self):
        archive = self.root/'fake.zip'; make_zip(archive)
        output = self.root/'output'
        dl.extract_binary(archive,output,'tunnel-client')
        self.assertEqual(output.read_bytes(), BINARY)
        self.assertTrue(os.access(output,os.X_OK))

    def test_traversal_member_is_not_executable(self):
        archive = self.root/'fake.zip'; make_zip(archive, {'../tunnel-client':BINARY})
        with self.assertRaises(dl.DownloadError):
            dl.extract_binary(archive,self.root/'output','tunnel-client')
        self.assertFalse((self.root/'output').exists())

    def test_symlink_member_rejected(self):
        archive = self.root/'fake.zip'
        with zipfile.ZipFile(archive,'w') as bundle:
            entry = zipfile.ZipInfo('tunnel-client'); entry.create_system=3
            entry.external_attr=(stat.S_IFLNK | 0o777) << 16
            bundle.writestr(entry,'/etc/passwd')
        with self.assertRaises(dl.DownloadError):
            dl.extract_binary(archive,self.root/'output','tunnel-client')

    def test_ambiguous_binary_rejected(self):
        archive = self.root/'fake.zip'
        make_zip(archive, {'a/tunnel-client':BINARY,'b/tunnel-client':BINARY})
        with self.assertRaisesRegex(dl.DownloadError,'exactly one'):
            dl.extract_binary(archive,self.root/'output','tunnel-client')

    def test_native_tar_extracts_only_agentdock(self):
        archive = self.root/'agentdock.tar.gz'
        with tarfile.open(archive,'w:gz') as bundle:
            entry=tarfile.TarInfo('bin/agentdock'); entry.size=len(BINARY)
            bundle.addfile(entry,io.BytesIO(BINARY))
            bad=tarfile.TarInfo('../should-not-exist'); bad.size=1
            bundle.addfile(bad,io.BytesIO(b'x'))
        output=self.root/'native'; dl.extract_binary(archive,output,'agentdock')
        self.assertEqual(output.read_bytes(),BINARY)
        self.assertFalse((self.root.parent/'should-not-exist').exists())

    def test_checksum_failure(self):
        path=self.root/'blob'; path.write_bytes(b'corrupt')
        with self.assertRaisesRegex(dl.DownloadError,'SHA-256 mismatch'):
            dl.verify_digest(path,'0'*64)

    def test_checksum_manifest_fallback(self):
        asset={'name':'test.zip'}
        release={'assets':[{'name':'SHA256SUMS.txt', 'browser_download_url':'https://github.com/openai/tunnel-client/releases/download/v0.0.14/SHA256SUMS.txt'}]}
        def fake_fetch(url,path,archive=False):
            path.write_text('a'*64+'  other.zip\n'+'b'*64+'  test.zip\n')
        with mock.patch.object(dl,'fetch',side_effect=fake_fetch):
            self.assertEqual(dl.expected_digest(release,asset,'openai/tunnel-client',self.root),'b'*64)

    def test_no_checksum_refuses_install(self):
        with self.assertRaisesRegex(dl.DownloadError,'No verifiable SHA-256'):
            dl.expected_digest({'assets':[]},{'name':'a.zip'},'openai/tunnel-client',self.root)

    def test_timeout_retried_once_and_bounded(self):
        response=subprocess.CompletedProcess([],28,b'000')
        with mock.patch.object(dl.subprocess,'run',return_value=response) as run, mock.patch.object(dl.shutil,'which',return_value='/usr/bin/curl'), mock.patch.object(dl.time,'sleep'):
            with self.assertRaisesRegex(dl.DownloadError,'curl 28'):
                dl.fetch('https://api.github.com/repos/openai/tunnel-client/releases/latest',self.root/'result')
            self.assertEqual(run.call_count,2)
            args=run.call_args.args[0]
            self.assertIn('--connect-timeout',args); self.assertIn('--max-time',args)
            self.assertEqual(run.call_args.kwargs['timeout'],55)
            self.assertNotIn('Authorization',str(args))

    def test_403_explains_rate_limit_without_retries(self):
        with mock.patch.object(dl.subprocess,'run',return_value=subprocess.CompletedProcess([],22,b'403')) as run, mock.patch.object(dl.shutil,'which',return_value='/usr/bin/curl'):
            with self.assertRaisesRegex(dl.DownloadError,'rate-limited'):
                dl.fetch('https://api.github.com/repos/openai/tunnel-client/releases/latest',self.root/'result')
            self.assertEqual(run.call_count,1)

    def test_bad_timeout_configuration_rejected(self):
        with mock.patch.dict(os.environ,{'AGENTDOCK_CONNECT_TIMEOUT':'0'}):
            with self.assertRaises(dl.DownloadError): dl.positive_env('AGENTDOCK_CONNECT_TIMEOUT',10)

    def test_version_url(self):
        self.assertTrue(dl.release_url('openai/tunnel-client','0.0.14').endswith('/tags/v0.0.14'))
        with self.assertRaises(dl.DownloadError): dl.release_url('openai/tunnel-client','../../x')

    def run_install(self, destination, bad_hash=False, force=False, corrupt=False):
        archive=self.root/'fixture.zip'; make_zip(archive)
        if corrupt: archive.write_bytes(b'not a zip')
        data=metadata(archive)
        if bad_hash: data['assets'][0]['digest']='sha256:'+'0'*64
        def fake_fetch(url,target,archive=False):
            if url.startswith('https://api.github.com/'):
                target.write_text(json.dumps(data,separators=(',',':')))
            else:
                shutil.copyfile(self.root/'fixture.zip',target)
        with mock.patch.object(dl,'fetch',side_effect=fake_fetch), mock.patch.object(dl,'detect_platform',return_value=('darwin','arm64')):
            dl.install('tunnel-client',destination,force=force)

    def test_successful_install_then_offline_cache(self):
        output=self.root/'bin'/'tunnel-client'
        self.run_install(output)
        self.assertIn('0.0.14',dl.binary_version(output))
        with mock.patch.object(dl,'fetch',side_effect=AssertionError('must stay offline')):
            dl.install('tunnel-client',output)
        self.assertEqual(list(output.parent.glob('.download-*')),[])

    def test_failed_update_preserves_old_binary(self):
        output=self.root/'tunnel-client'; output.write_bytes(BINARY); output.chmod(0o755)
        with self.assertRaises(dl.DownloadError): self.run_install(output,bad_hash=True,force=True)
        self.assertEqual(output.read_bytes(),BINARY)
        self.assertEqual(list(output.parent.glob('.download-*')),[])

    def test_corrupt_archive_preserves_old_binary(self):
        output=self.root/'tunnel-client'; output.write_bytes(BINARY); output.chmod(0o755)
        with self.assertRaises(zipfile.BadZipFile): self.run_install(output,force=True,corrupt=True)
        self.assertEqual(output.read_bytes(),BINARY)

    def test_invalid_cached_file_is_repaired(self):
        output=self.root/'tunnel-client'; output.write_bytes(b'license text'); output.chmod(0o755)
        self.run_install(output)
        self.assertEqual(output.read_bytes(),BINARY)


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='agentdock launcher space ')
        self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        (self.root/'scripts').mkdir()
        shutil.copyfile(ROOT/'agentdock',self.root/'agentdock')
        # Real launcher, inert script targets; deliberately outside repository cwd.
        (self.root/'scripts'/'agentdock.sh').write_text('printf "MAIN:%s\\n" "$1"\n')
        (self.root/'scripts'/'bootstrap-tunnel.sh').write_text('echo BOOTSTRAP\n')

    def invoke(self,command):
        return subprocess.run(['bash',str(self.root/'agentdock'),command],cwd='/',capture_output=True,text=True,timeout=10)

    def test_help_status_stop_logs_do_not_bootstrap(self):
        for command in ('help','status','stop','logs'):
            with self.subTest(command=command):
                result=self.invoke(command)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertNotIn('BOOTSTRAP',result.stdout)
                self.assertIn('MAIN:'+command,result.stdout)

    def test_install_bootstraps_from_outside_repo(self):
        result=self.invoke('install')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('BOOTSTRAP',result.stdout)
        self.assertIn('MAIN:install',result.stdout)

    def test_bootstrap_failure_does_not_run_install(self):
        (self.root/'scripts'/'bootstrap-tunnel.sh').write_text('exit 28\n')
        result=self.invoke('install')
        self.assertEqual(result.returncode,28)
        self.assertNotIn('MAIN:',result.stdout)
        self.assertIn('exit 28',result.stderr)


class MainScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='agentdock-main-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root/'scripts').mkdir()
        shutil.copyfile(ROOT/'agentdock', self.root/'agentdock')
        for name in ('agentdock.sh','bootstrap-tunnel.sh','download-release.py'):
            shutil.copyfile(ROOT/'scripts'/name, self.root/'scripts'/name)
        self.work = self.root/'workspace'; self.work.mkdir()
        (self.root/'config.yaml').write_text(
            "deployment_mode: 'docker'\n"
            "tunnel_id: 'tunnel_0123456789abcdef0123456789abcdef'\n"
            "runtime_api_key: 'TEST_FAKE_NON_SECRET_DO_NOT_USE'\n"
            "agentdock_port: 18765\n"
            "default_workspace: 'workspace'\n"
            "workspaces:\n  - path: '{}'\n    mode: 'rw'\n".format(self.work))
        self.bin = self.root/'mock-bin'; self.bin.mkdir()
        (self.bin/'docker').write_text('#!/bin/sh\ncase "$*" in *pull*) exit "${TEST_PULL_EXIT:-0}";; *) exit 0;; esac\n')
        (self.bin/'id').write_text('#!/bin/sh\nprintf "1000\n"\n')
        for path in self.bin.iterdir(): path.chmod(0o755)
        runtime_bin = self.root/'.runtime'/'bin'; runtime_bin.mkdir(parents=True)
        executable = runtime_bin/'tunnel-client'; executable.write_bytes(BINARY); executable.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ['PATH'])

    def invoke(self, command):
        return subprocess.run(['bash', str(self.root/'agentdock'), command], cwd='/',
                              env=self.env, capture_output=True, text=True, timeout=20)

    def test_docker_install_with_cached_tunnel(self):
        result = self.invoke('install')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('Installed in docker mode', result.stdout)
        self.assertEqual((self.root/'.runtime'/'deployment.txt').read_text(),'docker')
        self.assertIn(str(self.work), (self.root/'.runtime'/'compose.yaml').read_text())
        self.assertNotIn('TEST_FAKE_NON_SECRET_DO_NOT_USE', (self.root/'.runtime'/'compose.yaml').read_text())

    def test_failed_docker_pull_has_error_without_install_marker(self):
        self.env['TEST_PULL_EXIT'] = '17'
        result = self.invoke('install')
        self.assertEqual(result.returncode,17,result.stderr)
        self.assertIn('exit 17',result.stderr)
        self.assertNotIn('TEST_FAKE_NON_SECRET_DO_NOT_USE',result.stderr+result.stdout)
        self.assertFalse((self.root/'.runtime'/'deployment.txt').exists())

    def test_empty_logs_succeeds_without_download(self):
        result = self.invoke('logs')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('Preparing',result.stderr)


if __name__=='__main__': unittest.main()
