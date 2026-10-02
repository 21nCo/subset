"""Process-lifetime verdicts for fast startup and uncertain identity reads."""

import importlib.util
import pathlib
import tempfile
import time
import unittest
from unittest.mock import patch
import contextlib
import io


ROOT = pathlib.Path(__file__).parent
spec = importlib.util.spec_from_file_location("check_lifetime", ROOT / "check-lifetime.py")
lifetime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifetime)


class LifetimeTests(unittest.TestCase):
    def test_fast_ready_before_no_wait_launcher_exit_is_valid(self):
        class Launcher:
            def __init__(self):
                self.stopped = False

            def kill(self):
                self.stopped = True

            def wait(self, timeout):
                self.stopped = True

            def poll(self):
                return 0 if self.stopped else None

        with tempfile.TemporaryDirectory() as folder:
            bundle = pathlib.Path(folder) / "MGraphCapture.app"
            binary = bundle / "Contents/MacOS/MGraphCapture"
            binary.parent.mkdir(parents=True)
            binary.touch()
            identities = {}

            def launch(_bundle, control, _marker, _lifetime, *, wait):
                pid = {"other": 101, "early": 102, "late": 103}[control.name]
                (control / "ready").write_text(str(pid))
                identities[pid] = (str(binary), pid, 1)
                return Launcher() if wait else None

            output = io.StringIO()
            with patch.object(lifetime.subprocess, "run"), \
                 patch.object(lifetime, "launch", side_effect=launch), \
                 patch.object(lifetime, "process_identity", side_effect=lambda pid: identities.get(pid)), \
                 patch.object(lifetime, "wait_exited", return_value=True), \
                 contextlib.redirect_stdout(output):
                lifetime.main(bundle)
            self.assertIn("early_launcher_exited_before_ready=false", output.getvalue())
            self.assertIn("abandoned_invocations_expired=passed", output.getvalue())

    def test_fast_ready_and_transient_identity_are_both_accepted(self):
        with tempfile.TemporaryDirectory() as folder:
            control = pathlib.Path(folder)
            (control / "ready").write_text("42")
            binary = pathlib.Path("/tmp/MGraphCapture").resolve()
            identity = (str(binary), 10, 1)
            with patch.object(lifetime, "process_identity", side_effect=[None, identity]):
                self.assertEqual(lifetime.wait_ready(control, binary, time.monotonic() + 1),
                                 (42, identity))

    def test_persistent_identity_failure_reaches_deadline(self):
        with tempfile.TemporaryDirectory() as folder:
            control = pathlib.Path(folder)
            (control / "ready").write_text("42")
            with patch.object(lifetime, "process_identity", return_value=None):
                with self.assertRaisesRegex(RuntimeError, "before deadline"):
                    lifetime.wait_ready(control, pathlib.Path("/tmp/MGraphCapture"),
                                        time.monotonic() + 0.06)

    def test_replacement_pid_proves_original_exit(self):
        with tempfile.TemporaryDirectory() as folder:
            control = pathlib.Path(folder)
            (control / "ready").write_text("42")
            binary = pathlib.Path("/tmp/MGraphCapture").resolve()
            original = (str(binary), 10, 1)
            replacement = (str(binary), 11, 1)
            with patch.object(lifetime, "process_identity", return_value=replacement), \
                 patch.object(lifetime, "alive", return_value=True):
                self.assertTrue(lifetime.wait_exited(control, binary, time.monotonic() + 1,
                                                     (42, original)))

    def test_unresolved_live_pid_cannot_pass_exit(self):
        with tempfile.TemporaryDirectory() as folder:
            control = pathlib.Path(folder)
            (control / "ready").write_text("42")
            binary = pathlib.Path("/tmp/MGraphCapture").resolve()
            with patch.object(lifetime, "process_identity", return_value=None), \
                 patch.object(lifetime, "alive", return_value=True):
                self.assertFalse(lifetime.wait_exited(control, binary, time.monotonic() + 0.06))

    def test_missing_ready_after_launch_retains_shutdown_marker(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder) / "controls"
            root.mkdir()
            bundle = pathlib.Path(folder) / "MGraphCapture.app"
            binary = bundle / "Contents/MacOS/MGraphCapture"
            binary.parent.mkdir(parents=True)
            binary.touch()
            with patch.object(lifetime.tempfile, "mkdtemp", return_value=str(root)), \
                 patch.object(lifetime.subprocess, "run"), \
                 patch.object(lifetime, "launch", side_effect=RuntimeError("launcher interrupted")), \
                 patch.object(lifetime, "wait_exited", return_value=False):
                with self.assertRaisesRegex(RuntimeError, "exit unverified"):
                    lifetime.main(bundle)
            self.assertTrue((root / "other" / "shutdown").is_file())


if __name__ == "__main__":
    unittest.main()
