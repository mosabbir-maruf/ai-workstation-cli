import os
import subprocess
import time
import urllib.request
import urllib.error
import unittest

class DaemonAuthTest(unittest.TestCase):
    def test_startup_fails_without_key_or_insecure_flag(self):
        env = os.environ.copy()
        env.pop("WORKSTATION_API_KEY", None)
        env.pop("AIWS_INSECURE_LOCAL", None)
        proc = subprocess.run(
            ["python3", "daemon/server.py"],
            env=env,
            capture_output=True,
            text=True
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("refuses to start without an API key", proc.stderr)

    def test_daemon_authenticated_endpoints(self):
        env = os.environ.copy()
        env["WORKSTATION_API_KEY"] = "test-secret-key-12345"
        env["WORKSTATION_DAEMON_PORT"] = "18888"
        env["WORKSTATION_DAEMON_HOST"] = "127.0.0.1"

        proc = subprocess.Popen(
            ["python3", "daemon/server.py"],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        try:
            # Wait for daemon ready
            ready = False
            for _ in range(50):
                try:
                    req = urllib.request.Request(
                        "http://127.0.0.1:18888/api/health",
                        headers={"Authorization": "Bearer test-secret-key-12345"}
                    )
                    with urllib.request.urlopen(req, timeout=0.5) as res:
                        if res.status == 200:
                            ready = True
                            break
                except Exception:
                    time.sleep(0.05)

            self.assertTrue(ready, "Daemon did not start in time")

            # Test 1: Missing auth returns 401
            req_unauth = urllib.request.Request("http://127.0.0.1:18888/api/health")
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(req_unauth)
            self.assertEqual(ctx.exception.code, 401)

            # Test 2: Invalid auth returns 401
            req_bad = urllib.request.Request(
                "http://127.0.0.1:18888/api/health",
                headers={"Authorization": "Bearer wrong-key"}
            )
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(req_bad)
            self.assertEqual(ctx.exception.code, 401)

            # Test 3: Valid bearer returns 200
            req_good = urllib.request.Request(
                "http://127.0.0.1:18888/api/health",
                headers={"Authorization": "Bearer test-secret-key-12345"}
            )
            with urllib.request.urlopen(req_good) as res:
                self.assertEqual(res.status, 200)

            # Test 4: Sudo password rejected
            exec_req = urllib.request.Request(
                "http://127.0.0.1:18888/api/terminal/exec",
                headers={
                    "Authorization": "Bearer test-secret-key-12345",
                    "Content-Type": "application/json"
                },
                data=b'{"command": "echo test", "target": "host", "sudoPassword": "mypassword"}'
            )
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(exec_req)
            self.assertEqual(ctx.exception.code, 403)

        finally:
            proc.terminate()
            proc.wait(timeout=2)

if __name__ == '__main__':
    unittest.main()
