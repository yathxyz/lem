#!/usr/bin/env python3
"""Deterministic subprocess used by compilation-test.sh."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path


def append(path: Path, line: str) -> None:
    with path.open("a", encoding="utf-8") as stream:
        stream.write(line + "\n")
        stream.flush()


def touch(path: Path) -> None:
    path.touch()


def wait_for(path: Path, timeout: float = 30.0) -> None:
    deadline = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() >= deadline:
            raise SystemExit(f"timed out waiting for {path}")
        time.sleep(0.02)


def wait_event(path: Path, marker: str, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while True:
        try:
            if marker in path.read_text(encoding="utf-8"):
                return
        except FileNotFoundError:
            pass
        if time.monotonic() >= deadline:
            raise SystemExit(f"timed out waiting for event {marker}")
        time.sleep(0.02)


def write(data: bytes) -> None:
    os.write(sys.stdout.fileno(), data)


def command_transport_memfd() -> str | None:
    """Return the guardian script descriptor target if one leaked here."""
    for name in os.listdir("/proc/self/fd"):
        try:
            target = os.readlink(f"/proc/self/fd/{name}")
        except (FileNotFoundError, PermissionError):
            continue
        if "memfd:lem-yath-compilation" in target:
            return target
    return None


def process_parent(pid: int) -> int | None:
    try:
        stat = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    except (FileNotFoundError, PermissionError):
        return None
    command_end = stat.rfind(")")
    fields = stat[command_end + 2 :].split()
    return int(fields[1]) if len(fields) > 1 else None


def guardian_process() -> int | None:
    pid = os.getppid()
    guardian = None
    while pid > 1:
        try:
            command = Path(f"/proc/{pid}/cmdline").read_bytes()
        except (FileNotFoundError, PermissionError):
            return guardian
        if b"compilation-guardian.py" in command:
            # The broker, watchdog, and in-group anchor retain the guardian
            # cmdline after fork.  Keep walking so the highest match is the
            # direct broker owned by Lem, not the command's immediate anchor.
            guardian = pid
        parent = process_parent(pid)
        if parent is None or parent == pid:
            return guardian
        pid = parent
    return guardian


def child_loop(events: Path, label: str, report_sigint: bool) -> subprocess.Popen[bytes]:
    program = r"""
import os, signal, sys, time
events, label, report = sys.argv[1], sys.argv[2], sys.argv[3] == "yes"
def log(text):
    with open(events, "a", encoding="utf-8") as stream:
        stream.write(text + "\n")
        stream.flush()
def on_sigint(_signal, _frame):
    if report:
        log(f"{label}-sigint pid={os.getpid()} pgid={os.getpgrp()}")
signal.signal(signal.SIGINT, on_sigint)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
log(f"{label}-start pid={os.getpid()} pgid={os.getpgrp()}")
while True:
    time.sleep(0.1)
"""
    return subprocess.Popen(
        [sys.executable, "-c", program, str(events), label,
         "yes" if report_sigint else "no"],
        stdin=subprocess.DEVNULL,
    )


def streaming_child(events: Path, label: str) -> subprocess.Popen[bytes]:
    """Write small bursts forever from a process outside the guardian group."""
    program = r"""
import os, sys, time
events, label = sys.argv[1], sys.argv[2]
def log(text):
    with open(events, "a", encoding="utf-8") as stream:
        stream.write(text + "\n")
        stream.flush()
log(f"{label}-start pid={os.getpid()} pgid={os.getpgrp()}")
while True:
    try:
        os.write(1, b".")
    except BrokenPipeError:
        log(f"{label}-broken-pipe")
        raise SystemExit(0)
    time.sleep(0.002)
"""
    return subprocess.Popen(
        [sys.executable, "-c", program, str(events), label],
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )


def primary(root: Path, events: Path) -> None:
    count_path = root / "primary.count"
    count = int(count_path.read_text(encoding="ascii") or "0") + 1 if count_path.exists() else 1
    count_path.write_text(str(count), encoding="ascii")
    append(events, f"primary-count={count}")
    write(f"LIVE-BEFORE-GATE run={count}\n".encode())
    touch(root / "primary.ready")
    wait_for(root / "primary.release")

    # Deliberately split a valid two-octet UTF-8 character across reads.
    write(b"UTF8-SPLIT-\xce")
    touch(root / "utf8.ready")
    wait_for(root / "utf8.release")
    write(b"\xbb\n")

    # Deliberately end a write in the middle of an SGR control sequence.
    write(b"\x1b[38;5;")
    append(events, "ansi-prefix-written")
    touch(root / "ansi.ready")
    wait_for(root / "ansi.release")

    write(b"196mANSI-SPLIT\x1b[0m\n")
    diagnostics = [
        f"{root / 'main.c'}:2:3: error: gcc-marker\n",
        f"{root / 'main.c'}:4:2: F401 ruff-marker\n",
        f"  --> {root / 'secondary.rs'}:3:5\n",
        f"{root / 'worker.go'}:4:2: go-marker\n",
        f"  File \"{root / 'test_sample.py'}\", line 5, in test_case\n",
        f"error: nix-marker at {root / 'default.nix'}:7:4\n",
    ]
    write("".join(diagnostics).encode())
    append(events, f"primary-finished={count}")


def interrupt(root: Path, events: Path) -> None:
    child = child_loop(events, "interrupt-child", True)
    append(events, f"interrupt-child={child.pid}")
    wait_event(events, "interrupt-child-start")

    def on_sigint(_signal: int, _frame: object) -> None:
        append(events, f"interrupt-parent-sigint pid={os.getpid()} pgid={os.getpgrp()}")
        os._exit(130)

    signal.signal(signal.SIGINT, on_sigint)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    write(b"INTERRUPT-RUNNING\n")
    touch(root / "interrupt.ready")
    while True:
        time.sleep(0.1)


def interrupt_leader_only(root: Path, events: Path) -> None:
    """Exit on SIGINT with no descendant to keep the old process group alive."""

    def on_sigint(_signal: int, _frame: object) -> None:
        append(
            events,
            f"leader-only-sigint pid={os.getpid()} pgid={os.getpgrp()}",
        )
        os._exit(130)

    signal.signal(signal.SIGINT, on_sigint)
    write(b"LEADER-ONLY-RUNNING\n")
    touch(root / "leader-only.ready")
    while True:
        time.sleep(0.1)


def default_interrupt(root: Path, events: Path) -> None:
    """Rely on the inherited SIGINT disposition without installing a handler."""
    disposition = signal.getsignal(signal.SIGINT)
    append(
        events,
        "default-interrupt-disposition="
        + ("ignored" if disposition == signal.SIG_IGN else "active"),
    )
    write(b"DEFAULT-INTERRUPT-RUNNING\n")
    touch(root / "default-interrupt.ready")
    while True:
        time.sleep(0.1)


def old(root: Path, events: Path) -> None:
    child = child_loop(events, "old-child", False)
    append(events, f"old-child={child.pid}")
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    write(b"OLD-RUNNING\n")
    touch(root / "old.ready")
    while True:
        time.sleep(0.1)


def fresh(root: Path, events: Path) -> None:
    write(b"FRESH-ONLY\n")
    write(f"{root / 'main.c'}:6:1: fresh-marker\n".encode())
    append(events, "fresh-finished")


def background(root: Path, events: Path) -> None:
    """Exit normally while a descendant keeps the inherited stdout open."""
    child = child_loop(events, "background-child", False)
    append(events, f"background-child={child.pid}")
    wait_event(events, "background-child-start")
    write(b"BACKGROUND-LEADER-FINISHED\n")
    touch(root / "background.ready")


def slow_background(root: Path, events: Path) -> None:
    """Exit while an escaped descendant continuously produces small bursts."""
    child = streaming_child(events, "slow-child")
    append(events, f"slow-child={child.pid}")
    wait_event(events, "slow-child-start")
    write(b"SLOW-BACKGROUND-LEADER-FINISHED\n")
    touch(root / "slow-background.ready")


def escaped_running(root: Path, events: Path) -> None:
    """Stay active with a continuously writing descendant in another group."""
    child = streaming_child(events, "escaped-child")
    append(events, f"escaped-child={child.pid}")
    wait_event(events, "escaped-child-start")
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    write(b"ESCAPED-RUNNING\n")
    touch(root / "escaped-running.ready")
    while True:
        time.sleep(0.1)


def kill_guardian(root: Path, events: Path, guardian: int | None) -> None:
    """Kill only the guardian; its out-of-group watchdog must clean up."""
    if guardian is None:
        raise SystemExit("guardian process is unavailable")
    write(b"KILL-GUARDIAN-READY\n")
    touch(root / "kill-guardian.ready")
    wait_for(root / "kill-guardian.release")
    os.kill(guardian, signal.SIGKILL)
    while True:
        time.sleep(0.1)


def stop_group(root: Path, events: Path) -> None:
    """Stop the command group without stopping the out-of-group guardian."""
    write(b"STOP-GROUP-READY\n")
    touch(root / "stop-group.ready")
    os.killpg(os.getpgrp(), signal.SIGSTOP)


def stop_parent(root: Path, events: Path) -> None:
    """Stop the immediate parent without stopping the out-of-group broker."""
    parent = os.getppid()
    append(events, f"stop-parent-target={parent}")
    write(b"STOP-PARENT-READY\n")
    touch(root / "stop-parent.ready")
    os.kill(parent, signal.SIGSTOP)
    while True:
        time.sleep(0.1)


def startup_gate(root: Path, events: Path) -> None:
    """Remain live after BASH_ENV stops the parent before this script runs."""
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    append(events, "startup-gate-body")
    write(b"STARTUP-GATE-BODY\n")
    touch(root / "startup-gate.ready")
    while True:
        time.sleep(0.1)


def partial_utf8(root: Path, events: Path) -> None:
    """Exit after an incomplete code point while a child retains stdout."""
    child = child_loop(events, "partial-child", False)
    append(events, f"partial-child={child.pid}")
    wait_event(events, "partial-child-start")
    write(b"PARTIAL-UTF8-BEFORE\n\xe2")
    touch(root / "partial.ready")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: fake-compiler.py MODE ROOT", file=sys.stderr)
        return 2
    mode = sys.argv[1]
    root = Path(sys.argv[2]).resolve()
    events = root / "events"
    guardian = guardian_process()
    leaked_transport = command_transport_memfd()
    append(
        events,
        "command-transport-memfd="
        + (leaked_transport if leaked_transport is not None else "absent"),
    )
    if leaked_transport is not None:
        print("guardian command transport leaked into a descendant", file=sys.stderr)
        return 70
    append(
        events,
        " ".join(
            [
                f"start mode={mode}",
                f"pid={os.getpid()}",
                f"pgid={os.getpgrp()}",
                f"guardian={guardian if guardian is not None else '<missing>'}",
                f"cwd={os.getcwd()}",
                f"sentinel={os.environ.get('LEM_YATH_COMPILATION_SENTINEL', '<missing>')}",
                f"option-name={os.environ.get('--help', '<missing>')}",
            ]
        ),
    )
    if mode == "primary":
        primary(root, events)
    elif mode == "interrupt":
        interrupt(root, events)
    elif mode == "leader-only":
        interrupt_leader_only(root, events)
    elif mode == "default-interrupt":
        default_interrupt(root, events)
    elif mode == "old":
        old(root, events)
    elif mode == "fresh":
        fresh(root, events)
    elif mode == "background":
        background(root, events)
    elif mode == "slow-background":
        slow_background(root, events)
    elif mode == "escaped-running":
        escaped_running(root, events)
    elif mode == "kill-guardian":
        kill_guardian(root, events, guardian)
    elif mode == "stop-group":
        stop_group(root, events)
    elif mode == "stop-parent":
        stop_parent(root, events)
    elif mode == "startup-gate":
        startup_gate(root, events)
    elif mode == "partial":
        partial_utf8(root, events)
    else:
        print(f"unknown mode: {mode}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
