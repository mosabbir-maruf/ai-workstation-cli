import io
import os
import shutil
import subprocess
import tarfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

class StateTransferE2ETest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parent.parent
        cls.backups_dir = Path.home() / "aiws-state-backups"
        cls.backups_dir.mkdir(parents=True, exist_ok=True)

        cls.port = 18889
        cls.api_key = "test-state-key-xyz987"
        cls.env = os.environ.copy()
        cls.env["WORKSTATION_API_KEY"] = cls.api_key
        cls.env["WORKSTATION_DAEMON_PORT"] = str(cls.port)
        cls.env["WORKSTATION_DAEMON_HOST"] = "127.0.0.1"

        cls.daemon_proc = subprocess.Popen(
            ["python3", "daemon/server.py"],
            cwd=str(cls.root),
            env=cls.env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )

        ready = False
        for _ in range(50):
            try:
                req = urllib.request.Request(
                    f"http://127.0.0.1:{cls.port}/api/health",
                    headers={"Authorization": f"Bearer {cls.api_key}"}
                )
                with urllib.request.urlopen(req, timeout=0.5) as res:
                    if res.status == 200:
                        ready = True
                        break
            except Exception:
                time.sleep(0.05)

        if not ready:
            cls.daemon_proc.terminate()
            raise RuntimeError("Daemon failed to start for StateTransferE2ETest")

    @classmethod
    def tearDownClass(cls):
        cls.daemon_proc.terminate()
        cls.daemon_proc.wait(timeout=3)

    def setUp(self):
        # Create test archives
        self.old_archive = self.backups_dir / "aiws-state-20260101-000000.tar.gz"
        self.new_archive = self.backups_dir / "aiws-state-20261014-120000.tar.gz"

        self.old_content = b"ARCHIVE_DATA_OLD_20260101"
        self.new_content = b"ARCHIVE_DATA_NEW_20261014"

        self.old_archive.write_bytes(self.old_content)
        time.sleep(0.05)
        self.new_archive.write_bytes(self.new_content)

    def tearDown(self):
        for f in self.backups_dir.glob("aiws-state-2026*.tar.gz"):
            try:
                f.unlink()
            except Exception:
                pass

    def test_state_download_specific_archive_and_byte_identity(self):
        # Request specific old archive
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/state/download?file=aiws-state-20260101-000000.tar.gz",
            headers={"Authorization": f"Bearer {self.api_key}"}
        )
        with urllib.request.urlopen(req) as res:
            self.assertEqual(res.status, 200)
            self.assertEqual(res.headers.get("Content-Type"), "application/gzip")
            self.assertIn("aiws-state-20260101-000000.tar.gz", res.headers.get("Content-Disposition", ""))
            self.assertIn("private, no-store", res.headers.get("Cache-Control", ""))
            data = res.read()
            self.assertEqual(data, self.old_content)

    def test_state_download_default_newest_archive(self):
        # Request without ?file= returns newest archive
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/state/download",
            headers={"Authorization": f"Bearer {self.api_key}"}
        )
        with urllib.request.urlopen(req) as res:
            self.assertEqual(res.status, 200)
            data = res.read()
            self.assertEqual(data, self.new_content)

    def test_state_download_nonexistent_returns_404(self):
        # Requesting nonexistent file returns 404, not fallback to newest
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/state/download?file=aiws-state-nonexistent.tar.gz",
            headers={"Authorization": f"Bearer {self.api_key}"}
        )
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req)
        self.assertEqual(ctx.exception.code, 404)

    def test_state_download_traversal_rejected_with_404(self):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/state/download?file=../../etc/passwd",
            headers={"Authorization": f"Bearer {self.api_key}"}
        )
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req)
        self.assertEqual(ctx.exception.code, 404)

    def test_state_import_raw_gzip_body_handled(self):
        # Build in-memory valid tar.gz
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            data = b"KEY=VALUE\n"
            info = tarfile.TarInfo(name="manifest")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        archive_bytes = buf.getvalue()

        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/state/import",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/gzip",
            },
            data=archive_bytes
        )
        with urllib.request.urlopen(req) as res:
            self.assertEqual(res.status, 200)

        # Confirm temporary archive was cleaned up
        temp_imports = list(self.backups_dir.glob("import-*.tar.gz"))
        self.assertEqual(len(temp_imports), 0, "Temporary import archive was not cleaned up")

    def test_state_import_cli_rejects_unsafe_paths_and_preserves_state(self):
        # Create an archive with an illegal entry outside manifest/.env/dsh/*
        bad_buf = io.BytesIO()
        with tarfile.open(fileobj=bad_buf, mode="w:gz") as tar:
            data = b"malicious content"
            info = tarfile.TarInfo(name="evil_script.sh")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        bad_archive = self.backups_dir / "bad-import-test.tar.gz"
        bad_archive.write_bytes(bad_buf.getvalue())

        # Create baseline state to test rollback preservation
        test_env = self.root / ".env"
        orig_content = test_env.read_bytes() if test_env.is_file() else b"TEST_KEY=ORIGINAL\n"
        test_env.write_bytes(orig_content)

        res = subprocess.run(
            ["bash", str(self.root / "scripts" / "aiws"), "state", "import", str(bad_archive)],
            cwd=str(self.root),
            capture_output=True,
            text=True
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("State archive contains unsafe or unexpected files", res.stderr)

        # Assert prior state was preserved and not wiped out
        self.assertEqual(test_env.read_bytes(), orig_content)
        bad_archive.unlink()

if __name__ == '__main__':
    unittest.main()
