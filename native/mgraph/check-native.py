#!/usr/bin/env python3
"""Launch-context smoke check for the signed development bundle."""

import argparse
import json
import pathlib
import subprocess
import sys
import tempfile
import time
from bundle_process import approve_cli_capture, launched_bundle, owned_pids, wait_for_owned_pid


def canonical_bundle(path):
    bundle = pathlib.Path(path).expanduser().resolve()
    if bundle.name != "MGraphCapture.app":
        raise ValueError("Expected a MGraphCapture.app bundle")
    return bundle


def bundled_command(bundle, command, folder, *, approve=False):
    output = folder / f"{command}.json"
    output.unlink(missing_ok=True)
    with launched_bundle(bundle, (command,), output=output, allowed_returncodes=(0, 1, 2),
                         before_wait=approve_cli_capture if approve else None) as invocation:
        if not invocation:
            raise RuntimeError("LaunchServices invocation identity missing")
    if not output.exists():
        raise RuntimeError(f"LaunchServices produced no output for {command}")
    try:
        result = json.loads(output.read_text())
    except (json.JSONDecodeError, UnicodeError) as error:
        raise RuntimeError(f"LaunchServices produced malformed {command} output") from error
    if not isinstance(result, dict):
        raise RuntimeError(f"LaunchServices produced non-object {command} output")
    return result


def validate_capture_state(capture, expected):
    require(isinstance(capture, dict), "Invalid capture result")
    require(capture.get("state") in ("available", "permissionRequired", "noForegroundApplication",
                                      "unsupportedApplication", "readFailed"), "Invalid capture state")
    require(capture["state"] != "permissionRequired" or not capture.get("text"), "Denied capture exposed text")
    require(capture["state"] == "available" or not capture.get("text"), "Failed capture exposed text")
    if expected == "permissionRequired":
        require(capture["state"] == "permissionRequired", f"Denied capture returned {capture['state']}")
    if expected == "available":
        require(capture["state"] != "permissionRequired", "Grant was revoked before capture")
        require(capture["state"] == "available" and bool(capture.get("text")),
                f"Approved capture unavailable (state={capture['state']})")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", nargs="?", type=pathlib.Path,
                        default=pathlib.Path(__file__).parent / "dist/MGraphCapture.app")
    parser.add_argument("--expect-state", choices=("available", "permissionRequired"))
    args = parser.parse_args()
    bundle = canonical_bundle(args.bundle)
    binary = bundle / "Contents/MacOS/MGraphCapture"
    if not binary.is_file():
        sys.exit(f"Build the app first: {pathlib.Path(__file__).parent / 'build-app.sh'}")
    require((bundle / "Contents/Resources/AppIcon.icns").is_file(), "Bundle icon missing")
    icon = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIconFile",
                           str(bundle / "Contents/Info.plist")], check=True, capture_output=True, text=True)
    require(icon.stdout.strip() == "AppIcon.icns", "Bundle icon is not declared")

    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    links = subprocess.run(["otool", "-L", str(binary)], check=True, capture_output=True, text=True).stdout.splitlines()[1:]
    require(all(line.strip().startswith(("/System/Library/", "/usr/lib/")) for line in links),
            "Non-system runtime dependency")
    print("signature=valid runtime=system-only")
    malformed = subprocess.run([str(binary), "capture", "--invocation-id", "invalid"],
                               capture_output=True, text=True, timeout=5)
    require(malformed.returncode == 64 and not malformed.stdout, "Malformed command was accepted")

    with tempfile.TemporaryDirectory(prefix="mgraph-native-check-") as temporary:
        folder = pathlib.Path(temporary)
        status = bundled_command(bundle, "status", folder)
        require(status.get("state") in ("available", "permissionRequired"), "Invalid bundle permission state")
        if args.expect_state:
            require(status["state"] == args.expect_state, f"Expected {args.expect_state}, got {status['state']}")
        print(f"bundle_permission={status['state']}")

        with launched_bundle(bundle, wait=False) as invocation:
            pid = wait_for_owned_pid(bundle, invocation)
            require(pid in owned_pids(binary, invocation), "Owned app process disappeared during startup")
            time.sleep(0.5)
        require(pid not in owned_pids(binary, invocation), "App did not stop")
        print("bundle_startup_shutdown=passed")

        if status["state"] == "available":
            unapproved = bundled_command(bundle, "capture", folder)
            require(unapproved.get("state") == "readFailed" and not unapproved.get("text"),
                    "CLI capture without fresh approval exposed text")
            print("unapproved_cli_capture=denied")

        capture = bundled_command(bundle, "capture", folder, approve=status["state"] == "available")
        validate_capture_state(capture, args.expect_state)
        print(f"capture_state={capture['state']} app={capture.get('bundleIdentifier')} characters={len(capture.get('text') or '')}")


if __name__ == "__main__":
    main()
