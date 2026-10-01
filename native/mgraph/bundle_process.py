"""LaunchServices process ownership for local native checks.

Every invocation carries a UUID in the bundle command line. Cleanup only
targets that UUID, even if another M Graph instance was already running.
"""

import contextlib
import ctypes
import os
import pathlib
import signal
import subprocess
import time
import uuid


class _BSDInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid",
        "svuid", "svgid", "reserved")]
    _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in (
        "nfiles", "pgid", "pjobc", "tdev", "tpgid", "nice")]
    _fields_ += [("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64)]


_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
_libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                  ctypes.c_void_p, ctypes.c_int]
_libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
_known = {}


def process_identity(pid):
    """Kernel process path and birth time; never identify an invocation by PID alone."""
    info = _BSDInfo()
    size = _libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    path = ctypes.create_string_buffer(4096)
    length = _libproc.proc_pidpath(pid, path, len(path))
    if size != ctypes.sizeof(info) or length <= 0:
        return None
    return (os.fsdecode(path.value), info.start_sec, info.start_usec)


class LaunchInterrupted(Exception):
    """A signal interrupted a check while it owned a bundle invocation."""


def owned_pids(binary, invocation, timeout=1):
    supplied_binary = str(binary)
    binary = pathlib.Path(binary).resolve()
    output = subprocess.run(["ps", "-axo", "pid=,command="], check=True,
                            capture_output=True, text=True, timeout=timeout).stdout
    found = {}
    for line in output.splitlines():
        parts = line.strip().split(maxsplit=1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        command = parts[1]
        if not any(command.startswith(f"{path} ") for path in (supplied_binary, str(binary))) or \
                not command.endswith(f" --invocation-id {invocation}"):
            continue
        pid = int(parts[0])
        identity = process_identity(pid)
        if identity is not None and pathlib.Path(identity[0]).resolve() == binary:
            found[pid] = identity
    if found:
        _known.setdefault(invocation, {}).update(found)
    return set(found)


def _live_known(binary, invocation):
    return {pid for pid, identity in _known.get(invocation, {}).items()
            if identity == process_identity(pid) and pathlib.Path(identity[0]).resolve() == binary}


def is_owned(binary, invocation, pid):
    return pid in _live_known(pathlib.Path(binary).resolve(), invocation)


def terminate_owned(binary, invocation):
    supplied_binary = binary
    binary = pathlib.Path(binary).resolve()
    end = time.monotonic() + 5
    for sig in (signal.SIGTERM, signal.SIGKILL):
        while True:
            try:
                pids = owned_pids(supplied_binary, invocation,
                                  timeout=max(0.05, min(1, end - time.monotonic())))
                break
            except subprocess.TimeoutExpired:
                # A stalled process listing is unknown, not evidence of exit.
                pids = _live_known(binary, invocation)
                if pids:
                    break
                if time.monotonic() >= end:
                    raise RuntimeError("Could not establish owned bundle process identity for cleanup") from None
        if not pids:
            if not _live_known(binary, invocation):
                _known.pop(invocation, None)
                return
            pids = _live_known(binary, invocation)
        for pid in pids:
            if pid not in _live_known(binary, invocation):
                continue
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        phase_end = min(end, time.monotonic() + (1.5 if sig == signal.SIGTERM else 2.5))
        while time.monotonic() < phase_end:
            if not _live_known(binary, invocation):
                _known.pop(invocation, None)
                return
            time.sleep(min(0.1, max(0, phase_end - time.monotonic())))
    remaining = _live_known(binary, invocation)
    if remaining:
        raise RuntimeError(f"Owned bundle process did not exit: {remaining}")
    _known.pop(invocation, None)


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
        pids = owned_pids(binary, invocation, timeout=max(0.05, min(1, end - time.monotonic())))
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
    try:
        os.kill(pid, 0)
        exited = False
    except ProcessLookupError:
        exited = True
    if (result.returncode or result.stdout.strip() == "no-consent-alert") and exited:
        # Permission can be revoked between bundled status and capture. The
        # command exits before showing consent; let the caller inspect its
        # permissionRequired JSON instead of masking that transition.
        return
    if result.returncode or result.stdout.strip() != "approved":
        raise RuntimeError(f"CLI capture consent failed: {result.stderr.strip() or result.stdout.strip()}")
