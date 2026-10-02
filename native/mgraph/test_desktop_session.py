"""An AX-readable process alone must not authorize desktop automation."""

import subprocess
import unittest
from unittest.mock import patch

import desktop_session


class DesktopSessionTests(unittest.TestCase):
    def test_active_console_and_awake_display_accept_frontmost_app(self):
        with patch.object(desktop_session, "console_and_display_state", return_value=(True, True)), \
             patch.object(desktop_session.subprocess, "run", return_value=subprocess.CompletedProcess(
                 [], 0, "TextEdit\n", "")):
            self.assertEqual(desktop_session.require_active_desktop(), "TextEdit")

    def test_switched_locked_or_sleeping_session_rejects_stale_frontmost_app(self):
        for state in ((False, True), (True, False)):
            with self.subTest(state=state), \
                 patch.object(desktop_session, "console_and_display_state", return_value=state), \
                 patch.object(desktop_session.subprocess, "run") as automation:
                with self.assertRaisesRegex(desktop_session.DesktopUnavailable, "Active desktop required"):
                    desktop_session.require_active_desktop()
                automation.assert_not_called()


if __name__ == "__main__":
    unittest.main()
