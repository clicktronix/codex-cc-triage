#!/usr/bin/env python3
"""Run Claude print mode with a portable wall-clock timeout."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional


TERMINATION_GRACE_SECONDS = 5.0
GROUP_VERIFY_SECONDS = 1.0
SIGNAL_RETRY_SECONDS = 0.05


class TerminationRequested(Exception):
    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


class ProcessGroupTerminationError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, required=True)
    parser.add_argument("--stdout", type=Path, required=True)
    parser.add_argument("--stderr", type=Path, required=True)
    parser.add_argument("--status", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if not args.command:
        parser.error("a command is required after --")
    return args


def signal_process_group(pid: int, signum: int) -> Optional[PermissionError]:
    """Signal a process group, retrying transient macOS permission races."""
    last_error: Optional[PermissionError] = None
    for _attempt in range(3):
        try:
            os.killpg(pid, signum)
            return None
        except ProcessLookupError:
            return None
        except PermissionError as error:
            last_error = error
            time.sleep(SIGNAL_RETRY_SECONDS)
    return last_error


def process_group_exists(pid: int) -> bool:
    try:
        os.killpg(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # EPERM still proves that the group exists; it does not prove cleanup.
        return True
    return True


def terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    term_error = signal_process_group(process.pid, signal.SIGTERM)
    deadline = time.monotonic() + TERMINATION_GRACE_SECONDS
    while time.monotonic() < deadline:
        process.poll()
        if not process_group_exists(process.pid):
            process.wait()
            return
        if term_error is not None:
            term_error = signal_process_group(process.pid, signal.SIGTERM)
        time.sleep(SIGNAL_RETRY_SECONDS)

    kill_error = signal_process_group(process.pid, signal.SIGKILL)
    if kill_error is not None and process.poll() is None:
        try:
            process.kill()
        except ProcessLookupError:
            pass
        except OSError as error:
            raise ProcessGroupTerminationError(
                f"cannot signal Claude process or group: {error}"
            ) from error

    try:
        process.wait(timeout=TERMINATION_GRACE_SECONDS)
    except subprocess.TimeoutExpired as error:
        raise ProcessGroupTerminationError(
            "Claude process did not exit after SIGKILL"
        ) from error

    verify_deadline = time.monotonic() + GROUP_VERIFY_SECONDS
    while time.monotonic() < verify_deadline:
        if not process_group_exists(process.pid):
            return
        if kill_error is not None:
            kill_error = signal_process_group(process.pid, signal.SIGKILL)
        time.sleep(SIGNAL_RETRY_SECONDS)

    if process_group_exists(process.pid):
        detail = f": {kill_error}" if kill_error is not None else ""
        raise ProcessGroupTerminationError(
            f"could not confirm termination of Claude process group{detail}"
        )


def append_diagnostic(path: Path, message: str) -> None:
    try:
        with path.open("ab") as output:
            output.write(f"codex-cc-triage: {message}\n".encode())
    except OSError:
        print(f"codex-cc-triage: {message}", file=sys.stderr)


def ignore_termination_signals() -> None:
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)


def main() -> int:
    args = parse_args()
    prompt = sys.stdin.buffer.read()
    process: Optional[subprocess.Popen[bytes]] = None
    termination_signals = {signal.SIGHUP, signal.SIGINT, signal.SIGTERM}
    try:
        with args.stdout.open("wb") as stdout, args.stderr.open("wb") as stderr:

            def request_termination(signum: int, _frame: object) -> None:
                raise TerminationRequested(signum)

            previous_mask = signal.pthread_sigmask(
                signal.SIG_BLOCK, termination_signals
            )
            try:
                try:
                    for signum in termination_signals:
                        signal.signal(signum, request_termination)
                    process = subprocess.Popen(
                        args.command,
                        stdin=subprocess.PIPE,
                        stdout=stdout,
                        stderr=stderr,
                        start_new_session=True,
                        preexec_fn=lambda: signal.pthread_sigmask(
                            signal.SIG_SETMASK, previous_mask
                        ),
                    )
                finally:
                    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

                process.communicate(prompt, timeout=args.timeout)
            except subprocess.TimeoutExpired:
                ignore_termination_signals()
                try:
                    if process is not None:
                        terminate_process_group(process)
                except ProcessGroupTerminationError as error:
                    args.status.write_text("termination-failed\n", encoding="utf-8")
                    stderr.write(
                        f"codex-cc-triage: timeout cleanup failed: {error}\n".encode()
                    )
                    return 125
                args.status.write_text("timeout\n", encoding="utf-8")
                stderr.write(
                    f"codex-cc-triage: Claude timed out after {args.timeout} seconds\n".encode()
                )
                return 124
            except TerminationRequested as error:
                ignore_termination_signals()
                try:
                    if process is not None:
                        terminate_process_group(process)
                except ProcessGroupTerminationError as cleanup_error:
                    args.status.write_text("termination-failed\n", encoding="utf-8")
                    stderr.write(
                        f"codex-cc-triage: signal cleanup failed: {cleanup_error}\n".encode()
                    )
                    return 125
                return 128 + error.signum
            except OSError as error:
                ignore_termination_signals()
                try:
                    if process is not None:
                        terminate_process_group(process)
                except ProcessGroupTerminationError as cleanup_error:
                    stderr.write(
                        f"codex-cc-triage: cleanup also failed: {cleanup_error}\n".encode()
                    )
                stderr.write(f"codex-cc-triage: cannot run Claude: {error}\n".encode())
                return 127
    except OSError as error:
        append_diagnostic(args.stderr, f"timeout runner failed: {error}")
        return 127

    if process is None:
        return 127
    if process.returncode < 0:
        return min(255, 128 - process.returncode)
    return process.returncode


if __name__ == "__main__":
    raise SystemExit(main())
