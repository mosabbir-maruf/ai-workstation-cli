import os
import subprocess
import time
import unittest
import urllib.request
from pathlib import Path

class ProcessAndSseReliabilityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parent.parent
        cls.port = 18890
        cls.api_key = "test-process-sse-key-456"
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
            raise RuntimeError("Daemon failed to start for ProcessAndSseReliabilityTest")

    @classmethod
    def tearDownClass(cls):
        cls.daemon_proc.terminate()
        cls.daemon_proc.wait(timeout=3)

    def test_subprocess_timeout(self):
        import sys
        sys.path.insert(0, str(self.root / "daemon"))
        from server import _run_cmd_sync

        ok, out = _run_cmd_sync(["sleep", "5"], timeout=0.5)
        self.assertFalse(ok)
        self.assertIn("timed out after 0.5s", out)

    def test_subprocess_descendant_termination(self):
        import sys
        sys.path.insert(0, str(self.root / "daemon"))
        from server import _run_cmd_sync

        # Command that spawns a background descendant sleep process
        cmd = ["bash", "-c", "sleep 10 & wait"]
        t0 = time.time()
        ok, out = _run_cmd_sync(cmd, timeout=0.5)
        duration = time.time() - t0

        self.assertFalse(ok)
        self.assertIn("timed out after 0.5s", out)
        self.assertLess(duration, 2.0, "Descendant process group was not terminated on timeout")

    def test_subprocess_output_truncation(self):
        import sys
        sys.path.insert(0, str(self.root / "daemon"))
        from server import _run_cmd_sync

        # Generate ~2MB of output
        ok, out = _run_cmd_sync(["python3", "-c", "print('A' * 2000000)"], timeout=5.0)
        self.assertTrue(ok)
        self.assertIn("[OUTPUT TRUNCATED: Exceeded 1MB buffer limit]", out)
        self.assertLessEqual(len(out), 1024 * 1024 + 100)

    def test_concurrent_sse_subscribers(self):
        # Verify query token is rejected for security
        req_token_url = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/logs/app?token={self.api_key}"
        )
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req_token_url, timeout=2)
        self.assertEqual(ctx.exception.code, 401)

        # Open 2 concurrent SSE connections using Authorization header
        req1 = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/logs/app",
            headers={"Authorization": f"Bearer {self.api_key}"}
        )
        req2 = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/logs/app",
            headers={"Authorization": f"Bearer {self.api_key}"}
        )

        res1 = urllib.request.urlopen(req1, timeout=5)
        res2 = urllib.request.urlopen(req2, timeout=5)

        self.assertEqual(res1.status, 200)
        self.assertEqual(res2.status, 200)

        # Both receive initial message
        line1 = res1.readline()
        line2 = res2.readline()
        self.assertTrue(b"event:" in line1 or b"data:" in line1 or b": keepalive" in line1)
        self.assertTrue(b"event:" in line2 or b"data:" in line2 or b": keepalive" in line2)

        # Close client 1; client 2 must remain open and functional
        res1.close()

        # Read next line from client 2 without error
        line2_next = res2.readline()
        self.assertIsNotNone(line2_next)
        res2.close()

if __name__ == '__main__':
    unittest.main()
