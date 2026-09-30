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
    def test_grant_revoked_between_status_and_capture_fails(self):
        native = load_script("check-native.py", "check_native")
        with self.assertRaisesRegex(AssertionError, "Grant was revoked"):
            native.validate_capture_state({"state": "permissionRequired", "text": None}, "available")
        native.validate_capture_state({"state": "readFailed", "text": None}, "available")

    def test_dropped_matrix_close_does_not_report_closed(self):
        matrix = load_script("fixture-matrix.py", "fixture_matrix")

        def dropped_close(command, **_kwargs):
            script = command[2]
            # The fixture still exists after Command-W. An unchecked command
            # would claim success; readback must detect this state.
            state = "still-open" if "exists (first window whose name contains" in script else "closed"
            return subprocess.CompletedProcess(command, 0, state + "\n", "")

        with patch.object(matrix.subprocess, "run", side_effect=dropped_close):
            self.assertFalse(matrix.close_fixture_window("TextEdit", "MGraph TextEdit Fixture test"))


if __name__ == "__main__":
    unittest.main()
