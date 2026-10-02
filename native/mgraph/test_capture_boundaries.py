"""Distinguish permission and fixture-cleanup transitions from false passes."""

import importlib.util
import contextlib
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import fixture_windows


ROOT = pathlib.Path(__file__).parent


def load_script(name, module_name):
    spec = importlib.util.spec_from_file_location(module_name, ROOT / name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CaptureBoundaryTests(unittest.TestCase):
    def test_option_shaped_check_bundle_becomes_absolute_operand(self):
        native = load_script("check-native.py", "check_native_option")
        bundle = native.canonical_bundle(pathlib.Path("-option/MGraphCapture.app"))
        self.assertTrue(bundle.is_absolute())
        self.assertEqual(bundle.name, "MGraphCapture.app")
        with self.assertRaisesRegex(ValueError, "Expected a MGraphCapture.app"):
            native.canonical_bundle(pathlib.Path("-option.app"))

    def test_grant_revoked_between_status_and_capture_fails(self):
        native = load_script("check-native.py", "check_native")
        with self.assertRaisesRegex(AssertionError, "Grant was revoked"):
            native.validate_capture_state({"state": "permissionRequired", "text": None}, "available")
        with self.assertRaisesRegex(AssertionError, "Approved capture unavailable"):
            native.validate_capture_state({"state": "readFailed", "text": None}, "available")
        with self.assertRaisesRegex(AssertionError, "Denied capture exposed text"):
            native.validate_capture_state({"state": "permissionRequired", "text": "exposed"},
                                          "permissionRequired")
        with self.assertRaisesRegex(AssertionError, "Failed capture exposed text"):
            native.validate_capture_state({"state": "readFailed", "text": "exposed"}, "available")
        native.validate_capture_state({"state": "available", "text": "fixture"}, "available")

    def test_dropped_matrix_close_does_not_report_closed(self):
        # The mock is the observed state after Command-W, independent of the
        # AppleScript source text; a dropped close must fail the verdict.
        with patch.object(fixture_windows.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, "still-open\n", "")) as run:
            self.assertFalse(fixture_windows.close_fixture_window("TextEdit", "MGraph TextEdit Fixture abcdef12"))
            self.assertIn('repeat 50 times', run.call_args.args[0][2])

    def test_browser_selection_does_not_change_nonmatching_tabs(self):
        with patch.object(fixture_windows.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, "focused\n", "")) as run:
            self.assertTrue(fixture_windows.focus_fixture_window(
                "Google Chrome", "MGraph Capture Fixture abcdef12"))
        script = run.call_args.args[0][2]
        self.assertIn('if name of child contains fixtureTitle', script)
        self.assertNotIn('keystroke "9"', script)

    def test_browser_close_readback_checks_hidden_fixture_tab(self):
        # A browser can switch to another tab after Command-W while the fixture
        # tab remains. Window-title-only readback would incorrectly pass.
        outcomes = ["closed\n", "exists\n", "closed\n", "exists\n"]
        def hidden_tab(_command, **_kwargs):
            return subprocess.CompletedProcess([], 0, outcomes.pop(0), "")
        with patch.object(fixture_windows.subprocess, "run", side_effect=hidden_tab) as run:
            self.assertFalse(fixture_windows.close_fixture_window(
                "Google Chrome", "MGraph Capture Fixture abcdef12"))
        self.assertEqual(run.call_count, 4)
        script = run.call_args_list[0].args[0][2]
        self.assertIn('get entire contents of remainingWindow', script)
        self.assertIn('if name of child contains fixtureTitle then set fixtureStillOpen to true', script)
        self.assertIn('on error\n                    set fixtureStillOpen to true', script)

    def test_chrome_hidden_tab_can_be_found_when_ax_omits_it(self):
        outcomes = ["absent\n", "exists\n"]
        def hidden_tab(_command, **_kwargs):
            return subprocess.CompletedProcess([], 0, outcomes.pop(0), "")
        with patch.object(fixture_windows.subprocess, "run", side_effect=hidden_tab):
            self.assertTrue(fixture_windows.fixture_window_exists(
                "Google Chrome", "MGraph Capture Fixture abcdef12"))

    def test_partial_open_cleanup_attempt_survives_presence_probe_timeout(self):
        matrix = load_script("fixture-matrix.py", "fixture_matrix_probe_timeout")
        title = "MGraph Capture Fixture abcdef12"
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(matrix.subprocess, "run", side_effect=subprocess.TimeoutExpired("open", 20)), \
             patch.object(fixture_windows, "fixture_window_exists",
                          side_effect=subprocess.TimeoutExpired("osascript", 1)) as probe, \
             patch.object(fixture_windows, "close_fixture_window", return_value=True) as close:
            folder = pathlib.Path(temporary)
            failures = matrix.run_app(pathlib.Path("bundle"), folder, "Firefox", "org.mozilla.firefox",
                                      folder / "fixture.txt", folder / "fixture.html",
                                      "MGraph TextEdit Fixture abcdef12", title)
        self.assertEqual(len(failures), 1)
        self.assertIn("transition or capture failed", failures[0])
        probe.assert_not_called()
        self.assertEqual(close.call_args.args, ("Firefox", title))
        self.assertIn("deadline", close.call_args.kwargs)

    def test_presence_probe_never_materializes_browser_descendants(self):
        with patch.object(fixture_windows.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, "absent\n", "")) as run:
            self.assertIsNone(fixture_windows.fixture_window_exists(
                "Firefox", "MGraph Capture Fixture abcdef12"))
        self.assertNotIn("get entire contents", run.call_args.args[0][2])

    def test_chrome_hidden_fixture_can_be_selected_without_touching_other_tabs(self):
        title = "MGraph Capture Fixture abcdef12"
        with patch.object(fixture_windows, "run_window_action", side_effect=[False, True]) as ax, \
             patch.object(fixture_windows, "chrome_tab_action", return_value="selected") as chrome:
            self.assertTrue(fixture_windows.focus_fixture_window("Google Chrome", title))
        self.assertEqual(ax.call_count, 2)
        chrome.assert_called_once_with(title, "select")

    def test_background_fixture_never_launches_capture_until_selected(self):
        matrix = load_script("fixture-matrix.py", "fixture_matrix_background")
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(matrix, "focus_fixture_window", return_value=False) as focus, \
             patch.object(matrix, "launched_bundle") as launch, \
             patch.object(matrix.time, "sleep"):
            with self.assertRaisesRegex(RuntimeError, "could not be focused"):
                matrix.capture_fixture(pathlib.Path("bundle"), pathlib.Path(temporary),
                                       "Google Chrome", "com.google.Chrome",
                                       "MGraph Capture Fixture abcdef12")
        self.assertEqual(focus.call_count, 5)
        launch.assert_not_called()

    def test_failed_open_does_not_claim_fixture_cleanup_failure(self):
        matrix = load_script("fixture-matrix.py", "fixture_matrix_failed_open")
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(matrix.subprocess, "run", return_value=subprocess.CompletedProcess(
                 [], 1, "", "app unavailable")), \
             patch.object(matrix, "cleanup_fixture_after_open", return_value=True) as close:
            folder = pathlib.Path(temporary)
            failures = matrix.run_app(pathlib.Path("bundle"), folder, "TextEdit", "com.apple.TextEdit",
                                      folder / "fixture.txt", folder / "fixture.html",
                                      "MGraph TextEdit Fixture abcdef12", "MGraph Capture Fixture abcdef12")
        self.assertEqual(len(failures), 1)
        self.assertIn("app unavailable", failures[0])
        close.assert_called_once_with("TextEdit", "MGraph TextEdit Fixture abcdef12", "failed")

    def test_partial_open_and_stalled_cleanup_report_both_failures(self):
        matrix = load_script("fixture-matrix.py", "fixture_matrix_partial_open")
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(matrix.subprocess, "run", side_effect=subprocess.TimeoutExpired("open", 20)), \
             patch.object(matrix, "cleanup_fixture_after_open", side_effect=subprocess.TimeoutExpired("osascript", 5)):
            folder = pathlib.Path(temporary)
            failures = matrix.run_app(pathlib.Path("bundle"), folder, "TextEdit", "com.apple.TextEdit",
                                      folder / "fixture.txt", folder / "fixture.html",
                                      "MGraph TextEdit Fixture abcdef12", "MGraph Capture Fixture abcdef12")
        self.assertEqual(len(failures), 2)
        self.assertIn("transition or capture failed", failures[0])
        self.assertIn("cleanup failed", failures[1])

    def test_malformed_capture_output_is_a_per_app_failure(self):
        matrix = load_script("fixture-matrix.py", "fixture_matrix_malformed")
        def malformed(_bundle, _args, *, output, **_kwargs):
            output.write_text("{")
            return contextlib.nullcontext("owned")
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(matrix.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")), \
             patch.object(matrix, "focus_fixture_window", return_value=True), \
             patch.object(matrix, "cleanup_fixture_after_open", return_value=True), \
             patch.object(matrix, "launched_bundle", side_effect=malformed), \
             patch.object(matrix.time, "sleep"):
            folder = pathlib.Path(temporary)
            failures = matrix.run_app(pathlib.Path("bundle"), folder, "TextEdit", "com.apple.TextEdit",
                                      folder / "fixture.txt", folder / "fixture.html",
                                      "MGraph TextEdit Fixture abcdef12", "MGraph Capture Fixture abcdef12")
        self.assertEqual(len(failures), 1)
        self.assertIn("bundle output was malformed", failures[0])


if __name__ == "__main__":
    unittest.main()
