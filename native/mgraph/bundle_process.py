"""LaunchServices process ownership for local native checks.

Every invocation carries a UUID in the bundle command line. Cleanup only
targets that UUID, even if another M Graph instance was already running.
"""

import contextlib
import os
import pathlib
import signal
import subprocess
import time
import uuid


class LaunchInterrupted(Exception):
    """A signal interrupted a check while it owned a bundle invocation."""


def owned_pids(binary, invocation):
    output = subprocess.run(["ps", "-axo", "pid=,command="], check=True,
                            capture_output=True, text=True, timeout=1).stdout
    return {
        int(parts[0]) for line in output.splitlines()
        if (parts := line.strip().split(maxsplit=1)) and len(parts) == 2
        and str(binary) in parts[1] and f"--invocation-id {invocation}" in parts[1]
    }


def terminate_owned(binary, invocation):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        pids = owned_pids(binary, invocation)
        if not pids:
            return
        for pid in pids:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        for _ in range(20):
            if not owned_pids(binary, invocation):
                return
            time.sleep(0.1)
    remaining = owned_pids(binary, invocation)
    if remaining:
        raise RuntimeError(f"Owned bundle process did not exit: {remaining}")


@contextlib.contextmanager
def launched_bundle(bundle, args=(), output=None, wait=True, timeout=20,
                    allowed_returncodes=(0,), before_wait=None):
    # Absolute paths cannot be parsed as options by open, even when a caller
    # supplied an option-shaped relative bundle or output path.
    bundle = pathlib.Path(bundle).resolve()
    binary = bundle / "Contents/MacOS/MGraphCapture"
    invocation = str(uuid.uuid4())
    command = ["open", "-n"]
    if wait:
        command.append("-W")
    if output is not None:
        command += ["-o", str(pathlib.Path(output).resolve())]
    command += [str(bundle), "--args", *args, "--invocation-id", invocation]
    previous_term_handler = signal.getsignal(signal.SIGTERM)

    def interrupt(_signum, _frame):
        raise LaunchInterrupted("Native check interrupted by SIGTERM")

    signal.signal(signal.SIGTERM, interrupt)
    launcher = None
    try:
        launcher = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if before_wait is not None:
            before_wait(invocation, binary)
        if wait:
            stdout, stderr = launcher.communicate(timeout=timeout)
            if launcher.returncode not in allowed_returncodes:
                raise subprocess.CalledProcessError(launcher.returncode, command, stdout, stderr)
        else:
            launcher.communicate(timeout=timeout)
            if launcher.returncode:
                raise subprocess.CalledProcessError(launcher.returncode, command)
        yield invocation
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        try:
            if launcher is not None and launcher.poll() is None:
                launcher.terminate()
                try:
                    launcher.communicate(timeout=2)
                except subprocess.TimeoutExpired:
                    launcher.kill()
                    launcher.communicate(timeout=2)
            terminate_owned(binary, invocation)
        finally:
            signal.signal(signal.SIGTERM, previous_term_handler)


def wait_for_owned_pid(bundle, invocation, timeout=5):
    binary = pathlib.Path(bundle) / "Contents/MacOS/MGraphCapture"
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        pids = owned_pids(binary, invocation)
        if len(pids) == 1:
            return next(iter(pids))
        if len(pids) > 1:
            raise RuntimeError(f"Expected one owned bundle process, got {pids}")
        time.sleep(0.1)
    raise TimeoutError("Owned bundle did not start")


def approve_cli_capture(invocation, binary):
    """Test runner's authorized System Events click for the one-time CLI prompt."""
    try:
        pid = wait_for_owned_pid(binary.parents[2], invocation)
    except TimeoutError:
        # A denied or revoked grant exits before presenting the prompt.
        # launched_bundle still checks the command and bundled_command its JSON.
        return
    script = f'''tell application "System Events" to tell (first process whose unix id is {pid})
    repeat 50 times
        if exists window 1 then
            if exists button "Allow Capture" of window 1 then
                click button "Allow Capture" of window 1
                return "approved"
            end if
        end if
        delay 0.1
    end repeat
    return "no-consent-alert"
end tell'''
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=10)
    if result.stdout.strip() == "no-consent-alert" and not owned_pids(binary, invocation):
        # Permission can be revoked between bundled status and capture. The
        # command exits before showing consent; let the caller inspect its
        # permissionRequired JSON instead of masking that transition.
        return
    if result.returncode or result.stdout.strip() != "approved":
        raise RuntimeError(f"CLI capture consent failed: {result.stderr.strip() or result.stdout.strip()}")
