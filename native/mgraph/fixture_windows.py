"""Select and close only the uniquely titled windows owned by native checks."""

import re
import subprocess


APPS = {"TextEdit", "Safari", "Google Chrome", "Firefox"}


def run_window_action(app, title, *, close=False):
    if app not in APPS or not re.fullmatch(r"MGraph [A-Za-z ]+ Fixture [a-f0-9]{8}", title):
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
                    return "read-error"
                end try''' if app != "TextEdit" else ""
    action = f'''keystroke "w" using command down
        repeat 50 times
            set fixtureStillOpen to false
            repeat with remainingWindow in (get value of attribute "AXWindows")
                if name of remainingWindow contains fixtureTitle then set fixtureStillOpen to true
                {browser_readback}
            end repeat
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
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=20)
    return result.returncode == 0 and result.stdout.strip() == ("closed" if close else "focused")


def focus_fixture_window(app, title):
    if run_window_action(app, title):
        return True
    # Chrome does not expose hidden tabs through its AX descendants on this
    # host. Its scripting API can select only the exact fixture tab by title.
    if app == "Google Chrome" and chrome_tab_action(title, "select") == "selected":
        return run_window_action(app, title)
    return False


def close_fixture_window(app, title):
    closed_by_ax = run_window_action(app, title, close=True)
    if app != "Google Chrome":
        return closed_by_ax
    if chrome_tab_action(title, "exists") == "absent":
        return True
    # A dropped Command-W can leave a hidden fixture tab after the window
    # title changes. Close that exact tab via Chrome and verify its absence.
    return (chrome_tab_action(title, "close") == "closed"
            and chrome_tab_action(title, "exists") == "absent")


def chrome_tab_action(title, operation):
    if not re.fullmatch(r"MGraph [A-Za-z ]+ Fixture [a-f0-9]{8}", title):
        raise ValueError("Expected a unique native-check fixture title")
    if operation not in {"exists", "select", "close"}:
        raise ValueError("Unsupported Chrome tab operation")
    action = {
        "exists": 'return "exists"',
        "select": 'set active tab index of candidateWindow to tabNumber\n                return "selected"',
        "close": 'close candidateTab\n                return "closed"',
    }[operation]
    script = f'''set fixtureTitle to "{title}"
tell application "Google Chrome"
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
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=5)
    if result.returncode:
        raise RuntimeError(f"Chrome fixture tab {operation} failed: {result.stderr.strip()}")
    answer = result.stdout.strip()
    if answer not in {"exists", "selected", "closed", "absent"}:
        raise RuntimeError("Chrome fixture tab check returned an unknown result")
    return answer


def fixture_window_exists(app, title):
    """Read-only partial-open probe; a unique fixture title is required."""
    if app not in APPS or not re.fullmatch(r"MGraph [A-Za-z ]+ Fixture [a-f0-9]{8}", title):
        raise ValueError("Expected a native-check fixture app and unique title")
    inspect_tabs = '''repeat with child in (get entire contents of candidate)
            try
                if name of child contains fixtureTitle then return "exists"
            end try
        end repeat''' if app != "TextEdit" else ""
    script = f'''set fixtureTitle to "{title}"
tell application "System Events"
    if not (exists process "{app}") then return "absent"
    tell process "{app}"
    repeat with candidate in (get value of attribute "AXWindows")
        if name of candidate contains fixtureTitle then return "exists"
        {inspect_tabs}
    end repeat
    return "absent"
    end tell
end tell'''
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=5)
    if result.returncode:
        raise RuntimeError(f"Fixture presence check failed: {result.stderr.strip()}")
    found = result.stdout.strip() == "exists"
    return found or (app == "Google Chrome" and chrome_tab_action(title, "exists") == "exists")
