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


class TerminationRequested(Exception):
    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


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


def terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait()
        return

    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        process.poll()
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            process.wait()
            return
        time.sleep(0.05)

    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def ignore_termination_signals() -> None:
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)


def main() -> int:
    args = parse_args()
    prompt = sys.stdin.buffer.read()
    process: subprocess.Popen[bytes] | None = None
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
                    )
                finally:
                    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

                process.communicate(prompt, timeout=args.timeout)
            except subprocess.TimeoutExpired:
                ignore_termination_signals()
                if process is not None:
                    terminate_process_group(process)
                args.status.write_text("timeout\n", encoding="utf-8")
                stderr.write(
                    f"codex-cc-triage: Claude timed out after {args.timeout} seconds\n".encode()
                )
                return 124
            except TerminationRequested as error:
                ignore_termination_signals()
                if process is not None:
                    terminate_process_group(process)
                return 128 + error.signum
            except OSError as error:
                ignore_termination_signals()
                if process is not None:
                    terminate_process_group(process)
                stderr.write(f"codex-cc-triage: cannot run Claude: {error}\n".encode())
                return 127
    except OSError as error:
        print(f"codex-cc-triage: timeout runner failed: {error}", file=sys.stderr)
        return 127

    if process is None:
        return 127
    if process.returncode < 0:
        return min(255, 128 - process.returncode)
    return process.returncode


if __name__ == "__main__":
    raise SystemExit(main())
