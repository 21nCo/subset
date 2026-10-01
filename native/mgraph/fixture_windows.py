"""Select and close only the uniquely titled windows owned by native checks."""

import re
import subprocess


APPS = {"TextEdit", "Safari", "Google Chrome", "Firefox"}


def run_window_action(app, title, *, close=False):
    if app not in APPS or not re.fullmatch(r"MGraph [A-Za-z ]+ Fixture [a-f0-9]{8}", title):
        raise ValueError("Expected a native-check fixture app and unique title")

    # A browser may put the file in the last tab of a background window.
    # Raise each window before inspecting its title or trying its last tab.
    last_tab = '''keystroke "9" using command down
                set focusedWindow to get value of attribute "AXFocusedWindow"
                if focusedWindow is not missing value then
                    if name of focusedWindow contains fixtureTitle then exit repeat
                end if''' if app != "TextEdit" else ""
    action = '''keystroke "w" using command down
        repeat 20 times
            set fixtureStillOpen to false
            repeat with remainingWindow in (get value of attribute "AXWindows")
                if name of remainingWindow contains fixtureTitle then set fixtureStillOpen to true
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
                {last_tab}
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
    return run_window_action(app, title)


def close_fixture_window(app, title):
    return run_window_action(app, title, close=True)
