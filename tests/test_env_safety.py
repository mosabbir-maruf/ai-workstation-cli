import os
import subprocess
import unittest
from pathlib import Path

class EnvLoadingSafetyTest(unittest.TestCase):
    def setUp(self):
        self.marker = Path("/tmp/aiws_safe_env_marker_check")
        if self.marker.exists():
            self.marker.unlink()

        self.root = Path(__file__).resolve().parent.parent
        self.test_env = self.root / ".env.test_safety"
        # Write malicious payload that would execute if sourced by bash
        self.test_env.write_text(
            f'MALICIOUS_VAR=$(touch {self.marker})\n'
            'ANOTHER_VAR="safe_value"\n'
            'NUMBER_VAR=12345\n'
        )

    def tearDown(self):
        if self.marker.exists():
            self.marker.unlink()
        if self.test_env.exists():
            self.test_env.unlink()

    def test_env_loader_does_not_execute_code(self):
        # Run scripts/aiws with ENV_FILE pointing to our malicious test file
        env = os.environ.copy()
        env["ENV_FILE"] = str(self.test_env)

        res = subprocess.run(
            ["bash", "-c", f'ENV_FILE="{self.test_env}" && source scripts/aiws load_env 2>/dev/null || true'],
            cwd=str(self.root),
            capture_output=True,
            text=True,
            env=env
        )

        # The marker file MUST NOT exist! If it exists, code execution occurred!
        self.assertFalse(
            self.marker.exists(),
            "CRITICAL: .env file was executed as code! Marker file was created."
        )

if __name__ == '__main__':
    unittest.main()
