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
from fixture_windows import close_fixture_window, focus_fixture_window


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
        automation = subprocess.run(
            ["osascript", "-e", 'tell application "System Events" to get count of menu bar items of menu bar 1 of process "Finder"'],
            capture_output=True, text=True, timeout=10,
        )
    except subprocess.TimeoutExpired:
        sys.exit("System Events access timed out before opening fixtures")
    if automation.returncode:
        raise RuntimeError(f"System Events access required before opening fixtures: {automation.stderr.strip()}")


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
    for _ in range(5):
        output.unlink(missing_ok=True)
        if not focus_fixture_window(app, title):
            time.sleep(0.5)
            continue
        time.sleep(0.5)
        with launched_bundle(bundle, ("capture",), output=output, allowed_returncodes=(0, 1, 2),
                             before_wait=approve_cli_capture):
            pass
        result = json.loads(output.read_text()) if output.exists() else None
        if (result is not None and result.get("bundleIdentifier") == bundle_id
                and result.get("state") == "available" and marker in (result.get("text") or "")):
            break
        time.sleep(0.5)
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
    failures = []
    opened_fixture = False
    try:
        opened_fixture = True
        opened = subprocess.run(["open", "-a", app, str(fixture)], capture_output=True,
                                text=True, timeout=20)
        if opened.returncode:
            failures.append(f"{app}: unavailable ({opened.stderr.strip()})")
        else:
            time.sleep(1)
            failures.extend(validate_fixture(app, bundle_id, capture_fixture(bundle, folder, app, bundle_id, title)))
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError, TimeoutError) as error:
        failures.append(f"{app}: fixture transition or capture failed ({error})")
    finally:
        if opened_fixture:
            try:
                if not close_fixture_window(app, title):
                    failures.append(f"{app}: fixture window was not closed")
            except subprocess.TimeoutExpired:
                failures.append(f"{app}: fixture close timed out")
    return failures


def main():
    signal.signal(signal.SIGTERM, interrupt)
    require_automation()
    with tempfile.TemporaryDirectory(prefix="mgraph-fixtures-") as temporary:
        folder = pathlib.Path(temporary)
        plain, html, textedit_title, browser_title = write_fixtures(folder)
        failures = []
        for app, bundle_id in expected.items():
            failures.extend(run_app(bundle, folder, app, bundle_id, plain, html,
                                    textedit_title, browser_title))
        if failures:
            sys.exit("; ".join(failures))


if __name__ == "__main__":
    main()
