"""Distinguish permission and fixture-cleanup transitions from false passes."""

import importlib.util
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
        native.validate_capture_state({"state": "readFailed", "text": None}, "available")

    def test_dropped_matrix_close_does_not_report_closed(self):
        # The mock is the observed state after Command-W, independent of the
        # AppleScript source text; a dropped close must fail the verdict.
        with patch.object(fixture_windows.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, "still-open\n", "")) as run:
            self.assertFalse(fixture_windows.close_fixture_window("TextEdit", "MGraph TextEdit Fixture abcdef12"))
            self.assertIn('repeat 20 times', run.call_args.args[0][2])

    def test_background_fixture_never_launches_capture_until_selected(self):
        matrix = load_script("fixture-matrix.py", "fixture_matrix_background")
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(matrix, "focus_fixture_window", return_value=False) as focus, \
             patch.object(matrix, "launched_bundle") as launch, \
             patch.object(matrix.time, "sleep"):
            result = matrix.capture_fixture(pathlib.Path("bundle"), pathlib.Path(temporary),
                                            "Google Chrome", "com.google.Chrome",
                                            "MGraph Capture Fixture abcdef12")
        self.assertIsNone(result)
        self.assertEqual(focus.call_count, 5)
        launch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
