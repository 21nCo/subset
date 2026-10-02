#!/usr/bin/env python3
"""OS-visible expiry and isolation check for a signed LaunchServices bundle."""

import pathlib
import subprocess
import sys
import tempfile
import time
import uuid
from bundle_process import process_identity


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def alive(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="],
                            capture_output=True, text=True, timeout=2)
    return result.returncode == 0 and bool(result.stdout.strip())


def wait_ready(control, binary):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            pid = int((control / "ready").read_text())
        except (OSError, ValueError):
            time.sleep(0.05)
            continue
        identity = process_identity(pid)
        require(identity is not None and pathlib.Path(identity[0]).resolve() == binary,
                "Ready PID did not identify the signed bundle")
        return pid
    raise RuntimeError("Signed bundle did not publish a ready PID")


def wait_exited(pid, seconds):
    deadline = time.monotonic() + seconds
    while alive(pid) and time.monotonic() < deadline:
        time.sleep(0.05)
    return not alive(pid)


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
    with tempfile.TemporaryDirectory(prefix="mgraph-lifetime-") as temporary:
        controls = {}
        launchers = []

        def control(name):
            path = pathlib.Path(temporary) / name
            path.mkdir()
            marker = str(uuid.uuid4())
            controls[name] = (path, marker)
            return path, marker

        try:
            other, other_marker = control("other")
            launchers.append(launch(bundle, other, other_marker, 20, wait=True))
            other_pid = wait_ready(other, binary)

            early, early_marker = control("early")
            launch(bundle, early, early_marker, 3, wait=False)
            early_before_ready = not (early / "ready").exists()
            early_pid = wait_ready(early, binary)
            require(wait_exited(early_pid, 5), "App outlived its expiry after no-wait launcher exit")
            require(early_before_ready, "No-wait launcher remained active until ready; before-ready abandonment unproven")
            require(alive(other_pid), "Unrelated invocation exited with the early one")

            late, late_marker = control("late")
            late_launcher = launch(bundle, late, late_marker, 3, wait=True)
            launchers.append(late_launcher)
            late_pid = wait_ready(late, binary)
            late_launcher.kill()
            late_launcher.wait(timeout=2)
            (late / "shutdown").unlink(missing_ok=True)
            require(wait_exited(late_pid, 5), "App outlived its expiry after runner death")
            require(alive(other_pid), "Unrelated invocation exited with the killed runner")

            (other / "shutdown").write_text(other_marker.upper())
            require(wait_exited(other_pid, 5), "Other invocation ignored its shutdown marker")
            print(f"early_launcher_exited_before_ready={str(early_before_ready).lower()}")
            print("abandoned_invocations_expired=passed other_invocation_preserved=passed")
        finally:
            for path, marker in controls.values():
                (path / "shutdown").write_text(marker.upper())
            for launcher in launchers:
                if launcher is not None and launcher.poll() is None:
                    try:
                        launcher.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        launcher.kill()
                        launcher.wait(timeout=2)


if __name__ == "__main__":
    target = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).parent / "dist/MGraphCapture.app"
    try:
        main(target)
    except (OSError, RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        sys.exit(str(error))
