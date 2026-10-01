"""Deterministic timeout/interruption checks for LaunchServices ownership."""

import pathlib
import os
import signal
import subprocess
import tempfile
import time
import uuid
import unittest
from unittest.mock import patch

import bundle_process


class FakeLauncher:
    def __init__(self, error):
        self.error = error
        self.returncode = None
        self.terminated = False

    def communicate(self, timeout):
        if not self.terminated:
            if self.error == "sigterm":
                os.kill(os.getpid(), signal.SIGTERM)
            raise self.error
        self.returncode = -15
        return ("", "")

    def poll(self):
        return self.returncode

    def terminate(self):
        self.terminated = True


class BundleProcessTests(unittest.TestCase):
    def test_only_tagged_bundle_process_is_owned(self):
        output = """100 /tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture
101 /tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture capture --invocation-id 123
102 /tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture capture --invocation-id 456
"""
        with patch.object(bundle_process.subprocess, "run") as run:
            run.return_value.stdout = output
            self.assertEqual(bundle_process.owned_pids(
                pathlib.Path("/tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture"), "123"), {101})
            self.assertEqual(run.call_args.kwargs["timeout"], 1)

    def test_stalled_process_lookup_fails_within_cleanup_deadline(self):
        with patch.object(bundle_process.subprocess, "run", side_effect=subprocess.TimeoutExpired("ps", 1)) as run, \
             patch.object(bundle_process.os, "kill") as kill:
            with self.assertRaises(subprocess.TimeoutExpired):
                bundle_process.terminate_owned(pathlib.Path("/tmp/MGraphCapture"), "owned")
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.kwargs["timeout"], 1)
            kill.assert_not_called()

    def test_option_shaped_bundle_and_output_are_absolute_operands(self):
        launcher = FakeLauncher(None)
        launcher.communicate = lambda timeout: ("", "")
        launcher.returncode = 0
        with patch.object(bundle_process.subprocess, "Popen", return_value=launcher) as popen, \
             patch.object(bundle_process, "terminate_owned"):
            with bundle_process.launched_bundle(pathlib.Path("-bundle.app"), output=pathlib.Path("-output.json")):
                pass
        command = popen.call_args.args[0]
        self.assertTrue(pathlib.Path(command[command.index("-o") + 1]).is_absolute())
        self.assertTrue(pathlib.Path(command[command.index("--args") - 1]).is_absolute())

    def test_consent_click_targets_only_the_owned_process(self):
        with patch.object(bundle_process, "wait_for_owned_pid", return_value=4242), \
             patch.object(bundle_process.subprocess, "run", return_value=subprocess.CompletedProcess(
                 [], 0, "approved\n", "")) as run:
            bundle_process.approve_cli_capture("invocation", pathlib.Path(
                "/tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture"))
        self.assertIn("unix id is 4242", run.call_args.args[0][2])

    def test_revoked_capture_exits_before_consent_without_masking_json(self):
        with patch.object(bundle_process, "wait_for_owned_pid", return_value=4242), \
             patch.object(bundle_process.subprocess, "run", return_value=subprocess.CompletedProcess(
                 [], 0, "no-consent-alert\n", "")), \
             patch.object(bundle_process, "owned_pids", return_value=set()):
            bundle_process.approve_cli_capture("invocation", pathlib.Path(
                "/tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture"))

    def test_timeout_and_interruption_terminate_only_invocation(self):
        for error in (subprocess.TimeoutExpired("open", 0.01), KeyboardInterrupt(), "sigterm"):
            with self.subTest(error=str(error)):
                launcher = FakeLauncher(error)
                with patch.object(bundle_process.subprocess, "Popen", return_value=launcher) as popen, \
                     patch.object(bundle_process, "terminate_owned") as terminate:
                    expected = bundle_process.LaunchInterrupted if error == "sigterm" else type(error)
                    with self.assertRaises(expected):
                        with bundle_process.launched_bundle(pathlib.Path("/tmp/MGraphCapture.app"),
                                                            ("capture",), timeout=0.01):
                            pass
                    self.assertTrue(launcher.terminated)
                    marker = popen.call_args.args[0][-1]
                    terminate.assert_called_once_with(
                        pathlib.Path("/tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture").resolve(), marker)

    def test_real_cleanup_preserves_preexisting_instance(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = pathlib.Path(temporary) / "MGraphCapture"
            binary.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(30)\n")
            binary.chmod(0o755)
            marker = str(uuid.uuid4())
            preexisting = subprocess.Popen([str(binary)])
            owned = subprocess.Popen([str(binary), "--invocation-id", marker])
            try:
                for _ in range(20):
                    if owned.pid in bundle_process.owned_pids(binary, marker):
                        break
                    time.sleep(0.05)
                self.assertEqual(bundle_process.owned_pids(binary, marker), {owned.pid})
                bundle_process.terminate_owned(binary, marker)
                owned.wait(timeout=2)
                self.assertIsNone(preexisting.poll())
            finally:
                for process in (owned, preexisting):
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=2)


if __name__ == "__main__":
    unittest.main()
