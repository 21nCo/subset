#!/usr/bin/env python3
"""Native menu-bar journey; requires System Events automation permission."""

import pathlib
import subprocess
import sys
import tempfile
import time
import uuid
from bundle_process import is_owned, launched_bundle, owned_pids, wait_for_owned_pid
from desktop_session import DesktopUnavailable, require_active_desktop
from fixture_windows import cleanup_fixture_after_open, focus_fixture_window


MARKER = "MGRAPH MENU FIXTURE Delta Echo Foxtrot"
CAPTURE_WAIT_SECONDS = 5  # The collector has four seconds; allow alert delivery.


def apple_script(script, *, timeout=20):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=timeout)


def wait_for_capture_alert(read_alert, *, clock=time.monotonic, sleep=time.sleep):
    """Wait for the asynchronous capture alert through the collector deadline."""
    deadline = clock() + CAPTURE_WAIT_SECONDS
    while True:
        remaining = deadline - clock()
        if remaining <= 0:
            raise TimeoutError("Capture alert did not appear within five seconds")
        try:
            result = read_alert(remaining)
        except subprocess.TimeoutExpired as error:
            raise TimeoutError("Capture alert read exceeded five-second deadline") from error
        if result.returncode:
            raise RuntimeError(f"Menu alert read failed: {result.stderr.strip()}")
        if result.stdout.strip() != "no-alert":
            return result.stdout
        if clock() >= deadline:
            raise TimeoutError("Capture alert did not appear within five seconds")
        sleep(min(0.1, max(0, deadline - clock())))


def close_fixture_window(title, open_outcome="success"):
    return cleanup_fixture_after_open("TextEdit", title, open_outcome)


def menu_operation(pid, invocation, binary, body, *, timeout=20, allow_exit=False):
    require_active_desktop()
    if not is_owned(binary, invocation, pid):
        raise RuntimeError("Owned M Graph process exited before menu operation")
    menu_title = f"M Graph · {str(uuid.UUID(invocation)).upper()}"
    body = body.replace('menu bar item "M Graph"', f'menu bar item "{menu_title}"')
    script = f'tell application "System Events" to tell (first process whose unix id is {pid})\n{body}\nend tell'
    result = apple_script(script, timeout=timeout)
    if not allow_exit and not is_owned(binary, invocation, pid):
        raise RuntimeError("Owned M Graph process exited during menu operation")
    if result.returncode:
        raise RuntimeError(f"Menu operation failed: {result.stderr.strip()}")
    return result


def require_automation():
    try:
        require_active_desktop()
    except DesktopUnavailable as error:
        raise DesktopUnavailable(f"System Events access required before opening menu fixture: {error}") from error


def exercise_menu(pid, invocation, binary, title):
    click_script = '''
    click menu bar item "M Graph" of menu bar 1
    click menu item "Capture Foreground" of menu 1 of menu bar item "M Graph" of menu bar 1
'''
    read_script = '''
    if not (exists window 1) then return "no-alert"
    get value of every static text of window 1
'''
    for _ in range(5):
        require_active_desktop()
        if not focus_fixture_window("TextEdit", title):
            raise RuntimeError("TextEdit menu fixture could not be focused")
        menu_operation(pid, invocation, binary, click_script)
        alert_text = wait_for_capture_alert(
            lambda remaining: menu_operation(pid, invocation, binary, read_script,
                                             timeout=remaining))
        menu_operation(pid, invocation, binary, 'click button "OK" of window 1')
        if MARKER in alert_text:
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("Fixture text was absent from the native alert after five foreground attempts")
    print("menu_capture_fixture=passed")
    quit_script = '''
    click menu bar item "M Graph" of menu bar 1
    click menu item "Quit M Graph" of menu 1 of menu bar item "M Graph" of menu bar 1
'''
    menu_operation(pid, invocation, binary, quit_script, allow_exit=True)
    for _ in range(30):
        if pid not in owned_pids(binary, invocation):
            print("menu_quit=passed")
            return
        time.sleep(0.1)
    raise RuntimeError("Quit did not stop the app")


def run_check(bundle):
    binary = bundle.resolve() / "Contents/MacOS/MGraphCapture"
    require_automation()
    with tempfile.TemporaryDirectory(prefix="mgraph-menu-check-") as temporary:
        fixture = pathlib.Path(temporary) / f"MGraph Menu Fixture {uuid.uuid4().hex[:8]}.txt"
        fixture.write_text(MARKER + "\n")
        with launched_bundle(bundle, args=("--expected-fixture-title", fixture.name), wait=False) as invocation:
            pid = wait_for_owned_pid(bundle, invocation)
            open_outcome = "unknown"
            attempted_open = False
            failures = []
            try:
                require_active_desktop()
                attempted_open = True
                subprocess.run(["open", "-a", "TextEdit", str(fixture)], check=True, timeout=20)
                open_outcome = "success"
                require_active_desktop()
                exercise_menu(pid, invocation, binary, fixture.stem)
            except (RuntimeError, subprocess.CalledProcessError,
                    subprocess.TimeoutExpired, OSError) as error:
                failures.append(str(error))
            finally:
                try:
                    if attempted_open:
                        require_active_desktop()
                        if not close_fixture_window(fixture.stem, open_outcome):
                            failures.append("TextEdit menu fixture window was not closed")
                except (RuntimeError, subprocess.TimeoutExpired, OSError) as error:
                    failures.append(f"TextEdit fixture cleanup failed ({error})")
                if attempted_open and any("fixture cleanup failed" in item or "was not closed" in item for item in failures):
                    failures.append(f"TextEdit: exact fixture title {fixture.stem} remains pending cleanup")
            if failures:
                raise RuntimeError("; ".join(failures))


if __name__ == "__main__":
    bundle = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).parent / "dist/MGraphCapture.app"
    try:
        run_check(bundle)
    except (AssertionError, RuntimeError, TimeoutError, subprocess.CalledProcessError,
            subprocess.TimeoutExpired) as error:
        sys.exit(str(error))
