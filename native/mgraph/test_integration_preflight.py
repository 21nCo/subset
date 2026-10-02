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

    def test_locked_desktop_rejects_stale_finder_menu_readiness(self):
        with tempfile.TemporaryDirectory(prefix="mgraph-locked-test-") as temporary:
            folder = pathlib.Path(temporary)
            automation = folder / "osascript"
            automation.write_text("#!/bin/sh\ncase \"$*\" in\n"
                                  "  *frontmost*) echo 'Invalid index. (-1719)' >&2; exit 1 ;;\n"
                                  "  *) echo 8 ;;\nesac\n")
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
                    self.assertIn("Active desktop required", result.stderr)
                    self.assertFalse(log.exists(), f"{script} opened a fixture on a locked desktop")

    def test_matrix_stops_after_desktop_disappears_during_first_fixture(self):
        with tempfile.TemporaryDirectory(prefix="mgraph-session-loss-test-") as temporary:
            folder = pathlib.Path(temporary)
            automation = folder / "osascript"
            automation.write_text("#!/bin/sh\n"
                                  "count=$(cat \"$MGRAPH_TEST_QUERY_COUNT\" 2>/dev/null || echo 0)\n"
                                  "count=$((count + 1))\n"
                                  "echo \"$count\" > \"$MGRAPH_TEST_QUERY_COUNT\"\n"
                                  "if [ \"$count\" -gt 2 ]; then echo 'Invalid index. (-1719)' >&2; exit 1; fi\n"
                                  "echo Finder\n")
            automation.chmod(0o755)
            opener = folder / "open"
            opener.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$MGRAPH_TEST_OPEN_LOG\"\n")
            opener.chmod(0o755)
            log = folder / "open.log"
            environment = os.environ.copy()
            environment["PATH"] = str(folder) + os.pathsep + environment["PATH"]
            environment["MGRAPH_TEST_OPEN_LOG"] = str(log)
            environment["MGRAPH_TEST_QUERY_COUNT"] = str(folder / "queries")
            result = subprocess.run([sys.executable, str(ROOT / "fixture-matrix.py")],
                                    capture_output=True, text=True, timeout=15, env=environment)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(len(log.read_text().splitlines()), 1)
            self.assertIn("MGraph TextEdit Fixture", result.stderr)
            self.assertIn("cleanup unverified", result.stderr)


if __name__ == "__main__":
    unittest.main()
