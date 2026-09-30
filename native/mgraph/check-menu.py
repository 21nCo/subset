#!/usr/bin/env python3
"""Native menu-bar journey; requires System Events automation permission."""

import pathlib
import subprocess
import sys
import tempfile
import time
import uuid
from bundle_process import launched_bundle, owned_pids, wait_for_owned_pid


MARKER = "MGRAPH MENU FIXTURE Delta Echo Foxtrot"
CAPTURE_WAIT_SECONDS = 5  # The collector has four seconds; allow alert delivery.


def apple_script(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=20)


def wait_for_capture_alert(read_alert, *, clock=time.monotonic, sleep=time.sleep):
    """Wait for the asynchronous capture alert through the collector deadline."""
    deadline = clock() + CAPTURE_WAIT_SECONDS
    while True:
        result = read_alert()
        if result.returncode:
            raise RuntimeError(f"Menu alert read failed: {result.stderr.strip()}")
        if result.stdout.strip() != "no-alert":
            return result.stdout
        if clock() >= deadline:
            raise TimeoutError("Capture alert did not appear within five seconds")
        sleep(min(0.1, max(0, deadline - clock())))


def close_fixture_window(title):
    # Check both the command outcome and the window state after the keystroke.
    script = f'''tell application "TextEdit" to activate
tell application "System Events"
    tell process "TextEdit"
        if name of front window does not contain "{title}" then return "not-focused"
        keystroke "w" using command down
        delay 0.1
        if exists (first window whose name contains "{title}") then return "still-open"
        return "closed"
    end tell
end tell'''
    result = apple_script(script)
    return result.returncode == 0 and result.stdout.strip() == "closed"


def run_check(bundle):
    binary = bundle / "Contents/MacOS/MGraphCapture"
    try:
        automation = subprocess.run(
            ["osascript", "-e", 'tell application "System Events" to get count of menu bar items of menu bar 1 of process "Finder"'],
            capture_output=True, text=True, timeout=10,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("System Events access timed out before opening menu fixture") from None
    if automation.returncode:
        raise RuntimeError(f"System Events access required before opening menu fixture: {automation.stderr.strip()}")

    with tempfile.TemporaryDirectory(prefix="mgraph-menu-check-") as temporary:
        fixture = pathlib.Path(temporary) / f"MGraph Menu Fixture {uuid.uuid4().hex[:8]}.txt"
        fixture.write_text(MARKER + "\n")
        with launched_bundle(bundle, wait=False) as invocation:
            pid = wait_for_owned_pid(bundle, invocation)
            opened_fixture = False
            try:
                opened_fixture = True
                subprocess.run(["open", "-a", "TextEdit", str(fixture)], check=True, timeout=20)
                click_script = '''tell application "TextEdit" to activate
delay 0.1
tell application "System Events" to tell process "MGraphCapture"
    click menu bar item "M Graph" of menu bar 1
    click menu item "Capture Foreground" of menu 1 of menu bar item "M Graph" of menu bar 1
end tell'''
                read_script = '''tell application "System Events" to tell process "MGraphCapture"
    if not (exists window 1) then return "no-alert"
    get value of every static text of window 1
end tell'''
                for attempt in range(5):
                    clicked = apple_script(click_script)
                    if clicked.returncode:
                        raise RuntimeError(f"Menu capture failed: {clicked.stderr.strip()}")
                    alert_text = wait_for_capture_alert(lambda: apple_script(read_script))
                    apple_script('tell application "System Events" to tell process "MGraphCapture" to click button "OK" of window 1').check_returncode()
                    if MARKER in alert_text:
                        break
                    time.sleep(0.1)
                else:
                    raise AssertionError("Fixture text was absent from the native alert after five foreground attempts")
                print("menu_capture_fixture=passed")
                quit_script = '''tell application "System Events" to tell process "MGraphCapture"
    click menu bar item "M Graph" of menu bar 1
    click menu item "Quit M Graph" of menu 1 of menu bar item "M Graph" of menu bar 1
end tell'''
                apple_script(quit_script).check_returncode()
                for _ in range(30):
                    if pid not in owned_pids(binary, invocation):
                        break
                    time.sleep(0.1)
                else:
                    raise AssertionError("Quit did not stop the app")
                print("menu_quit=passed")
            finally:
                if opened_fixture and not close_fixture_window(fixture.stem):
                    raise AssertionError("TextEdit menu fixture window was not closed")


if __name__ == "__main__":
    bundle = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).parent / "dist/MGraphCapture.app"
    try:
        run_check(bundle)
    except (AssertionError, RuntimeError, TimeoutError) as error:
        sys.exit(str(error))
