"""A denied automation grant must fail before opening native fixtures."""

import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).parent


class IntegrationPreflightTests(unittest.TestCase):
    def test_denied_system_events_does_not_open_fixtures(self):
        with tempfile.TemporaryDirectory(prefix="mgraph-preflight-test-") as temporary:
            folder = pathlib.Path(temporary)
            automation = folder / "osascript"
            automation.write_text("#!/bin/sh\necho 'assistive access denied' >&2\nexit 1\n")
            automation.chmod(0o755)
            opener = folder / "open"
            opener.write_text("#!/bin/sh\nprintf 'opened\\n' >> \"$MGRAPH_TEST_OPEN_LOG\"\n")
            opener.chmod(0o755)
            log = folder / "open.log"
            environment = os.environ.copy()
            environment["PATH"] = str(folder) + os.pathsep + environment["PATH"]
            environment["MGRAPH_TEST_OPEN_LOG"] = str(log)

            for script in ("fixture-matrix.py", "check-menu.py"):
                with self.subTest(script=script):
                    result = subprocess.run([sys.executable, str(ROOT / script)],
                                            capture_output=True, text=True, timeout=15,
                                            env=environment)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("System Events access required before opening", result.stderr)
                    self.assertFalse(log.exists(), f"{script} opened a fixture without automation access")


if __name__ == "__main__":
    unittest.main()
