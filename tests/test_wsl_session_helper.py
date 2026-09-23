"""Exercise the actual POSIX lease helper; never start Docker or WSL."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipIf(os.name == 'nt', 'POSIX shell helper runs inside Linux, not CMD')
class LeaseHelperTests(unittest.TestCase):
    def run_holder(self, replacement):
        with tempfile.TemporaryDirectory(prefix='agentdock lease ') as directory:
            lease = Path(directory) / 'lease file'
            marker = 'a' * 32
            lease.write_text(marker)
            ready = Path(directory) / 'ready file'
            process = subprocess.Popen(['sh', str(ROOT / 'scripts/wsl-session.sh'), str(lease), str(ready), marker], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                for _ in range(100):
                    if ready.exists() and ready.read_text().strip() == marker:
                        break
                    if process.poll() is not None:
                        break
                    import time; time.sleep(0.05)
                self.assertTrue(ready.exists(), 'helper did not create ready file')
                self.assertEqual(ready.read_text().strip(), marker)
                self.assertIsNone(process.poll())
                if replacement is None:
                    lease.unlink()
                else:
                    lease.write_text(replacement)
                self.assertEqual(process.wait(timeout=6), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdout.close()
                process.stderr.close()

    def test_revoked_lease_exits_without_shutting_down_distro(self):
        self.run_holder(None)

    def test_new_owner_expires_old_holder(self):
        self.run_holder('b' * 32)

    def test_missing_lease_does_not_claim_ready(self):
        with tempfile.TemporaryDirectory(prefix='agentdock lease missing ') as directory:
            ready = Path(directory) / 'ready'
            result = subprocess.run(['sh', str(ROOT / 'scripts/wsl-session.sh'), '/nonexistent/agentdock-lease', str(ready), 'a' * 32], capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(ready.exists())


if __name__ == '__main__':
    unittest.main()
