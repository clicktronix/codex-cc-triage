#!/usr/bin/env python3
"""Focused failure-path tests for the portable timeout runner."""

from __future__ import annotations

import argparse
import importlib.util
import signal
import subprocess
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from typing import Optional
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
RUNNER_PATH = ROOT / "plugins" / "codex-cc-triage" / "scripts" / "run_with_timeout.py"
SPEC = importlib.util.spec_from_file_location("run_with_timeout", RUNNER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load timeout runner")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class FakeProcess:
    pid = 4242

    def __init__(self) -> None:
        self.returncode = None
        self.killed = False

    def poll(self) -> Optional[int]:
        return self.returncode

    def kill(self) -> None:
        self.killed = True
        self.returncode = -signal.SIGKILL

    def wait(self, timeout: Optional[float] = None) -> int:
        del timeout
        return self.returncode or 0


class TimeoutProcess(FakeProcess):
    def communicate(self, _prompt: bytes, timeout: int) -> None:
        raise subprocess.TimeoutExpired("claude", timeout)


class TimeoutRunnerTests(unittest.TestCase):
    def test_transient_permission_error_is_retried(self) -> None:
        process = FakeProcess()
        calls = 0

        def fake_killpg(_pid: int, signum: int) -> None:
            nonlocal calls
            if signum == 0:
                raise ProcessLookupError
            calls += 1
            if calls == 1:
                raise PermissionError(1, "Operation not permitted")

        with ExitStack() as stack:
            stack.enter_context(
                mock.patch.object(RUNNER.os, "killpg", side_effect=fake_killpg)
            )
            stack.enter_context(mock.patch.object(RUNNER.time, "sleep"))
            RUNNER.terminate_process_group(process)

        self.assertGreaterEqual(calls, 2)

    def test_persistent_permission_error_is_not_reported_as_success(self) -> None:
        process = FakeProcess()
        denied = PermissionError(1, "Operation not permitted")

        with ExitStack() as stack:
            stack.enter_context(
                mock.patch.object(RUNNER.os, "killpg", side_effect=denied)
            )
            stack.enter_context(
                mock.patch.object(RUNNER, "TERMINATION_GRACE_SECONDS", 0)
            )
            stack.enter_context(mock.patch.object(RUNNER, "GROUP_VERIFY_SECONDS", 0))
            stack.enter_context(mock.patch.object(RUNNER, "SIGNAL_RETRY_SECONDS", 0))
            with self.assertRaises(RUNNER.ProcessGroupTerminationError):
                RUNNER.terminate_process_group(process)

        self.assertTrue(process.killed)

    def test_timeout_cleanup_failure_has_distinct_status(self) -> None:
        process = TimeoutProcess()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = argparse.Namespace(
                timeout=1,
                stdout=root / "stdout",
                stderr=root / "stderr",
                status=root / "status",
                command=["claude", "-p"],
            )
            with ExitStack() as stack:
                stack.enter_context(
                    mock.patch.object(RUNNER, "parse_args", return_value=args)
                )
                stack.enter_context(
                    mock.patch.object(RUNNER.subprocess, "Popen", return_value=process)
                )
                stack.enter_context(
                    mock.patch.object(
                        RUNNER,
                        "terminate_process_group",
                        side_effect=RUNNER.ProcessGroupTerminationError("denied"),
                    )
                )
                stack.enter_context(
                    mock.patch.object(RUNNER, "ignore_termination_signals")
                )
                stack.enter_context(
                    mock.patch.object(
                        RUNNER.signal, "pthread_sigmask", return_value=set()
                    )
                )
                stack.enter_context(mock.patch.object(RUNNER.signal, "signal"))
                rc = RUNNER.main()

            self.assertEqual(rc, 125)
            self.assertEqual(
                args.status.read_text(encoding="utf-8"), "termination-failed\n"
            )
            self.assertIn(
                "timeout cleanup failed", args.stderr.read_text(encoding="utf-8")
            )


if __name__ == "__main__":
    unittest.main()
