"""Require the runner's unlocked, awake console before native fixture automation."""

import ctypes
import os
import subprocess


FRONTMOST_QUERY = ('tell application "System Events" to get name of '
                   'first application process whose frontmost is true')


class DesktopUnavailable(RuntimeError):
    """The test runner cannot safely inspect or control the foreground desktop."""


def console_and_display_state():
    """Read WindowServer's session and display state from system frameworks."""
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    cg.CGSessionCopyCurrentDictionary.restype = ctypes.c_void_p
    cg.CGMainDisplayID.restype = ctypes.c_uint32
    cg.CGDisplayIsAsleep.argtypes = [ctypes.c_uint32]
    cg.CGDisplayIsAsleep.restype = ctypes.c_bool
    cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFStringCreateWithCString.restype = ctypes.c_void_p
    cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    cf.CFDictionaryGetValue.restype = ctypes.c_void_p
    cf.CFGetTypeID.argtypes = [ctypes.c_void_p]
    cf.CFGetTypeID.restype = ctypes.c_ulong
    cf.CFBooleanGetTypeID.restype = ctypes.c_ulong
    cf.CFNumberGetTypeID.restype = ctypes.c_ulong
    cf.CFBooleanGetValue.argtypes = [ctypes.c_void_p]
    cf.CFBooleanGetValue.restype = ctypes.c_bool
    cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    cf.CFNumberGetValue.restype = ctypes.c_bool
    cf.CFRelease.argtypes = [ctypes.c_void_p]

    session = cg.CGSessionCopyCurrentDictionary()
    if not session:
        raise DesktopUnavailable("WindowServer session unavailable")

    def value_for(key):
        name = cf.CFStringCreateWithCString(None, key.encode(), 0x08000100)
        if not name:
            raise DesktopUnavailable("WindowServer session key unavailable")
        try:
            return cf.CFDictionaryGetValue(session, name)
        finally:
            cf.CFRelease(name)

    def boolean(key):
        value = value_for(key)
        if not value:
            return None
        if cf.CFGetTypeID(value) != cf.CFBooleanGetTypeID():
            raise DesktopUnavailable(f"WindowServer session type mismatch: {key}")
        return bool(cf.CFBooleanGetValue(value))

    def uid(key):
        value = value_for(key)
        if not value:
            return None
        if cf.CFGetTypeID(value) != cf.CFNumberGetTypeID():
            raise DesktopUnavailable(f"WindowServer session type mismatch: {key}")
        result = ctypes.c_int32()
        if not cf.CFNumberGetValue(value, 3, ctypes.byref(result)):
            return None
        return result.value

    try:
        on_console = boolean("kCGSSessionOnConsoleKey") is True
        login_done = boolean("kCGSessionLoginDoneKey") is True
        user_matches = uid("kCGSSessionUserIDKey") == os.getuid()
        # WindowServer omits this key for an unlocked session on macOS 26.6.2.
        # Its absence is accepted only alongside the required console proofs
        # above and the System Events frontmost query below.
        locked = boolean("CGSSessionScreenIsLocked") is True
        asleep = cg.CGDisplayIsAsleep(cg.CGMainDisplayID())
        return on_console and login_done and user_matches and not locked, not asleep
    finally:
        cf.CFRelease(session)


def require_active_desktop():
    try:
        active_console, awake_display = console_and_display_state()
    except (OSError, ValueError) as error:
        raise DesktopUnavailable(f"Console or display query failed: {error}") from error
    if not active_console or not awake_display:
        raise DesktopUnavailable("Active desktop required: console locked, switched, or display asleep")
    try:
        result = subprocess.run(["osascript", "-e", FRONTMOST_QUERY],
                                capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired as error:
        raise DesktopUnavailable("Active desktop query timed out") from error
    except OSError as error:
        raise DesktopUnavailable(f"Active desktop query failed: {error}") from error
    name = result.stdout.strip()
    if result.returncode or not name or name.casefold() in {"loginwindow", "screensaverengine"}:
        detail = result.stderr.strip() or name or "no frontmost application"
        raise DesktopUnavailable(f"Active desktop required for System Events automation: {detail}")
    return name
