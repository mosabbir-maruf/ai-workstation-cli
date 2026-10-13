import os
import subprocess
import sys
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

# Add daemon directory to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "daemon"))
from server import is_safe_model_url, fetch_safe_model_json

class DaemonSecurityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parent.parent
        cls.port = 18891
        cls.api_key = "test-framing-key-789"
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
            raise RuntimeError("Daemon failed to start for DaemonSecurityTest")

    @classmethod
    def tearDownClass(cls):
        cls.daemon_proc.terminate()
        cls.daemon_proc.wait(timeout=3)

    def test_ssrf_url_validation_comprehensive(self):
        # 1. Cloud metadata & link-local blocked
        self.assertFalse(is_safe_model_url("http://169.254.169.254/latest/meta-data/"))
        self.assertFalse(is_safe_model_url("http://metadata.google.internal/computeMetadata/v1/"))
        self.assertFalse(is_safe_model_url("http://instance-data/"))

        # 2. Private LAN IPv4 blocked
        self.assertFalse(is_safe_model_url("http://10.0.0.1:8080/v1"))
        self.assertFalse(is_safe_model_url("http://192.168.1.1:11434"))
        self.assertFalse(is_safe_model_url("http://172.16.0.5:8000"))

        # 3. Invalid schemes blocked
        self.assertFalse(is_safe_model_url("ftp://example.com/models"))
        self.assertFalse(is_safe_model_url("file:///etc/passwd"))
        self.assertFalse(is_safe_model_url("gopher://127.0.0.1:80"))
        self.assertFalse(is_safe_model_url(""))

        # 4. Loopback allowed for local model endpoints
        self.assertTrue(is_safe_model_url("http://127.0.0.1:11434"))
        self.assertTrue(is_safe_model_url("http://localhost:11434/v1"))

        # 5. Public providers allowed
        self.assertTrue(is_safe_model_url("https://api.openai.com/v1"))
        self.assertTrue(is_safe_model_url("https://api.deepseek.com"))

    def test_fetch_safe_model_blocks_ssrf_and_redirects(self):
        # Must immediately reject and return empty dict without making illegal network calls
        self.assertEqual(fetch_safe_model_json("http://169.254.169.254/latest/meta-data"), {})
        self.assertEqual(fetch_safe_model_json("http://192.168.1.1/models"), {})
        self.assertEqual(fetch_safe_model_json("http://10.0.0.1/models"), {})
        self.assertEqual(fetch_safe_model_json("http://metadata.google.internal/computeMetadata/v1"), {})

    def test_http_framing_oversized_header_rejected(self):
        # Sending a header line > 8192 bytes must return 431 Request Header Fields Too Large
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect(("127.0.0.1", self.port))
        long_header = "X-Oversized: " + ("A" * 9000) + "\r\n"
        req = f"GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\n{long_header}\r\n"
        s.sendall(req.encode("utf-8"))
        response = s.recv(4096).decode("utf-8", errors="replace")
        s.close()
        self.assertIn("431", response)

    def test_http_framing_invalid_content_length_rejected(self):
        # Sending non-numeric content-length must return 400 Bad Request
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect(("127.0.0.1", self.port))
        req = "POST /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: invalid-number\r\n\r\n"
        s.sendall(req.encode("utf-8"))
        response = s.recv(4096).decode("utf-8", errors="replace")
        s.close()
        self.assertIn("400 Bad Request", response)

    def test_http_framing_duplicate_content_length_rejected(self):
        # Conflicting/duplicate Content-Length must return 400 Bad Request
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect(("127.0.0.1", self.port))
        req = (
            "POST /api/health HTTP/1.1\r\n"
            "Host: 127.0.0.1\r\n"
            "Content-Length: 10\r\n"
            "Content-Length: 20\r\n\r\n"
            "0123456789"
        )
        s.sendall(req.encode("utf-8"))
        response = s.recv(4096).decode("utf-8", errors="replace")
        s.close()
        self.assertIn("400 Bad Request", response)

    def test_http_framing_transfer_encoding_rejected(self):
        # Transfer-Encoding must be rejected with 400 Bad Request
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect(("127.0.0.1", self.port))
        req = (
            "POST /api/health HTTP/1.1\r\n"
            "Host: 127.0.0.1\r\n"
            "Transfer-Encoding: chunked\r\n\r\n"
            "0\r\n\r\n"
        )
        s.sendall(req.encode("utf-8"))
        response = s.recv(4096).decode("utf-8", errors="replace")
        s.close()
        self.assertIn("400 Bad Request", response)

    def test_http_malformed_json_rejected(self):
        # Malformed JSON with application/json Content-Type must return 400 Bad Request
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/terminal/exec",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            },
            data=b"{not valid json: 123"
        )
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req)
        self.assertEqual(ctx.exception.code, 400)

    def test_auth_rejection_before_body_reading(self):
        # Sending body without auth must immediately return 401 without hanging on slow body
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect(("127.0.0.1", self.port))
        # Declare 1000 bytes but only send headers
        req = (
            "POST /api/state/import HTTP/1.1\r\n"
            "Host: 127.0.0.1\r\n"
            "Content-Length: 1000\r\n\r\n"
        )
        s.sendall(req.encode("utf-8"))
        # Server must respond with 401 Unauthorized immediately without waiting for the 1000 bytes
        response = s.recv(4096).decode("utf-8", errors="replace")
        s.close()
        self.assertIn("401 Unauthorized", response)

if __name__ == '__main__':
    unittest.main()
