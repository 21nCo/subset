"""Process-lifetime verdicts for fast startup and uncertain identity reads."""

import importlib.util
import pathlib
import tempfile
import threading
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
    def test_deferred_ready_cannot_precede_launcher_exit(self):
        class Launcher:
            def poll(self):
                return 0

            def kill(self):
                pass

            def wait(self, timeout):
                return 0

        with tempfile.TemporaryDirectory() as folder:
            bundle = pathlib.Path(folder) / "MGraphCapture.app"
            binary = bundle / "Contents/MacOS/MGraphCapture"
            binary.parent.mkdir(parents=True)
            binary.touch()
            identities = {}

            def launch(_bundle, control, _marker, _lifetime, *, wait, defer_ready=False):
                pid = {"other": 101, "fast": 104, "early": 102, "late": 103}[control.name]
                identities[pid] = (str(binary), pid, 1)
                (control / "ready").write_text(str(pid))
                if defer_ready:
                    (control / "starting").write_text(str(pid))
                return Launcher() if wait else None

            with patch.object(lifetime.subprocess, "run"), \
                 patch.object(lifetime, "launch", side_effect=launch), \
                 patch.object(lifetime, "process_identity", side_effect=lambda pid: identities.get(pid)), \
                 patch.object(lifetime, "wait_exited", return_value=True):
                with self.assertRaisesRegex(RuntimeError, "published ready before launcher exit"):
                    lifetime.main(bundle)

    def test_fast_and_deferred_ready_orders_are_required(self):
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
            workers = []

            def launch(_bundle, control, _marker, _lifetime, *, wait, defer_ready=False):
                pid = {"other": 101, "fast": 104, "early": 102, "late": 103}[control.name]
                identities[pid] = (str(binary), pid, 1)
                if defer_ready:
                    (control / "starting").write_text(str(pid))
                    def publish_ready():
                        deadline = time.monotonic() + 10
                        while not (control / "release-ready").exists() and time.monotonic() < deadline:
                            time.sleep(0.005)
                        if (control / "release-ready").exists():
                            (control / "ready").write_text(str(pid))
                    worker = threading.Thread(target=publish_ready, daemon=True)
                    worker.start()
                    workers.append(worker)
                else:
                    (control / "ready").write_text(str(pid))
                return Launcher() if wait else None

            output = io.StringIO()
            with patch.object(lifetime.subprocess, "run"), \
                 patch.object(lifetime, "launch", side_effect=launch), \
                 patch.object(lifetime, "process_identity", side_effect=lambda pid: identities.get(pid)), \
                 patch.object(lifetime, "wait_exited", return_value=True), \
                 contextlib.redirect_stdout(output):
                lifetime.main(bundle)
            for worker in workers:
                worker.join(timeout=1)
                self.assertFalse(worker.is_alive())
            self.assertIn("early_launcher_exited_before_ready=true fast_ready=passed", output.getvalue())
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
            binary = pathlib.Path("/tmp/MGraphCapture")
            deadline = time.monotonic() + 0.06
            with patch.object(lifetime, "process_identity", return_value=None):
                with self.assertRaisesRegex(RuntimeError, "before deadline"):
                    lifetime.wait_ready(control, binary, deadline)

    def test_replacement_pid_proves_original_exit(self):
        with tempfile.TemporaryDirectory() as folder:
            control = pathlib.Path(folder)
            (control / "ready").write_text("42")
            binary = pathlib.Path("/tmp/MGraphCapture").resolve()
            original = (str(binary), 10, 1)
            replacement = (str(binary), 11, 1)
            with patch.object(lifetime, "process_identity", return_value=replacement):
                self.assertTrue(lifetime.wait_exited(control, binary, time.monotonic() + 1,
                                                     (42, original)))

    def test_transient_identity_failure_waits_for_confirmed_absence(self):
        with tempfile.TemporaryDirectory() as folder:
            control = pathlib.Path(folder)
            (control / "ready").write_text("42")
            binary = pathlib.Path("/tmp/MGraphCapture").resolve()
            original = (str(binary), 10, 1)
            with patch.object(lifetime, "process_identity", return_value=None), \
                 patch.object(lifetime, "pid_exists", side_effect=[True, False]) as exists:
                self.assertTrue(lifetime.wait_exited(control, binary, time.monotonic() + 1,
                                                     (42, original)))
                self.assertEqual(exists.call_count, 2)

    def test_unresolved_live_pid_cannot_pass_exit(self):
        with tempfile.TemporaryDirectory() as folder:
            control = pathlib.Path(folder)
            (control / "ready").write_text("42")
            binary = pathlib.Path("/tmp/MGraphCapture").resolve()
            with patch.object(lifetime, "process_identity", return_value=None), \
                 patch.object(lifetime, "pid_exists", return_value=None):
                self.assertFalse(lifetime.wait_exited(control, binary, time.monotonic() + 0.06))

    def test_failed_process_query_does_not_prove_exit(self):
        with patch.object(lifetime, "pid_exists", return_value=None) as exists, \
             patch.object(lifetime, "process_identity", return_value=None):
            with tempfile.TemporaryDirectory() as folder:
                control = pathlib.Path(folder)
                (control / "ready").write_text("42")
                binary = pathlib.Path("/tmp/MGraphCapture").resolve()
                self.assertFalse(lifetime.wait_exited(control, binary, time.monotonic() + 0.06,
                                                      (42, (str(binary), 10, 1))))
                self.assertGreater(exists.call_count, 0)

    def test_launch_phases_require_confirmed_exit_after_failed_identity_read(self):
        class Launcher:
            def kill(self):
                pass

            def wait(self, timeout):
                return 0

            def poll(self):
                return 0

        for phase in ("early", "late", "other"):
            for recovers in (True, False):
                with self.subTest(phase=phase, recovers=recovers), \
                     tempfile.TemporaryDirectory() as folder:
                    root = pathlib.Path(folder) / "controls"
                    root.mkdir()
                    bundle = pathlib.Path(folder) / "MGraphCapture.app"
                    binary = bundle / "Contents/MacOS/MGraphCapture"
                    binary.parent.mkdir(parents=True)
                    binary.touch()
                    identities = {}
                    workers = []
                    ready_reads = {}
                    probes = 0

                    def launch(_bundle, control, _marker, _lifetime, *, wait, defer_ready=False):
                        pid = {"other": 101, "fast": 104, "early": 102, "late": 103}[control.name]
                        identities[pid] = (str(binary), pid, 1)
                        if defer_ready:
                            (control / "starting").write_text(str(pid))
                            def publish_ready():
                                deadline = time.monotonic() + 10
                                while not (control / "release-ready").exists() and time.monotonic() < deadline:
                                    time.sleep(0.005)
                                if (control / "release-ready").exists():
                                    (control / "ready").write_text(str(pid))
                            worker = threading.Thread(target=publish_ready, daemon=True)
                            worker.start()
                            workers.append(worker)
                        else:
                            (control / "ready").write_text(str(pid))
                        return Launcher() if wait else None

                    def identity(pid):
                        name = {101: "other", 104: "fast", 102: "early", 103: "late"}[pid]
                        reads = ready_reads.get(pid, 0)
                        ready_reads[pid] = reads + 1
                        if reads < (2 if name == "early" else 1):
                            return identities[pid]
                        if name in ("fast", "early", "late") or (root / name / "shutdown").exists():
                            return None
                        return identities[pid]

                    def exists(pid):
                        nonlocal probes
                        name = {101: "other", 104: "fast", 102: "early", 103: "late"}[pid]
                        if name != phase:
                            return False
                        probes += 1
                        return True if not recovers or probes == 1 else False

                    actual_wait_exited = lifetime.wait_exited

                    def bounded_wait(control, path, _deadline, expected=None):
                        return actual_wait_exited(control, path, time.monotonic() + 0.5, expected)

                    with patch.object(lifetime.tempfile, "mkdtemp", return_value=str(root)), \
                         patch.object(lifetime.subprocess, "run"), \
                         patch.object(lifetime, "launch", side_effect=launch), \
                         patch.object(lifetime, "process_identity", side_effect=identity), \
                         patch.object(lifetime, "pid_exists", side_effect=exists), \
                         patch.object(lifetime, "wait_exited", side_effect=bounded_wait), \
                         contextlib.redirect_stdout(io.StringIO()):
                        if recovers:
                            lifetime.main(bundle)
                            self.assertFalse(root.exists())
                        else:
                            with self.assertRaisesRegex(RuntimeError, "exit unverified"):
                                lifetime.main(bundle)
                            self.assertTrue((root / phase / "shutdown").is_file())
                    for worker in workers:
                        worker.join(timeout=1)
                        self.assertFalse(worker.is_alive())
                    self.assertGreaterEqual(probes, 2)

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
