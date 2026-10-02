"""An AX-readable process alone must not authorize desktop automation."""

import subprocess
import unittest
from unittest.mock import patch
import ctypes

import desktop_session


class DesktopSessionTests(unittest.TestCase):
    def session_state(self, values, *, asleep=False, uid=501):
        class Function:
            def __init__(self, operation):
                self.operation = operation

            def __call__(self, *args):
                return self.operation(*args)

        class Framework:
            pass

        calls = []
        cf = Framework()
        cf.CFStringCreateWithCString = Function(lambda _, key, __: key)
        cf.CFDictionaryGetValue = Function(lambda _, key: values.get(key.decode()))
        cf.CFGetTypeID = Function(lambda value: value[0])
        cf.CFBooleanGetTypeID = Function(lambda: "boolean")
        cf.CFNumberGetTypeID = Function(lambda: "number")
        cf.CFBooleanGetValue = Function(lambda value: value[1])

        def get_number(value, number_type, result):
            calls.append((number_type, type(result._obj)))
            result._obj.value = value[1]
            return True

        cf.CFNumberGetValue = Function(get_number)
        cf.CFRelease = Function(lambda _: None)
        cg = Framework()
        cg.CGSessionCopyCurrentDictionary = Function(lambda: 1)
        cg.CGMainDisplayID = Function(lambda: 1)
        cg.CGDisplayIsAsleep = Function(lambda _: asleep)
        with patch.object(desktop_session.ctypes, "CDLL", side_effect=[cg, cf]), \
             patch.object(desktop_session.os, "getuid", return_value=uid):
            state = desktop_session.console_and_display_state()
        return state, calls

    def test_core_foundation_types_and_missing_session_values(self):
        active = {
            "kCGSSessionOnConsoleKey": ("boolean", True),
            "kCGSessionLoginDoneKey": ("boolean", True),
            "kCGSSessionUserIDKey": ("number", 501),
        }
        self.assertEqual(self.session_state(active), ((True, True), [(3, ctypes.c_int32)]))
        for change, value in (("kCGSSessionOnConsoleKey", ("boolean", False)),
                              ("kCGSessionLoginDoneKey", None),
                              ("kCGSSessionUserIDKey", ("number", 502)),
                              ("CGSSessionScreenIsLocked", ("boolean", True))):
            with self.subTest(change=change):
                self.assertEqual(self.session_state({**active, change: value})[0][0], False)
        self.assertEqual(self.session_state(active, asleep=True)[0], (True, False))
        with self.assertRaisesRegex(desktop_session.DesktopUnavailable, "type mismatch"):
            self.session_state({**active, "kCGSessionLoginDoneKey": ("number", 1)})

    def test_active_console_and_awake_display_accept_frontmost_app(self):
        with patch.object(desktop_session, "console_and_display_state", return_value=(True, True)), \
             patch.object(desktop_session.subprocess, "run", return_value=subprocess.CompletedProcess(
                 [], 0, "TextEdit\n", "")) as automation:
            self.assertEqual(desktop_session.require_active_desktop(), "TextEdit")
            automation.assert_called_once_with(["osascript", "-e", desktop_session.FRONTMOST_QUERY],
                                               capture_output=True, text=True, timeout=10)

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
