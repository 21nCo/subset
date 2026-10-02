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
    def build_controlled_binary(self, folder):
        source = folder / "controlled.c"
        source.write_text(r'''#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
int main(int argc, char **argv) {
    char path[4096];
    if (argc > 1) {
        snprintf(path, sizeof(path), "%s/ready", argv[1]);
        FILE *ready = fopen(path, "w");
        if (!ready) return 3;
        fprintf(ready, "%d", getpid());
        fclose(ready);
    }
    for (;;) {
        if (argc > 1) {
            struct stat metadata;
            snprintf(path, sizeof(path), "%s/shutdown", argv[1]);
            if (stat(path, &metadata) == 0) return 0;
        }
        usleep(50000);
    }
}''')
        binary = folder / "MGraphCapture"
        subprocess.run(["clang", str(source), "-o", str(binary)], check=True, capture_output=True)
        return binary

    def start_controlled_shell(self, binary, marker, control):
        return subprocess.Popen([str(binary), str(control), "--invocation-id", marker])

    def test_only_tagged_bundle_process_is_owned(self):
        output = """100 /tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture
101 /tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture capture --invocation-id 123
102 /tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture capture --invocation-id 456
"""
        with patch.object(bundle_process.subprocess, "run") as run, \
             patch.object(bundle_process, "process_identity", side_effect=lambda pid: (
                 "/tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture", 1, 0) if pid == 101 else None):
            run.return_value.stdout = output
            self.assertEqual(bundle_process.owned_pids(
                pathlib.Path("/tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture"), "123"), {101})
            self.assertLessEqual(run.call_args.kwargs["timeout"], 1)

    def test_stalled_process_lookup_fails_within_cleanup_deadline(self):
        marker = str(uuid.uuid4())
        with tempfile.TemporaryDirectory() as folder, \
             patch.dict(bundle_process._controls, {marker: pathlib.Path(folder)}), \
             patch.object(bundle_process.subprocess, "run", side_effect=subprocess.TimeoutExpired("ps", 1)), \
             patch.object(bundle_process.os, "kill") as kill:
            with self.assertRaisesRegex(RuntimeError, "Could not establish"):
                bundle_process.terminate_owned(pathlib.Path("/tmp/MGraphCapture"), marker,
                                               deadline=time.monotonic() + 0.05)
            self.assertEqual((pathlib.Path(folder) / "shutdown").read_text(), marker.upper())
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
        marker = str(uuid.uuid4())
        with patch.object(bundle_process, "wait_for_owned_pid", return_value=4242), \
             patch.object(bundle_process, "is_owned", return_value=True), \
             patch.object(bundle_process.subprocess, "run", return_value=subprocess.CompletedProcess(
                 [], 0, "approved\n", "")) as run:
            bundle_process.approve_cli_capture(marker, pathlib.Path(
                "/tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture"))
        self.assertIn("unix id is 4242", run.call_args.args[0][2])
        self.assertIn(marker.upper(), run.call_args.args[0][2])

    def test_revoked_capture_exits_before_consent_without_masking_json(self):
        marker = str(uuid.uuid4())
        with patch.object(bundle_process, "wait_for_owned_pid", return_value=4242), \
             patch.object(bundle_process.subprocess, "run", return_value=subprocess.CompletedProcess(
                 [], 0, "no-consent-alert\n", "")), \
             patch.object(bundle_process, "is_owned", return_value=False):
            bundle_process.approve_cli_capture(marker, pathlib.Path(
                "/tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture"))

    def test_consent_lookup_error_is_only_ignored_after_process_exits(self):
        binary = pathlib.Path("/tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture")
        marker = str(uuid.uuid4())
        failed = subprocess.CompletedProcess([], 1, "", "process disappeared")
        with patch.object(bundle_process, "wait_for_owned_pid", return_value=4242), \
             patch.object(bundle_process.subprocess, "run", return_value=failed), \
             patch.object(bundle_process, "is_owned", return_value=False):
            bundle_process.approve_cli_capture(marker, binary)
        with patch.object(bundle_process, "wait_for_owned_pid", return_value=4242), \
             patch.object(bundle_process.subprocess, "run", return_value=failed), \
             patch.object(bundle_process, "is_owned", return_value=True):
            with self.assertRaisesRegex(RuntimeError, "CLI capture consent failed"):
                bundle_process.approve_cli_capture(marker, binary)

    def test_approved_consent_from_exited_invocation_is_rejected(self):
        marker = str(uuid.uuid4())
        binary = pathlib.Path("/tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture")
        with patch.object(bundle_process, "wait_for_owned_pid", return_value=4242), \
             patch.object(bundle_process.subprocess, "run", return_value=subprocess.CompletedProcess(
                 [], 0, "approved\n", "")), \
             patch.object(bundle_process, "is_owned", return_value=False):
            with self.assertRaisesRegex(RuntimeError, "exited during CLI consent"):
                bundle_process.approve_cli_capture(marker, binary)

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
                    self.assertEqual(terminate.call_count, 1)
                    self.assertEqual(terminate.call_args.args, (
                        pathlib.Path("/tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture").resolve(), marker))
                    self.assertIn("deadline", terminate.call_args.kwargs)

    def test_real_cleanup_preserves_preexisting_instance(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = self.build_controlled_binary(pathlib.Path(temporary))
            marker = str(uuid.uuid4())
            control = pathlib.Path(temporary) / "control"
            control.mkdir()
            preexisting = subprocess.Popen([str(binary)])
            owned = self.start_controlled_shell(binary, marker, control)
            try:
                bundle_process._controls[marker] = control
                for _ in range(50):
                    if bundle_process._ready_pid(binary, marker) == owned.pid:
                        break
                    time.sleep(0.05)
                self.assertEqual(bundle_process._ready_pid(binary, marker), owned.pid)
                with patch.object(bundle_process.subprocess, "run",
                                  side_effect=subprocess.TimeoutExpired("ps", 1)):
                    bundle_process.terminate_owned(binary, marker)
                owned.wait(timeout=2)
                self.assertIsNone(preexisting.poll())
            finally:
                bundle_process._controls.pop(marker, None)
                bundle_process._known.pop(marker, None)
                for process in (owned, preexisting):
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=2)

    def test_stalled_ps_after_discovery_still_terminates_owned_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = self.build_controlled_binary(pathlib.Path(temporary))
            marker = str(uuid.uuid4())
            control = pathlib.Path(temporary) / "control"
            control.mkdir()
            owned = self.start_controlled_shell(binary, marker, control)
            try:
                bundle_process._controls[marker] = control
                for _ in range(50):
                    if bundle_process._ready_pid(binary, marker) == owned.pid:
                        break
                    time.sleep(0.05)
                self.assertEqual(bundle_process._ready_pid(binary, marker), owned.pid)
                with patch.object(bundle_process.subprocess, "run",
                                  side_effect=subprocess.TimeoutExpired("ps", 1)):
                    bundle_process.terminate_owned(binary, marker)
                owned.wait(timeout=2)
                self.assertIsNotNone(owned.poll())
            finally:
                bundle_process._controls.pop(marker, None)
                bundle_process._known.pop(marker, None)
                if owned.poll() is None:
                    owned.kill()
                owned.wait(timeout=2)

    def test_stalled_ps_before_discovery_uses_private_ready_channel(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = pathlib.Path(temporary)
            binary = self.build_controlled_binary(folder)
            control = folder / "control"
            control.mkdir()
            marker = str(uuid.uuid4())
            owned = self.start_controlled_shell(binary, marker, control)
            preexisting = subprocess.Popen([str(binary)])
            try:
                bundle_process._controls[marker] = control
                for _ in range(50):
                    if (control / "ready").exists():
                        break
                    time.sleep(0.05)
                self.assertTrue((control / "ready").exists())
                self.assertNotIn(marker, bundle_process._known)
                with patch.object(bundle_process.subprocess, "run",
                                  side_effect=subprocess.TimeoutExpired("ps", 1)) as ps:
                    bundle_process.terminate_owned(binary, marker)
                owned.wait(timeout=2)
                self.assertEqual(owned.returncode, 0)
                self.assertIsNone(preexisting.poll())
                ps.assert_not_called()
            finally:
                bundle_process._controls.pop(marker, None)
                bundle_process._known.pop(marker, None)
                for process in (owned, preexisting):
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=2)

    def test_reused_pid_is_never_signaled_from_cached_invocation(self):
        marker = str(uuid.uuid4())
        binary = pathlib.Path("/tmp/MGraphCapture.app/Contents/MacOS/MGraphCapture").resolve()
        bundle_process._known[marker] = {4242: (str(binary), 100, 0)}
        try:
            with tempfile.TemporaryDirectory() as folder, \
                 patch.dict(bundle_process._controls, {marker: pathlib.Path(folder)}), \
                 patch.object(bundle_process, "process_identity", return_value=(str(binary), 101, 0)), \
                 patch.object(bundle_process, "owned_pids", return_value=set()), \
                 patch.object(bundle_process.os, "kill") as kill:
                bundle_process.terminate_owned(binary, marker, deadline=time.monotonic() + 0.05)
                self.assertEqual((pathlib.Path(folder) / "shutdown").read_text(), marker.upper())
            kill.assert_not_called()
        finally:
            bundle_process._known.pop(marker, None)


if __name__ == "__main__":
    unittest.main()
