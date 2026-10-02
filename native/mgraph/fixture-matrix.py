#!/usr/bin/env python3
"""Exercise a signed bundle against local, nonsensitive document fixtures."""

import json
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from bundle_process import LaunchInterrupted, approve_cli_capture, launched_bundle
from desktop_session import DesktopUnavailable, require_active_desktop
from fixture_windows import cleanup_fixture_after_open, focus_fixture_window


bundle = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).parent / "dist/MGraphCapture.app"
marker = "MGRAPH ACCESSIBILITY FIXTURE Alpha Bravo Cedar"
expected = {
    "TextEdit": "com.apple.TextEdit",
    "Safari": "com.apple.Safari",
    "Google Chrome": "com.google.Chrome",
    "Firefox": "org.mozilla.firefox",
}


def interrupt(_signum, _frame):
    raise LaunchInterrupted("Fixture check interrupted by SIGTERM")


def require_automation():
    try:
        require_active_desktop()
    except DesktopUnavailable as error:
        raise DesktopUnavailable(f"System Events access required before opening fixtures: {error}") from error


def write_fixtures(folder):
    fixture_id = uuid.uuid4().hex[:8]
    textedit_title = f"MGraph TextEdit Fixture {fixture_id}"
    browser_title = f"MGraph Capture Fixture {fixture_id}"
    plain = folder / f"{textedit_title}.txt"
    plain.write_text(marker + "\nSecond line for capture quality.\n")
    html = folder / "fixture.html"
    html.write_text(f"<!doctype html><title>{browser_title}</title><h1>{marker}</h1><p>Second line for capture quality.</p>")
    return plain, html, textedit_title, browser_title


def capture_fixture(bundle, folder, app, bundle_id, title):
    output = folder / (app.replace(" ", "-") + ".json")
    result = None
    focused = False
    for _ in range(5):
        require_active_desktop()
        output.unlink(missing_ok=True)
        if not focus_fixture_window(app, title):
            time.sleep(0.5)
            continue
        focused = True
        time.sleep(0.5)
        with launched_bundle(bundle, ("capture",), output=output, allowed_returncodes=(0, 1, 2),
                             before_wait=approve_cli_capture) as invocation:
            if not invocation:
                raise RuntimeError("LaunchServices invocation identity missing")
        result = read_capture_output(output)
        if (result.get("bundleIdentifier") == bundle_id
                and result.get("state") == "available" and marker in (result.get("text") or "")):
            break
        time.sleep(0.5)
    if not focused:
        raise RuntimeError("fixture could not be focused")
    return result


def read_capture_output(output):
    if not output.exists():
        raise RuntimeError("bundle produced no output")
    try:
        result = json.loads(output.read_text())
    except (json.JSONDecodeError, UnicodeError) as error:
        raise RuntimeError("bundle output was malformed") from error
    if not isinstance(result, dict):
        raise RuntimeError("bundle output was not an object")
    return result


def validate_fixture(app, bundle_id, result):
    if result is None:
        return [f"{app}: no bundle output"]
    body = result.get("text") or ""
    identity = result.get("bundleIdentifier") == bundle_id
    failures = []
    if not identity:
        failures.append(f"{app}: foreground changed to {result.get('bundleIdentifier')}")
    if result.get("state") != "available" or marker not in body:
        failures.append(f"{app}: fixture text unavailable (state={result.get('state')}, characters={len(body)})")
    print(json.dumps({"app": app, "sourceIdentityMatches": identity, "state": result.get("state"),
                      "characters": len(body), "fixtureTextFound": marker in body,
                      "windowTitlePresent": bool(result.get("windowTitle")),
                      "documentURLPresent": bool(result.get("documentURL"))}))
    return failures


def run_app(bundle, folder, app, bundle_id, plain, html, textedit_title, browser_title):
    title = textedit_title if app == "TextEdit" else browser_title
    fixture = plain if app == "TextEdit" else html
    capture_failures = []
    open_outcome = "unknown"
    attempted_open = False
    session_error = None
    try:
        require_active_desktop()
        attempted_open = True
        opened = subprocess.run(["open", "-a", app, str(fixture)], capture_output=True,
                                text=True, timeout=20)
        if opened.returncode:
            open_outcome = "failed"
            capture_failures.append(f"{app}: unavailable ({opened.stderr.strip()})")
        else:
            open_outcome = "success"
            time.sleep(1)
            capture_failures.extend(validate_fixture(app, bundle_id,
                capture_fixture(bundle, folder, app, bundle_id, title)))
    except DesktopUnavailable as error:
        session_error = error
        capture_failures.append(f"{app}: active desktop lost ({error})")
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError, RuntimeError,
            OSError, ValueError) as error:
        if open_outcome == "unknown":
            open_outcome = "failed"
        capture_failures.append(f"{app}: fixture transition or capture failed ({error})")
    finally:
        if attempted_open:
            cleanup_failures, cleanup_session_error = finish_fixture(app, title, open_outcome)
            if cleanup_session_error is not None:
                session_error = cleanup_session_error
        else:
            cleanup_failures = []
    failures = capture_failures + cleanup_failures
    if session_error is not None:
        raise DesktopUnavailable("; ".join(failures)) from session_error
    return failures


def finish_fixture(app, title, open_outcome):
    try:
        require_active_desktop()
    except DesktopUnavailable as error:
        return ([f"{app}: cleanup unverified; exact fixture title {title}; "
                 f"restore desktop and close this fixture by title ({error})"], error)
    failures = cleanup_failure(app, title, open_outcome)
    if failures:
        failures.append(f"{app}: exact fixture title {title} remains pending cleanup")
    try:
        require_active_desktop()
    except DesktopUnavailable as error:
        failures.append(f"{app}: active desktop lost after cleanup ({error})")
        return failures, error
    return failures, None


def cleanup_failure(app, title, open_outcome):
    try:
        if cleanup_fixture_after_open(app, title, open_outcome):
            return []
        return [f"{app}: fixture window was not closed"]
    except (subprocess.TimeoutExpired, RuntimeError, OSError) as error:
        return [f"{app}: fixture cleanup failed ({error})"]


def main():
    signal.signal(signal.SIGTERM, interrupt)
    require_automation()
    with tempfile.TemporaryDirectory(prefix="mgraph-fixtures-") as temporary:
        folder = pathlib.Path(temporary)
        plain, html, textedit_title, browser_title = write_fixtures(folder)
        failures = []
        for app, bundle_id in expected.items():
            try:
                failures.extend(run_app(bundle, folder, app, bundle_id, plain, html,
                                        textedit_title, browser_title))
            except DesktopUnavailable as error:
                failures.append(str(error))
                break
        if failures:
            sys.exit("; ".join(failures))


if __name__ == "__main__":
    try:
        main()
    except DesktopUnavailable as error:
        sys.exit(str(error))
