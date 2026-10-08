"""Select and close only the uniquely titled windows owned by native checks."""

import re
import subprocess
import time


CHROME = "Google Chrome"
APPS = {"TextEdit", "Safari", CHROME, "Firefox"}
FIXTURE_TITLE = r"MGraph [A-Za-z ]+ Fixture [a-f0-9]{8}"
FIXTURE_CLEANUP_SECONDS = 12


def remaining(deadline, limit):
    if deadline is None:
        return limit
    left = deadline - time.monotonic()
    if left <= 0:
        raise TimeoutError("Fixture cleanup deadline exceeded")
    return min(limit, left)


def run_window_action(app, title, *, close=False, deadline=None):
    if app not in APPS or not re.fullmatch(FIXTURE_TITLE, title):
        raise ValueError("Expected a native-check fixture app and unique title")

    # Inspect tab labels before changing selection. Command-9 on every window
    # would alter unrelated browser windows, including ones owned by the user.
    select_tab = '''repeat with child in (get entire contents of candidate)
                    try
                        if name of child contains fixtureTitle then
                            perform action "AXPress" of child
                            exit repeat
                        end if
                    end try
                end repeat
                set focusedWindow to get value of attribute "AXFocusedWindow"
                if focusedWindow is not missing value then
                    if name of focusedWindow contains fixtureTitle then exit repeat
                end if''' if app != "TextEdit" else ""
    browser_readback = '''try
                    repeat with child in (get entire contents of remainingWindow)
                        try
                            if name of child contains fixtureTitle then set fixtureStillOpen to true
                        end try
                    end repeat
                on error
                    set fixtureStillOpen to true
                end try''' if app != "TextEdit" else ""
    action = f'''keystroke "w" using command down
        repeat 50 times
            set fixtureStillOpen to false
            try
                repeat with remainingWindow in (get value of attribute "AXWindows")
                    try
                        if name of remainingWindow contains fixtureTitle then set fixtureStillOpen to true
                        {browser_readback}
                    on error
                        set fixtureStillOpen to true
                    end try
                end repeat
            on error
                set fixtureStillOpen to true
            end try
            if not fixtureStillOpen then return "closed"
            delay 0.1
        end repeat
        return "still-open"''' if close else 'return "focused"'
    script = f'''set fixtureTitle to "{title}"
tell application "{app}" to activate
tell application "System Events"
    tell process "{app}"
        set frontmost to true
        repeat with candidate in (get value of attribute "AXWindows")
            try
                perform action "AXRaise" of candidate
                set focusedWindow to get value of attribute "AXFocusedWindow"
                if focusedWindow is not missing value then
                    if name of focusedWindow contains fixtureTitle then exit repeat
                end if
                {select_tab}
            end try
        end repeat
        set focusedWindow to get value of attribute "AXFocusedWindow"
        if focusedWindow is missing value then return "not-focused"
        if name of focusedWindow does not contain fixtureTitle then return "not-focused"
        {action}
    end tell
end tell'''
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True,
                            timeout=remaining(deadline, 8))
    return result.returncode == 0 and result.stdout.strip() == ("closed" if close else "focused")


def focus_fixture_window(app, title):
    if run_window_action(app, title):
        return True
    # Chrome does not expose hidden tabs through its AX descendants on this
    # host. Its scripting API can select only the exact fixture tab by title.
    if app == CHROME and chrome_tab_action(title, "select") == "selected":
        return run_window_action(app, title)
    return False


def close_fixture_window(app, title, *, deadline=None):
    deadline = deadline if deadline is not None else time.monotonic() + FIXTURE_CLEANUP_SECONDS
    try:
        closed_by_ax = run_window_action(app, title, close=True, deadline=deadline)
    except subprocess.TimeoutExpired:
        if app != CHROME:
            raise
        # Chrome's exact-tab adapter can still verify or close this fixture
        # after its AX tree stalls, provided the shared deadline has time.
        closed_by_ax = False
    if app != CHROME:
        return closed_by_ax
    if chrome_tab_action(title, "exists", deadline=deadline) == "absent":
        return True
    # A dropped Command-W can leave a hidden fixture tab after the window
    # title changes. Close that exact tab via Chrome and verify its absence.
    return (chrome_tab_action(title, "close", deadline=deadline) == "closed"
            and chrome_tab_action(title, "exists", deadline=deadline) == "absent")


def chrome_tab_action(title, operation, *, deadline=None):
    if not re.fullmatch(FIXTURE_TITLE, title):
        raise ValueError("Expected a unique native-check fixture title")
    if operation not in {"exists", "select", "close"}:
        raise ValueError("Unsupported Chrome tab operation")
    action = {
        "exists": 'return "exists"',
        "select": 'set active tab index of candidateWindow to tabNumber\n                return "selected"',
        "close": 'close candidateTab\n                return "closed"',
    }[operation]
    script = f'''set fixtureTitle to "{title}"
tell application "{CHROME}"
    repeat with candidateWindow in windows
        set tabNumber to 0
        repeat with candidateTab in tabs of candidateWindow
            set tabNumber to tabNumber + 1
            if title of candidateTab contains fixtureTitle then
                {action}
            end if
        end repeat
    end repeat
end tell
return "absent"'''
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True,
                            timeout=remaining(deadline, 5))
    if result.returncode:
        raise RuntimeError(f"Chrome fixture tab {operation} failed: {result.stderr.strip()}")
    answer = result.stdout.strip()
    if answer not in {"exists", "selected", "closed", "absent"}:
        raise RuntimeError("Chrome fixture tab check returned an unknown result")
    return answer


def fixture_window_exists(app, title, *, deadline=None):
    """Bounded presence probe; None means a hidden browser tab is uncertain."""
    if app not in APPS or not re.fullmatch(FIXTURE_TITLE, title):
        raise ValueError("Expected a native-check fixture app and unique title")
    script = f'''set fixtureTitle to "{title}"
tell application "System Events"
    if not (exists process "{app}") then return "process-absent"
    tell process "{app}"
    repeat with candidate in (get value of attribute "AXWindows")
        if name of candidate contains fixtureTitle then return "exists"
    end repeat
    return "absent"
    end tell
end tell'''
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True,
                            timeout=remaining(deadline, 5))
    if result.returncode:
        raise RuntimeError(f"Fixture presence check failed: {result.stderr.strip()}")
    answer = result.stdout.strip()
    if answer not in {"exists", "absent", "process-absent"}:
        raise RuntimeError("Fixture presence check returned an unknown result")
    if answer == "exists":
        return True
    if answer == "process-absent":
        return False
    if app == CHROME:
        return chrome_tab_action(title, "exists", deadline=deadline) == "exists"
    return False if app == "TextEdit" else None


def cleanup_fixture_after_open(app, title, open_outcome):
    """Close a unique fixture after success or uncertain partial open."""
    deadline = time.monotonic() + FIXTURE_CLEANUP_SECONDS
    if open_outcome == "failed":
        try:
            if fixture_window_exists(app, title, deadline=deadline) is False:
                return True
        except (subprocess.TimeoutExpired, RuntimeError):
            pass  # Unknown presence still requires a safe close attempt.
    if close_fixture_window(app, title, deadline=deadline):
        return True
    # A partial open may have failed before creating a TextEdit window or
    # Chrome tab. A negative bounded readback is conclusive for these apps.
    if open_outcome != "success":
        return fixture_window_exists(app, title, deadline=deadline) is False
    return False
