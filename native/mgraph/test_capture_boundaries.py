"""Distinguish permission and fixture-cleanup transitions from false passes."""

import importlib.util
import pathlib
import subprocess
import unittest
from unittest.mock import patch


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
        matrix = load_script("fixture-matrix.py", "fixture_matrix")

        # The mock is the observed state after Command-W, independent of the
        # AppleScript source text; a dropped close must fail the verdict.
        with patch.object(matrix.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, "still-open\n", "")) as run:
            self.assertFalse(matrix.close_fixture_window("TextEdit", "MGraph TextEdit Fixture test"))
            self.assertIn('repeat 20 times', run.call_args.args[0][2])


if __name__ == "__main__":
    unittest.main()
