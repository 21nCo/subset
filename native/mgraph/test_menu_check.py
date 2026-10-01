"""Contract checks for slow native alerts and fixture cleanup."""

import contextlib
import importlib.util
import io
import pathlib
import subprocess
import unittest
from unittest.mock import patch
import fixture_windows


SCRIPT = pathlib.Path(__file__).parent / "check-menu.py"
spec = importlib.util.spec_from_file_location("check_menu", SCRIPT)
check_menu = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_menu)


class MenuCheckTests(unittest.TestCase):
    def test_alert_can_arrive_after_old_half_second_wait(self):
        now = [0.0]

        def read_alert(_remaining):
            text = "no-alert" if now[0] < 4.1 else check_menu.MARKER
            return subprocess.CompletedProcess([], 0, text, "")

        def sleep(seconds):
            now[0] += seconds

        self.assertIn(check_menu.MARKER, check_menu.wait_for_capture_alert(
            read_alert, clock=lambda: now[0], sleep=sleep))

    def test_alert_timeout_fails_closed(self):
        now = [0.0]
        with self.assertRaisesRegex(TimeoutError, "did not appear"):
            check_menu.wait_for_capture_alert(
                lambda _remaining: subprocess.CompletedProcess([], 0, "no-alert", ""),
                clock=lambda: now[0], sleep=lambda seconds: now.__setitem__(0, now[0] + seconds))

    def test_alert_read_error_fails_closed(self):
        with self.assertRaisesRegex(RuntimeError, "Menu alert read failed: denied"):
            check_menu.wait_for_capture_alert(
                lambda _remaining: subprocess.CompletedProcess([], 1, "", "denied"))

    def test_stalled_alert_read_is_bounded_by_alert_deadline(self):
        observed = []
        def stalled(remaining):
            observed.append(remaining)
            raise subprocess.TimeoutExpired("osascript", remaining)
        with self.assertRaisesRegex(TimeoutError, "read exceeded"):
            check_menu.wait_for_capture_alert(stalled)
        self.assertLessEqual(observed[0], check_menu.CAPTURE_WAIT_SECONDS)

    def test_failed_fixture_close_makes_whole_menu_check_fail(self):
        success = subprocess.CompletedProcess([], 0, "", "")

        def apple_script(script, *, timeout=20):
            text = check_menu.MARKER if "get value of every static text" in script else ""
            return subprocess.CompletedProcess([], 0, text, "")

        with patch.object(check_menu.subprocess, "run", return_value=success), \
             patch.object(check_menu, "launched_bundle", return_value=contextlib.nullcontext("owned")), \
             patch.object(check_menu, "wait_for_owned_pid", return_value=42), \
             patch.object(check_menu, "owned_pids", return_value=set()), \
             patch.object(check_menu, "is_owned", return_value=True), \
             patch.object(check_menu, "focus_fixture_window", return_value=True), \
             patch.object(check_menu, "apple_script", side_effect=apple_script), \
             patch.object(check_menu, "close_fixture_window", return_value=False) as close, \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "fixture window was not closed"):
                check_menu.run_check(pathlib.Path("/tmp/MGraphCapture.app"))
            close.assert_called_once()

    def test_close_requires_window_readback(self):
        with patch.object(fixture_windows.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, "still-open\n", "")) as run:
            self.assertFalse(check_menu.close_fixture_window("MGraph Menu Fixture abc123ef"))
            self.assertIn('repeat 50 times', run.call_args.args[0][2])
            self.assertIn('repeat with remainingWindow in (get value of attribute "AXWindows")',
                          run.call_args.args[0][2])

    def test_menu_does_not_capture_an_unselected_fixture(self):
        success = subprocess.CompletedProcess([], 0, "", "")
        with patch.object(check_menu.subprocess, "run", return_value=success), \
             patch.object(check_menu, "launched_bundle", return_value=contextlib.nullcontext("owned")), \
             patch.object(check_menu, "wait_for_owned_pid", return_value=42), \
             patch.object(check_menu, "focus_fixture_window", return_value=False), \
             patch.object(check_menu, "close_fixture_window", return_value=True), \
             patch.object(check_menu, "apple_script") as click:
            with self.assertRaisesRegex(RuntimeError, "could not be focused"):
                check_menu.run_check(pathlib.Path("/tmp/MGraphCapture.app"))
            click.assert_not_called()

    def test_menu_operation_refuses_other_instance(self):
        with patch.object(check_menu, "is_owned", return_value=False), \
             patch.object(check_menu, "apple_script") as script:
            with self.assertRaisesRegex(RuntimeError, "Owned M Graph process exited"):
                check_menu.menu_operation(42, "owned", pathlib.Path("/tmp/MGraphCapture"),
                                          'click menu item "Capture Foreground"')
            script.assert_not_called()

    def test_failed_menu_fixture_open_keeps_primary_error(self):
        success = subprocess.CompletedProcess([], 0, "", "")
        def run(command, **_kwargs):
            if command[0] == "open":
                raise subprocess.CalledProcessError(1, command)
            return success
        with patch.object(check_menu.subprocess, "run", side_effect=run), \
             patch.object(check_menu, "launched_bundle", return_value=contextlib.nullcontext("owned")), \
             patch.object(check_menu, "wait_for_owned_pid", return_value=42), \
             patch.object(check_menu, "fixture_window_exists", return_value=False), \
             patch.object(check_menu, "close_fixture_window") as close:
            with self.assertRaisesRegex(RuntimeError, "returned non-zero exit status"):
                check_menu.run_check(pathlib.Path("/tmp/MGraphCapture.app"))
            close.assert_not_called()


if __name__ == "__main__":
    unittest.main()
