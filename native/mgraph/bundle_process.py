"""LaunchServices process ownership for local native checks.

Every invocation carries a UUID in the bundle command line. Cleanup only
targets that UUID, even if another M Graph instance was already running.
"""

import contextlib
import ctypes
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
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
_controls = {}


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
    ready_pid = _ready_pid(binary, invocation)
    if ready_pid is not None:
        return {ready_pid}
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


def _ready_pid(binary, invocation):
    control = _controls.get(invocation)
    if control is None:
        return None
    try:
        pid = int((control / "ready").read_text())
    except (ValueError, OSError):
        return None
    identity = process_identity(pid)
    if identity is None or pathlib.Path(identity[0]).resolve() != pathlib.Path(binary).resolve():
        return None
    known = _known.setdefault(invocation, {})
    if pid in known and known[pid] != identity:
        return None
    known[pid] = identity
    return pid


def _owned_now(binary, invocation, deadline):
    known = _live_known(binary, invocation)
    if known or _known.get(invocation):
        return known
    ready = _ready_pid(binary, invocation)
    if ready is not None:
        return {ready}
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError("Could not establish owned bundle process identity for cleanup")
    try:
        return owned_pids(binary, invocation, timeout=min(1, max(0.05, remaining)))
    except subprocess.TimeoutExpired:
        return _live_known(binary, invocation)


def terminate_owned(binary, invocation, deadline=None):
    binary = pathlib.Path(binary).resolve()
    end = deadline if deadline is not None else time.monotonic() + 5
    control = _controls.get(invocation)
    if control is None:
        raise RuntimeError("Invocation shutdown channel unavailable")
    # The command is consumed only by this invocation. Never signal a bare PID:
    # a process can exit and its number can be reused after an identity check.
    (control / "shutdown").write_text(str(uuid.UUID(invocation)).upper())
    had_identity = bool(_known.get(invocation))
    while time.monotonic() < end:
        pids = _owned_now(binary, invocation, end)
        if pids:
            had_identity = True
        if had_identity and not pids:
            _known.pop(invocation, None)
            return
        time.sleep(min(0.05, max(0, end - time.monotonic())))
    if _live_known(binary, invocation):
        raise RuntimeError("Owned bundle process did not exit before cleanup deadline")
    if not had_identity:
        raise RuntimeError("Could not establish owned bundle process identity for cleanup")
    _known.pop(invocation, None)


def _stop_launcher(launcher, deadline):
    if launcher.poll() is not None:
        return
    launcher.terminate()
    try:
        launcher.communicate(timeout=max(0.05, min(1, deadline - time.monotonic())))
    except subprocess.TimeoutExpired:
        launcher.kill()
        launcher.communicate(timeout=max(0.05, min(1, deadline - time.monotonic())))


def _finish_invocation(launcher, completed_wait, binary, invocation, deadline):
    if launcher is None:
        return
    try:
        _stop_launcher(launcher, deadline)
    finally:
        if completed_wait:
            _known.pop(invocation, None)
        else:
            terminate_owned(binary, invocation, deadline=deadline)


@contextlib.contextmanager
def launched_bundle(bundle, args=(), output=None, wait=True, timeout=20,
                    allowed_returncodes=(0,), before_wait=None, lifetime=90):
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
    control_path = pathlib.Path(tempfile.mkdtemp(prefix="mgraph-invocation-"))
    _controls[invocation] = control_path
    command += [str(bundle), "--args", *args, "--shutdown-after", str(lifetime),
                "--shutdown-file", str(control_path / "shutdown"),
                "--invocation-id", invocation]
    previous_term_handler = signal.getsignal(signal.SIGTERM)

    def interrupt(_signum, _frame):
        raise LaunchInterrupted("Native check interrupted by SIGTERM")

    signal.signal(signal.SIGTERM, interrupt)
    launcher = None
    completed_wait = False
    try:
        launcher = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if before_wait is not None:
            before_wait(invocation, binary)
        if wait:
            stdout, stderr = launcher.communicate(timeout=timeout)
            completed_wait = True
            if launcher.returncode not in allowed_returncodes:
                raise subprocess.CalledProcessError(launcher.returncode, command, stdout, stderr)
        else:
            launcher.communicate(timeout=timeout)
            if launcher.returncode:
                raise subprocess.CalledProcessError(launcher.returncode, command)
            wait_for_owned_pid(bundle, invocation, timeout=min(timeout, 5))
        yield invocation
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        shutdown_end = time.monotonic() + 5
        cleanup_ok = False
        try:
            _finish_invocation(launcher, completed_wait, binary, invocation, shutdown_end)
            cleanup_ok = True
        finally:
            _controls.pop(invocation, None)
            if cleanup_ok:
                shutil.rmtree(control_path)
            # On an unproven exit, leave the shutdown marker in place so a
            # delayed LaunchServices start still exits its exact invocation.
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
                set promptText to (value of every static text of window 1) as text
                if promptText contains "{str(uuid.UUID(invocation)).upper()}" then
                    click button "Allow Capture" of window 1
                    return "approved"
                end if
            end if
        end if
        delay 0.1
    end repeat
    return "no-consent-alert"
end tell'''
    try:
        result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("CLI capture consent automation timed out") from error
    if result.returncode == 0 and result.stdout.strip() == "approved":
        # The invocation-labeled click is the authorization event. A fast
        # capture may have written its result and exited before this readback.
        return
    exited = not is_owned(binary, invocation, pid)
    if (result.returncode or result.stdout.strip() == "no-consent-alert") and exited:
        # Permission can be revoked between bundled status and capture. The
        # command exits before showing consent; let the caller inspect its
        # permissionRequired JSON instead of masking that transition.
        return
    if result.returncode or result.stdout.strip() != "approved":
        raise RuntimeError(f"CLI capture consent failed: {result.stderr.strip() or result.stdout.strip()}")
