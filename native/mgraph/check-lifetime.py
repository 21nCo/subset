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


def wait_identity(control, filename, binary, deadline):
    while time.monotonic() < deadline:
        try:
            pid = int((control / filename).read_text())
        except (OSError, ValueError):
            time.sleep(0.05)
            continue
        identity = process_identity(pid)
        if identity is not None and pathlib.Path(identity[0]).resolve() == binary:
            return (pid, identity)
        time.sleep(0.05)
    raise RuntimeError(f"{filename} PID did not identify the signed bundle before deadline")


def wait_ready(control, binary, deadline):
    return wait_identity(control, "ready", binary, deadline)


def exit_probe(pid, binary, expected):
    """Return confirmed exit and any identity learned from the ready file."""
    current = process_identity(pid)
    if current is not None:
        if expected is not None:
            return current != expected[1], expected
        if pathlib.Path(current[0]).resolve() != binary:
            return True, None
        return False, (pid, current)
    return pid_exists(pid) is False, expected


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
        exited, expected = exit_probe(pid, binary, expected)
        if exited:
            return True
        time.sleep(0.05)
    return False


def launch(bundle, control, marker, lifetime, *, wait, defer_ready=False):
    command = ["open", "-n"]
    if wait:
        command.append("-W")
    command += [str(bundle), "--args"]
    if defer_ready:
        command.append("--defer-ready")
    command += ["--shutdown-after", str(lifetime),
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

            fast, fast_marker = control("fast")
            launched.add("fast")
            launch(bundle, fast, fast_marker, 3, wait=False)
            identities["fast"] = wait_ready(fast, binary, time.monotonic() + 5)
            require(wait_exited(fast, binary, time.monotonic() + 5, identities["fast"]),
                    "Fast-ready app outlived its expiry")

            early, early_marker = control("early")
            launched.add("early")
            launch(bundle, early, early_marker, 3, wait=False, defer_ready=True)
            starting = wait_identity(early, "starting", binary, time.monotonic() + 5)
            require(not (early / "ready").exists(), "Deferred app published ready before launcher exit")
            (early / "release-ready").write_text(early_marker.upper())
            identities["early"] = wait_ready(early, binary, time.monotonic() + 5)
            require(identities["early"] == starting, "Deferred app identity changed before ready")
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
        print("early_launcher_exited_before_ready=true fast_ready=passed")
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
