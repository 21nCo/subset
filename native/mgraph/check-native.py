#!/usr/bin/env python3
"""Launch-context smoke check for the signed development bundle."""

import argparse
import json
import pathlib
import subprocess
import sys
import tempfile
import time
from bundle_process import launched_bundle, owned_pids, wait_for_owned_pid


def bundled_command(bundle, command, folder):
    output = folder / f"{command}.json"
    with launched_bundle(bundle, (command,), output=output, allowed_returncodes=(0, 1, 2)):
        pass
    if not output.exists():
        raise RuntimeError(f"LaunchServices produced no output for {command}")
    return json.loads(output.read_text())


def validate_capture_state(capture, expected):
    assert capture["state"] in ("available", "permissionRequired", "noForegroundApplication", "unsupportedApplication", "readFailed")
    assert capture["state"] != "permissionRequired" or not capture.get("text"), "Denied capture exposed text"
    if expected == "permissionRequired":
        assert capture["state"] == "permissionRequired", f"Denied capture returned {capture['state']}"
    if expected == "available":
        assert capture["state"] != "permissionRequired", "Grant was revoked before capture"


def main():
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
    malformed = subprocess.run([str(binary), "capture", "--invocation-id", "invalid"],
                               capture_output=True, text=True, timeout=5)
    assert malformed.returncode == 64 and not malformed.stdout, "Malformed command was accepted"

    with tempfile.TemporaryDirectory(prefix="mgraph-native-check-") as temporary:
        folder = pathlib.Path(temporary)
        status = bundled_command(bundle, "status", folder)
        assert status["state"] in ("available", "permissionRequired")
        if args.expect_state:
            assert status["state"] == args.expect_state, f"Expected {args.expect_state}, got {status['state']}"
        print(f"bundle_permission={status['state']}")

        with launched_bundle(bundle, wait=False) as invocation:
            pid = wait_for_owned_pid(bundle, invocation)
            assert pid in owned_pids(binary, invocation)
            time.sleep(0.5)
        assert pid not in owned_pids(binary, invocation), "App did not stop"
        print("bundle_startup_shutdown=passed")

        capture = bundled_command(bundle, "capture", folder)
        validate_capture_state(capture, args.expect_state)
        print(f"capture_state={capture['state']} app={capture.get('bundleIdentifier')} characters={len(capture.get('text') or '')}")


if __name__ == "__main__":
    main()
