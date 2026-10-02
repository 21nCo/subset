"""Require an interactive desktop before native fixture automation."""

import subprocess


FRONTMOST_QUERY = ('tell application "System Events" to get name of '
                   'first application process whose frontmost is true')


class DesktopUnavailable(RuntimeError):
    """The test runner cannot safely inspect or control the foreground desktop."""


def require_active_desktop():
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
