#!/usr/bin/env python3
"""OS-visible expiry and isolation check for a signed LaunchServices bundle."""

import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from bundle_process import pid_exists, process_identity


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def wait_ready(control, binary, deadline):
    while time.monotonic() < deadline:
        try:
            pid = int((control / "ready").read_text())
        except (OSError, ValueError):
            time.sleep(0.05)
            continue
        identity = process_identity(pid)
        if identity is not None and pathlib.Path(identity[0]).resolve() == binary:
            return (pid, identity)
        time.sleep(0.05)
    raise RuntimeError("Ready PID did not identify the signed bundle before deadline")


def wait_exited(control, binary, deadline, expected=None):
    """Prove the exact ready invocation exited, even if its PID was reused."""
    while time.monotonic() < deadline:
        try:
            pid = int((control / "ready").read_text())
        except (OSError, ValueError):
            time.sleep(0.05)
            continue
        if expected is not None and pid != expected[0]:
            raise RuntimeError("Ready PID changed during invocation")
        current = process_identity(pid)
        if expected is not None:
            if current is not None and current != expected[1]:
                return True
        elif current is not None:
            if pathlib.Path(current[0]).resolve() != binary:
                return True  # The private ready PID has since been reused.
            expected = (pid, current)
        if current is None and pid_exists(pid) is False:
            return True
        time.sleep(0.05)
    return False


def launch(bundle, control, marker, lifetime, *, wait):
    command = ["open", "-n"]
    if wait:
        command.append("-W")
    command += [str(bundle), "--args", "--shutdown-after", str(lifetime),
                "--shutdown-file", str(control / "shutdown"), "--invocation-id", marker]
    if wait:
        return subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    completed = subprocess.run(command, capture_output=True, text=True, timeout=5)
    require(completed.returncode == 0, f"LaunchServices failed: {completed.stderr.strip()}")
    return None


def main(bundle):
    bundle = bundle.resolve()
    binary = bundle / "Contents/MacOS/MGraphCapture"
    require(binary.is_file(), "Signed MGraphCapture bundle is missing")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    temporary = pathlib.Path(tempfile.mkdtemp(prefix="mgraph-lifetime-"))
    cleanup_verified = False
    try:
        controls = {}
        launchers = []
        launched = set()
        identities = {}

        def control(name):
            path = temporary / name
            path.mkdir()
            marker = str(uuid.uuid4())
            controls[name] = (path, marker)
            return path, marker

        try:
            other, other_marker = control("other")
            launched.add("other")
            launchers.append(launch(bundle, other, other_marker, 20, wait=True))
            identities["other"] = wait_ready(other, binary, time.monotonic() + 5)

            early, early_marker = control("early")
            launched.add("early")
            launch(bundle, early, early_marker, 3, wait=False)
            early_before_ready = not (early / "ready").exists()
            identities["early"] = wait_ready(early, binary, time.monotonic() + 5)
            require(wait_exited(early, binary, time.monotonic() + 5, identities["early"]),
                    "App outlived its expiry after no-wait launcher exit")
            require(process_identity(identities["other"][0]) == identities["other"][1],
                    "Unrelated invocation exited with the early one")

            late, late_marker = control("late")
            launched.add("late")
            late_launcher = launch(bundle, late, late_marker, 3, wait=True)
            launchers.append(late_launcher)
            identities["late"] = wait_ready(late, binary, time.monotonic() + 5)
            late_launcher.kill()
            late_launcher.wait(timeout=2)
            (late / "shutdown").unlink(missing_ok=True)
            require(wait_exited(late, binary, time.monotonic() + 5, identities["late"]),
                    "App outlived its expiry after runner death")
            require(process_identity(identities["other"][0]) == identities["other"][1],
                    "Unrelated invocation exited with the killed runner")

            (other / "shutdown").write_text(other_marker.upper())
            require(wait_exited(other, binary, time.monotonic() + 5, identities["other"]),
                    "Other invocation ignored its shutdown marker")
        finally:
            for path, marker in controls.values():
                (path / "shutdown").write_text(marker.upper())
            deadline = time.monotonic() + 5
            unverified = []
            for name in launched:
                path, _ = controls[name]
                if not wait_exited(path, binary, deadline, identities.get(name)):
                    unverified.append(name)
            for launcher in launchers:
                if launcher is not None and launcher.poll() is None:
                    try:
                        launcher.wait(timeout=max(0.05, deadline - time.monotonic()))
                    except subprocess.TimeoutExpired:
                        launcher.kill()
                        launcher.wait(timeout=max(0.05, deadline - time.monotonic()))
            if unverified:
                raise RuntimeError(f"Owned invocation exit unverified: {', '.join(sorted(unverified))}; "
                                   f"shutdown markers retained at {temporary}")
            cleanup_verified = True
        print(f"early_launcher_exited_before_ready={str(early_before_ready).lower()}")
        print("abandoned_invocations_expired=passed other_invocation_preserved=passed")
    finally:
        if cleanup_verified:
            shutil.rmtree(temporary)


if __name__ == "__main__":
    target = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).parent / "dist/MGraphCapture.app"
    try:
        main(target)
    except (OSError, RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        sys.exit(str(error))
