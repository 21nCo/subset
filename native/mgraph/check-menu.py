#!/usr/bin/env python3
"""Native menu-bar journey; requires System Events automation permission."""

import pathlib
import subprocess
import sys
import tempfile
import time


bundle = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).parent / "dist/MGraphCapture.app"
binary = bundle / "Contents/MacOS/MGraphCapture"
marker = "MGRAPH MENU FIXTURE Delta Echo Foxtrot"


def running_pids():
    result = subprocess.run(["pgrep", "-f", str(binary)], capture_output=True, text=True)
    return {int(pid) for pid in result.stdout.split()}


if running_pids():
    sys.exit("Close any existing MGraphCapture instance before this check")

with tempfile.TemporaryDirectory(prefix="mgraph-menu-check-") as temporary:
    fixture = pathlib.Path(temporary) / "fixture.txt"
    fixture.write_text(marker + "\n")
    subprocess.run(["open", "-n", str(bundle)], check=True)
    time.sleep(0.3)
    launched = running_pids()
    if len(launched) != 1:
        sys.exit(f"Expected one app process, found {launched}")
    pid = launched.pop()
    try:
        subprocess.run(["open", "-a", "TextEdit", str(fixture)], check=True)
        script = '''tell application "TextEdit" to activate
delay 0.1
tell application "System Events"
    tell process "MGraphCapture"
        click menu bar item "M Graph" of menu bar 1
        click menu item "Capture Foreground" of menu 1 of menu bar item "M Graph" of menu bar 1
        delay 0.5
        get value of every static text of window 1
    end tell
end tell'''
        for attempt in range(5):
            result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError(f"Menu capture failed: {result.stderr.strip()}")
            subprocess.run(["osascript", "-e", 'tell application "System Events" to tell process "MGraphCapture" to click button "OK" of window 1'],
                           check=True, capture_output=True)
            if marker in result.stdout:
                break
            time.sleep(0.1)
        else:
            raise AssertionError("Fixture text was absent from the native alert after five foreground attempts")
        print("menu_capture_fixture=passed")
        quit_script = '''tell application "System Events" to tell process "MGraphCapture"
    click menu bar item "M Graph" of menu bar 1
    click menu item "Quit M Graph" of menu 1 of menu bar item "M Graph" of menu bar 1
end tell'''
        subprocess.run(["osascript", "-e", quit_script], check=True, capture_output=True)
        for _ in range(30):
            if pid not in running_pids():
                break
            time.sleep(0.1)
        else:
            raise AssertionError("Quit did not stop the app")
        print("menu_quit=passed")
    finally:
        if pid in running_pids():
            subprocess.run(["kill", "-TERM", str(pid)], check=False)
