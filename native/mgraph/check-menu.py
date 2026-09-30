#!/usr/bin/env python3
"""Native menu-bar journey; requires System Events automation permission."""

import pathlib
import subprocess
import sys
import tempfile
import time
import uuid
from bundle_process import launched_bundle, owned_pids, wait_for_owned_pid


bundle = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).parent / "dist/MGraphCapture.app"
binary = bundle / "Contents/MacOS/MGraphCapture"
marker = "MGRAPH MENU FIXTURE Delta Echo Foxtrot"


with tempfile.TemporaryDirectory(prefix="mgraph-menu-check-") as temporary:
    fixture = pathlib.Path(temporary) / f"MGraph Menu Fixture {uuid.uuid4().hex[:8]}.txt"
    fixture.write_text(marker + "\n")
    with launched_bundle(bundle, wait=False) as invocation:
        pid = wait_for_owned_pid(bundle, invocation)
        try:
            subprocess.run(["open", "-a", "TextEdit", str(fixture)], check=True, timeout=20)
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
                result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=20)
                if result.returncode:
                    raise RuntimeError(f"Menu capture failed: {result.stderr.strip()}")
                if marker in result.stdout:
                    subprocess.run(["osascript", "-e", 'tell application "System Events" to tell process "MGraphCapture" to click button "OK" of window 1'],
                                   check=True, capture_output=True, timeout=20)
                    break
                subprocess.run(["osascript", "-e", 'tell application "System Events" to tell process "MGraphCapture" to click button "OK" of window 1'],
                               check=True, capture_output=True, timeout=20)
                time.sleep(0.1)
            else:
                raise AssertionError("Fixture text was absent from the native alert after five foreground attempts")
            print("menu_capture_fixture=passed")
            quit_script = '''tell application "System Events" to tell process "MGraphCapture"
    click menu bar item "M Graph" of menu bar 1
    click menu item "Quit M Graph" of menu 1 of menu bar item "M Graph" of menu bar 1
end tell'''
            subprocess.run(["osascript", "-e", quit_script], check=True, capture_output=True, timeout=20)
            for _ in range(30):
                if pid not in owned_pids(binary, invocation):
                    break
                time.sleep(0.1)
            else:
                raise AssertionError("Quit did not stop the app")
            print("menu_quit=passed")
        finally:
            close_script = f'''tell application "TextEdit" to activate
tell application "System Events"
    tell process "TextEdit"
        if name of front window contains "{fixture.stem}" then
            keystroke "w" using command down
        end if
    end tell
end tell'''
            subprocess.run(["osascript", "-e", close_script], capture_output=True, timeout=20)
