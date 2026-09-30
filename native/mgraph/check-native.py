#!/usr/bin/env python3
"""Launch-context smoke check for the signed development bundle."""

import argparse
import json
import pathlib
import signal
import subprocess
import sys
import tempfile
import time


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("bundle", nargs="?", type=pathlib.Path,
                    default=pathlib.Path(__file__).parent / "dist/MGraphCapture.app")
parser.add_argument("--expect-state", choices=("available", "permissionRequired"))
args = parser.parse_args()
bundle = args.bundle
binary = bundle / "Contents/MacOS/MGraphCapture"
if not binary.is_file():
    sys.exit(f"Build the app first: {pathlib.Path(__file__).parent / 'build-app.sh'}")

subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
links = subprocess.run(["otool", "-L", str(binary)], check=True, capture_output=True, text=True).stdout.splitlines()[1:]
assert all(line.strip().startswith(("/System/Library/", "/usr/lib/")) for line in links), "Non-system runtime dependency"
print("signature=valid runtime=system-only")


def bundled_command(command, folder):
    output = folder / f"{command}.json"
    subprocess.run(["open", "-n", "-W", "-o", str(output), str(bundle), "--args", command],
                   capture_output=True, text=True, timeout=20)
    if not output.exists():
        raise RuntimeError(f"LaunchServices produced no output for {command}")
    return json.loads(output.read_text())


def running_pids():
    process = subprocess.run(["pgrep", "-f", str(binary)], capture_output=True, text=True)
    return {int(pid) for pid in process.stdout.split()}


with tempfile.TemporaryDirectory(prefix="mgraph-native-check-") as temporary:
    folder = pathlib.Path(temporary)
    status = bundled_command("status", folder)
    assert status["state"] in ("available", "permissionRequired")
    if args.expect_state:
        assert status["state"] == args.expect_state, f"Expected {args.expect_state}, got {status['state']}"
    print(f"bundle_permission={status['state']}")

    before = running_pids()
    subprocess.run(["open", "-n", str(bundle)], check=True, capture_output=True)
    time.sleep(2)
    launched = running_pids() - before
    assert len(launched) == 1, f"Expected one new app process, got {launched}"
    pid = launched.pop()
    try:
        subprocess.run(["kill", "-TERM", str(pid)], check=True)
        for _ in range(30):
            if pid not in running_pids():
                break
            time.sleep(0.1)
        else:
            raise AssertionError("App did not stop")
    finally:
        if pid in running_pids():
            subprocess.run(["kill", "-KILL", str(pid)], check=False)
    print("bundle_startup_shutdown=passed")

    capture = bundled_command("capture", folder)
    assert capture["state"] in ("available", "permissionRequired", "noForegroundApplication", "unsupportedApplication", "readFailed")
    assert capture["state"] != "permissionRequired" or not capture.get("text"), "Denied capture exposed text"
    if args.expect_state == "permissionRequired":
        assert capture["state"] == "permissionRequired", f"Denied capture returned {capture['state']}"
    print(f"capture_state={capture['state']} app={capture.get('bundleIdentifier')} characters={len(capture.get('text') or '')}")
