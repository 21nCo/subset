#!/usr/bin/env python3
"""Exercise a signed bundle against local, nonsensitive document fixtures."""

import json
import pathlib
import subprocess
import sys
import tempfile
import time


bundle = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).parent / "dist/MGraphCapture.app"
marker = "MGRAPH ACCESSIBILITY FIXTURE Alpha Bravo Cedar"
expected = {
    "TextEdit": "com.apple.TextEdit",
    "Safari": "com.apple.Safari",
    "Google Chrome": "com.google.Chrome",
    "Firefox": "org.mozilla.firefox",
}


def close_fixture_window(app, title):
    script = f'''tell application "{app}" to activate
tell application "System Events"
    tell process "{app}"
        if name of front window contains "{title}" then
            keystroke "w" using command down
            return "closed"
        end if
    end tell
end tell
return "not-focused"'''
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return result.returncode == 0 and result.stdout.strip() == "closed"


with tempfile.TemporaryDirectory(prefix="mgraph-fixtures-") as temporary:
    folder = pathlib.Path(temporary)
    plain = folder / "MGraph TextEdit Fixture.txt"
    plain.write_text(marker + "\nSecond line for capture quality.\n")
    html = folder / "fixture.html"
    html.write_text(f"<!doctype html><title>MGraph Capture Fixture</title><h1>{marker}</h1><p>Second line for capture quality.</p>")
    failures = []
    for app, bundle_id in expected.items():
        fixture = plain if app == "TextEdit" else html
        opened = subprocess.run(["open", "-a", app, str(fixture)], capture_output=True, text=True)
        if opened.returncode:
            print(f"{app}: unavailable ({opened.stderr.strip()})")
            failures.append(f"{app}: unavailable")
            continue
        time.sleep(1)
        output = folder / (app.replace(" ", "-") + ".json")
        result = None
        for attempt in range(5):
            output.unlink(missing_ok=True)
            result = None
            subprocess.run(["osascript", "-e", f'tell application "{app}" to activate'], capture_output=True)
            # Firefox opens a local file in a new background tab when an existing
            # window is present. Select the last tab before measuring its body.
            if app == "Firefox":
                subprocess.run(["osascript", "-e", 'tell application "System Events" to keystroke "9" using command down'],
                               check=True, capture_output=True)
            time.sleep(0.5)
            command = subprocess.run(["open", "-n", "-W", "-o", str(output), str(bundle), "--args", "capture"],
                                     capture_output=True, text=True, timeout=20)
            if output.exists():
                result = json.loads(output.read_text())
            if (command.returncode == 0 and result is not None
                    and result.get("bundleIdentifier") == bundle_id
                    and result.get("state") == "available"
                    and marker in (result.get("text") or "")):
                break
            time.sleep(0.5)
        if result is None:
            failures.append(f"{app}: no bundle output")
            title = "MGraph TextEdit Fixture" if app == "TextEdit" else "MGraph Capture Fixture"
            close_fixture_window(app, title)
            continue
        observed = result.get("bundleIdentifier")
        text = result.get("text") or ""
        identity = observed == bundle_id
        if not identity:
            failures.append(f"{app}: foreground changed to {observed}")
        if command.returncode:
            failures.append(f"{app}: bundle command failed ({command.returncode})")
        if result.get("state") != "available" or marker not in text:
            failures.append(f"{app}: fixture text unavailable (state={result.get('state')}, characters={len(text)})")
        print(json.dumps({"app": app, "sourceIdentityMatches": identity, "state": result["state"],
                          "characters": len(text), "fixtureTextFound": marker in text,
                          "windowTitlePresent": bool(result.get("windowTitle")),
                          "documentURLPresent": bool(result.get("documentURL"))}))
        title = "MGraph TextEdit Fixture" if app == "TextEdit" else "MGraph Capture Fixture"
        if not close_fixture_window(app, title):
            failures.append(f"{app}: fixture window was not closed")
    if failures:
        sys.exit("; ".join(failures))
