#!/usr/bin/env python3
"""Private process-group guardian for Lem compilation sessions."""

from __future__ import annotations

import fcntl
import os
import select
import signal
import struct
import sys
from collections.abc import Mapping


ENVIRONMENT_MAGIC = b"LEMENV1\0"
MAX_ENVIRONMENT_ENTRIES = 65_536
MAX_ENVIRONMENT_BYTES = 16 * 1024 * 1024
MAX_COMMAND_BYTES = 1024 * 1024
MAX_CONTROL_LINE = 64


class ProtocolError(Exception):
    pass


def read_exact(size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = os.read(0, size - len(chunks))
        if not chunk:
            raise ProtocolError("control stream closed")
        chunks.extend(chunk)
    return bytes(chunks)


def read_uint32() -> int:
    return struct.unpack("!I", read_exact(4))[0]


def read_environment() -> Mapping[bytes, bytes]:
    if read_exact(len(ENVIRONMENT_MAGIC)) != ENVIRONMENT_MAGIC:
        raise ProtocolError("invalid environment frame")
    count = read_uint32()
    if count > MAX_ENVIRONMENT_ENTRIES:
        raise ProtocolError("too many environment entries")

    environment: dict[bytes, bytes] = {}
    total = 0
    for _ in range(count):
        length = read_uint32()
        total += length
        if total > MAX_ENVIRONMENT_BYTES:
            raise ProtocolError("environment frame is too large")
        entry = read_exact(length)
        if b"\0" in entry or b"=" not in entry:
            raise ProtocolError("invalid environment entry")
        name, value = entry.split(b"=", 1)
        if not name or name in environment:
            raise ProtocolError("invalid or repeated environment name")
        environment[name] = value
    return environment


def read_command() -> bytes:
    length = read_uint32()
    if length > MAX_COMMAND_BYTES:
        raise ProtocolError("compilation command is too large")
    command = read_exact(length)
    if b"\0" in command:
        raise ProtocolError("compilation command contains NUL")
    command.decode("utf-8")
    return command


class ControlReader:
    def __init__(self, fd: int, description: str) -> None:
        self.fd = fd
        self.description = description
        self.buffer = bytearray()

    def read_line(self, timeout: float | None) -> bytes | None:
        while True:
            newline = self.buffer.find(b"\n")
            if newline >= 0:
                if newline > MAX_CONTROL_LINE:
                    raise ProtocolError("control line is too long")
                line = bytes(self.buffer[:newline])
                del self.buffer[: newline + 1]
                return line
            if len(self.buffer) > MAX_CONTROL_LINE:
                raise ProtocolError("control line is too long")
            ready, _, _ = select.select([self.fd], [], [], timeout)
            if not ready:
                return None
            chunk = os.read(self.fd, 4096)
            if not chunk:
                raise ProtocolError(f"{self.description} stream closed")
            self.buffer.extend(chunk)


def write_status(line: bytes) -> None:
    os.write(2, line + b"\n")


def normalize_wait_status(wait_status: int) -> int:
    if os.WIFEXITED(wait_status):
        return os.WEXITSTATUS(wait_status)
    if os.WIFSIGNALED(wait_status):
        return 128 + os.WTERMSIG(wait_status)
    return 125


def keep_guardian_alive(_signum: int, _frame: object) -> None:
    return


def signal_group(pgid: int, signum: int) -> None:
    os.killpg(pgid, signum)


def replace_stdio_with_null() -> None:
    null_fd = os.open(os.devnull, os.O_RDWR)
    for target_fd in (0, 1, 2):
        os.dup2(null_fd, target_fd)
    if null_fd > 2:
        os.close(null_fd)


def replace_fd_with_null(target_fd: int) -> None:
    null_fd = os.open(os.devnull, os.O_RDWR)
    try:
        os.dup2(null_fd, target_fd)
    finally:
        if null_fd != target_fd:
            os.close(null_fd)


def close_fds_except(allowed: set[int]) -> None:
    for name in os.listdir("/proc/self/fd"):
        try:
            fd = int(name)
        except ValueError:
            continue
        if fd in allowed:
            continue
        try:
            os.close(fd)
        except OSError:
            pass


def read_fd_exact(fd: int, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = os.read(fd, size - len(data))
        if not chunk:
            raise ProtocolError("watchdog stream closed")
        data.extend(chunk)
    return bytes(data)


def write_fd_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def write_fd_line(fd: int, line: bytes) -> None:
    write_fd_all(fd, line + b"\n")


def run_gated_bash(
    ready_fd: int,
    start_fd: int,
    status_fd: int,
    script_fd: int,
    bash: str,
    environment: Mapping[bytes, bytes],
) -> None:
    """Wait until STARTED is queued, then replace this child with Bash."""
    try:
        os.close(status_fd)
        restored_signals = [
            signal.SIGINT,
            signal.SIGQUIT,
            signal.SIGTERM,
            signal.SIGHUP,
            signal.SIGPIPE,
        ]
        for name in ("SIGXFZ", "SIGXFSZ"):
            signum = getattr(signal, name, None)
            if signum is not None:
                restored_signals.append(signum)
        for signum in restored_signals:
            signal.signal(signum, signal.SIG_DFL)
        replace_fd_with_null(0)
        os.dup2(1, 2)
        os.set_inheritable(script_fd, True)
        write_fd_all(ready_fd, b"R")
        os.close(ready_fd)
        read_fd_exact(start_fd, 1)
        os.close(start_fd)
        close_fds_except({0, 1, 2, script_fd})
        os.execve(
            bash,
            [bash, "--noprofile", "--norc", f"/proc/self/fd/{script_fd}"],
            environment,
        )
    except BaseException:
        os._exit(126)


def run_command_anchor(
    status_fd: int,
    ready_fd: int,
    start_fd: int,
    bash: str,
    environment: Mapping[bytes, bytes],
    command: bytes,
) -> None:
    """Own the command group and directly parent its Bash process."""
    try:
        os.setpgid(0, 0)
        write_fd_all(ready_fd, b"R")
    except OSError:
        os._exit(125)
    finally:
        os.close(ready_fd)
    try:
        read_fd_exact(start_fd, 1)
    except (OSError, ProtocolError):
        os._exit(125)
    finally:
        os.close(start_fd)

    script_fd = -1
    command_pid: int | None = None
    command_start_write = -1
    try:
        script_fd = command_file(command)
        command_ready_read, command_ready_write = os.pipe()
        command_start_read, command_start_write = os.pipe()
        command_pid = os.fork()
        if command_pid == 0:
            os.close(command_ready_read)
            os.close(command_start_write)
            run_gated_bash(
                command_ready_write,
                command_start_read,
                status_fd,
                script_fd,
                bash,
                environment,
            )
            os._exit(126)
        os.close(command_ready_write)
        os.close(command_start_read)
        read_fd_exact(command_ready_read, 1)
        os.close(command_ready_read)
    except (OSError, ProtocolError, ValueError) as error:
        try:
            write_fd_line(status_fd, f"ERROR {type(error).__name__}".encode("ascii"))
        except OSError:
            pass
        if command_pid is not None:
            try:
                os.kill(command_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(command_pid, 0)
            except (ChildProcessError, OSError):
                pass
        os._exit(125)
    finally:
        if script_fd >= 0:
            os.close(script_fd)

    # The gated child already owns the original output descriptor.  Queue
    # STARTED before allowing it to exec Bash: even a BASH_ENV that immediately
    # stops its parent or process group cannot block Lem's startup handshake.
    replace_stdio_with_null()
    try:
        write_fd_line(status_fd, f"STARTED {os.getpid()}".encode("ascii"))
        write_fd_all(command_start_write, b"S")
        os.close(command_start_write)
        command_start_write = -1
        waited_pid, wait_status = os.waitpid(command_pid, 0)
        if waited_pid != command_pid:
            raise ProtocolError("waited for the wrong command process")
        status = normalize_wait_status(wait_status)
        write_fd_line(status_fd, f"EXIT {status}".encode("ascii"))
        # Staying alive reserves the PGID until the broker explicitly releases
        # the watchdog.  All externally delivered group signals use handlers
        # inherited from the broker, except SIGKILL and SIGSTOP as intended.
        while True:
            signal.pause()
    except OSError:
        os._exit(125)


def run_watchdog(
    heartbeat_read: int,
    status_write: int,
    bash: str,
    environment: Mapping[bytes, bytes],
    command: bytes,
) -> None:
    """Pin one anchor until the broker releases or loses its heartbeat."""
    anchor_pid: int | None = None
    group_ready = False
    anchor_announced = False
    anchor_start_write = -1
    try:
        os.setpgid(0, 0)
        anchor_ready_read, anchor_ready_write = os.pipe()
        anchor_start_read, anchor_start_write = os.pipe()
        anchor_pid = os.fork()
        if anchor_pid == 0:
            os.close(heartbeat_read)
            os.close(anchor_ready_read)
            os.close(anchor_start_write)
            try:
                run_command_anchor(
                    status_write,
                    anchor_ready_write,
                    anchor_start_read,
                    bash,
                    environment,
                    command,
                )
            except BaseException as error:
                try:
                    write_fd_line(
                        status_write,
                        f"ERROR {type(error).__name__}".encode("ascii"),
                    )
                except OSError:
                    pass
            os._exit(125)

        os.close(anchor_ready_write)
        os.close(anchor_start_read)
        read_fd_exact(anchor_ready_read, 1)
        os.close(anchor_ready_read)
        group_ready = True
        # The broker sees the PGID only after this watchdog has committed to
        # retaining the anchor.  A second gate prevents STARTED overtaking it.
        write_fd_line(status_write, f"ANCHOR {anchor_pid}".encode("ascii"))
        anchor_announced = True
        write_fd_all(anchor_start_write, b"S")
        os.close(anchor_start_write)
        anchor_start_write = -1
        os.close(status_write)
        status_write = -1
        replace_stdio_with_null()
        try:
            normal_release = os.read(heartbeat_read, 1) == b"R"
        except OSError:
            normal_release = False
        os.close(heartbeat_read)
        heartbeat_read = -1
        try:
            if normal_release:
                os.kill(anchor_pid, signal.SIGKILL)
            else:
                signal_group(anchor_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(anchor_pid, 0)
        anchor_pid = None
    except BaseException as error:
        if anchor_start_write >= 0:
            try:
                os.close(anchor_start_write)
            except OSError:
                pass
        if anchor_announced:
            # The broker may now cache this numeric identity.  Keep the anchor
            # unreaped until its heartbeat closes, then fail closed as a group.
            if status_write >= 0:
                try:
                    os.close(status_write)
                except OSError:
                    pass
            try:
                replace_stdio_with_null()
            except OSError:
                for fd in (0, 1, 2):
                    try:
                        os.close(fd)
                    except OSError:
                        pass
            if heartbeat_read >= 0:
                try:
                    os.read(heartbeat_read, 1)
                except OSError:
                    pass
        elif status_write >= 0:
            try:
                write_fd_line(
                    status_write,
                    f"ERROR {type(error).__name__}".encode("ascii"),
                )
            except OSError:
                pass
        if anchor_pid is not None:
            try:
                if group_ready:
                    signal_group(anchor_pid, signal.SIGKILL)
                else:
                    os.kill(anchor_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(anchor_pid, 0)
            except (ChildProcessError, OSError):
                pass


def start_command_watchdog(
    bash: str,
    environment: Mapping[bytes, bytes],
    command: bytes,
) -> tuple[int, int, int]:
    """Start an out-of-group watchdog and its command-group anchor."""
    heartbeat_read, heartbeat_write = os.pipe()
    status_read, status_write = os.pipe()
    try:
        watchdog_pid = os.fork()
    except BaseException:
        os.close(heartbeat_read)
        os.close(heartbeat_write)
        os.close(status_read)
        os.close(status_write)
        raise
    if watchdog_pid != 0:
        os.close(heartbeat_read)
        os.close(status_write)
        return watchdog_pid, heartbeat_write, status_read

    # No forked helper is allowed to emit the broker-to-Lem protocol.  Keep
    # descriptor 2 occupied so anonymous command files cannot collide with the
    # stderr-to-stdout setup performed for Bash.
    try:
        replace_fd_with_null(2)
    except OSError:
        try:
            os.close(2)
        except OSError:
            pass
    try:
        os.close(heartbeat_write)
        os.close(status_read)
        run_watchdog(heartbeat_read, status_write, bash, environment, command)
    except BaseException:
        pass
    os._exit(0)


def finish_watchdog(pid: int, write_fd: int, normal_release: bool) -> None:
    write_error: OSError | None = None
    try:
        if normal_release:
            os.write(write_fd, b"R")
    except OSError as error:
        write_error = error
    finally:
        os.close(write_fd)
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        if write_error is None:
            raise
    if write_error is not None:
        raise write_error


def release_watchdog(pid: int, write_fd: int) -> None:
    finish_watchdog(pid, write_fd, True)


def abort_watchdog(pid: int, write_fd: int) -> None:
    # EOF is the fail-closed path: the watchdog repeats group SIGKILL before
    # reaping its anchor.  Only a post-EXIT RELEASE sends the normal marker.
    finish_watchdog(pid, write_fd, False)


def terminate_command_group(
    command_pgid: int,
    watchdog_pid: int,
    watchdog_fd: int,
) -> int:
    try:
        signal_group(command_pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    abort_watchdog(watchdog_pid, watchdog_fd)
    return 137


def command_file(command: bytes) -> int:
    if not hasattr(os, "memfd_create"):
        raise ProtocolError("anonymous command files are unavailable")
    fd = os.memfd_create("lem-yath-compilation", os.MFD_CLOEXEC)
    try:
        if fd < 3:
            replacement = fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 3)
            os.close(fd)
            fd = replacement
        # Bash opens the script on its own descriptor before reading it.  Close
        # the inherited transport descriptor in the first script line so
        # ordinary command descendants cannot retain the anonymous file.
        payload = f"exec {fd}<&-\n".encode("ascii") + command
        view = memoryview(payload)
        while view:
            written = os.write(fd, view)
            view = view[written:]
        os.lseek(fd, 0, os.SEEK_SET)
        return fd
    except BaseException:
        os.close(fd)
        raise


def require_line(reader: ControlReader, expected: bytes) -> None:
    line = reader.read_line(None)
    if line != expected:
        raise ProtocolError(f"expected {expected!r}")


def run() -> int:
    if len(sys.argv) != 2:
        raise ProtocolError("guardian requires one Bash argument")
    bash = sys.argv[1]

    for signum in (signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, keep_guardian_alive)

    write_status(b"READY")
    environment = read_environment()
    command = read_command()
    write_status(b"ENV")
    reader = ControlReader(0, "control")
    require_line(reader, b"START")

    watchdog_pid, watchdog_fd, status_fd = start_command_watchdog(
        bash, environment, command
    )
    watchdog_active = True
    command_pgid: int | None = None
    status_reader = ControlReader(status_fd, "command status")
    try:
        anchor = status_reader.read_line(None)
        if anchor is None or not anchor.startswith(b"ANCHOR "):
            raise ProtocolError("command anchor did not establish its group")
        command_pgid = int(anchor.removeprefix(b"ANCHOR "))
        if command_pgid <= 1:
            raise ProtocolError("invalid command process group")
        started = status_reader.read_line(None)
        if started is None or not started.startswith(b"STARTED "):
            raise ProtocolError("command anchor did not start Bash")
        if int(started.removeprefix(b"STARTED ")) != command_pgid:
            raise ProtocolError("command anchor changed identity")
        write_status(b"STARTED")

        status: int | None = None
        while status is None:
            command_line = status_reader.read_line(0.02)
            if command_line is not None:
                if not command_line.startswith(b"EXIT "):
                    raise ProtocolError("invalid command status")
                status = int(command_line.removeprefix(b"EXIT "))
                if status < 0 or status > 255:
                    raise ProtocolError("invalid command exit status")
                break
            line = reader.read_line(0)
            if line is None:
                continue
            if line == b"INT":
                signal_group(command_pgid, signal.SIGINT)
            elif line == b"KILL":
                status = terminate_command_group(
                    command_pgid, watchdog_pid, watchdog_fd
                )
                watchdog_active = False
                return status
            else:
                raise ProtocolError("invalid command while child is running")

        write_status(f"EXIT {status}".encode("ascii"))
        while True:
            line = reader.read_line(None)
            if line == b"RELEASE":
                release_watchdog(watchdog_pid, watchdog_fd)
                watchdog_active = False
                return status
            if line == b"INT":
                continue
            if line == b"KILL":
                status = terminate_command_group(
                    command_pgid, watchdog_pid, watchdog_fd
                )
                watchdog_active = False
                return status
            raise ProtocolError("invalid command after child exit")
    except BaseException:
        if watchdog_active:
            try:
                if command_pgid is not None:
                    signal_group(command_pgid, signal.SIGKILL)
                abort_watchdog(watchdog_pid, watchdog_fd)
            except (ChildProcessError, OSError):
                pass
        raise
    finally:
        os.close(status_fd)


def main() -> int:
    try:
        return run()
    except (OSError, ProtocolError, ValueError) as error:
        try:
            write_status(f"ERROR {type(error).__name__}".encode("ascii"))
        except OSError:
            pass
        return 125


if __name__ == "__main__":
    raise SystemExit(main())
