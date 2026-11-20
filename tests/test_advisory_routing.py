"""Exercise the public advisory bridge without network or a model account."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "plugins/codex-cc-triage/scripts"
DRIVER = SCRIPTS / "claude-thread.sh"


class AdvisoryRouting(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name).resolve()
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        self.args_log = self.tmp / "args"
        self.prompt_log = self.tmp / "prompt"
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("CODEX_CC_TRIAGE_", "FAKE_CLAUDE_"))}
        self.env.update(
            CODEX_CC_TRIAGE_CLAUDE_BIN=str(ROOT / "tests/fixtures/fake-claude.sh"),
            FAKE_CLAUDE_ARGS_LOG=str(self.args_log), FAKE_CLAUDE_PROMPT_LOG=str(self.prompt_log),
            XDG_STATE_HOME=str(self.tmp / "xdg"), TMPDIR=str(self.tmp),
        )
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "test")
        self.git("config", "user.email", "test@example.invalid")
        (self.repo / "spec.md").write_text("Subject\n")
        self.git("add", "spec.md")
        self.git("commit", "-qm", "baseline")

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True)

    def call(self, *args, cwd=None, prompt="", script=DRIVER, env=None, rc=0):
        result = subprocess.run(
            ["bash", script, *args], input=prompt, capture_output=True, text=True,
            timeout=20, cwd=cwd or self.repo, env=env or self.env,
        )
        self.assertEqual(result.returncode, rc, result)
        return result

    def state(self, cwd=None):
        return Path(self.call("--read-only", script=SCRIPTS / "state-dir.sh", cwd=cwd).stdout.strip())

    def test_oneshot_isolated_from_reserved_name_and_no_claude_session(self):
        self.call("begin", "topic", "--base", "HEAD", "--spec", "spec.md",
                  script=SCRIPTS / "review-state.sh")
        state = self.state()
        before = {p.name: p.read_bytes() for p in state.iterdir() if p.is_file()}
        output = self.call("dispatch", "review", "topic", "HEAD", "--oneshot", prompt="review")
        self.assertEqual(output.stdout, "FAKE_INITIAL")
        args = self.args_log.read_text().splitlines()
        self.assertIn("--no-session-persistence", args)
        self.assertNotIn("--name", args)
        self.assertNotIn("--resume", args)
        self.assertIn("# codex-cc-triage review context", self.prompt_log.read_text())
        self.assertEqual(before, {p.name: p.read_bytes() for p in state.iterdir() if p.is_file()})
        self.assertEqual(list(self.tmp.glob("codex-cc-oneshot.*")), [])
        self.call("dispatch", "review", "topic", "--oneshot", prompt="REQUIRED_REVIEW\n", rc=2)
        self.call("reply", "topic", "--oneshot", prompt="follow up", rc=2)
        self.call("dispatch", "ask", "topic", "--oneshot", "--oneshot", prompt="question", rc=2)
        self.call("new", "topic", "--dry-run", rc=2)
        self.assertEqual(self.args_log.read_text().splitlines().count("-p"), 1)

    def test_ephemeral_failure_and_missing_capability_leave_no_state(self):
        before = set(self.repo.iterdir())
        state = self.state()
        for extra, code in [({"FAKE_CLAUDE_MISSING_FLAG": "--no-session-persistence"}, 9),
                            ({"FAKE_CLAUDE_BUDGET_ERROR": "1"}, 3)]:
            with self.subTest(code=code):
                result = self.call("dispatch", "ask", "ephemeral", "--oneshot", prompt="question",
                                   env={**self.env, **extra}, rc=code)
                self.assertNotIn("retained", result.stderr)
                self.assertNotIn("last-error", result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertFalse(state.exists())
                self.assertEqual(set(self.repo.iterdir()), before)
                self.assertEqual(list(self.tmp.glob("codex-cc-oneshot.*")), [])

    def test_standalone_contexts_are_scoped_and_readonly(self):
        a, b = self.tmp / "first", self.tmp / "second"
        a.mkdir(); b.mkdir()
        state_a, state_b = self.state(a), self.state(b)
        self.assertNotEqual(state_a, state_b)
        self.assertIn(str(self.tmp / "xdg"), str(state_a))
        self.call("status", cwd=a)
        self.call("resolve", cwd=a, rc=6)
        self.assertFalse(state_a.exists())
        self.call("dispatch", "plan", "options", cwd=a, prompt="compare options")
        self.assertEqual(self.call("resolve", cwd=a).stdout.strip(), "options")
        answer = self.call("reply", "options", cwd=a, prompt="more detail")
        self.assertIn("FAKE_RESUME", answer.stdout)
        args = self.args_log.read_text().splitlines()
        self.assertIn("Read,Glob,Grep", args)
        self.assertIn("dontAsk", args)
        self.call("resolve", cwd=b, rc=6)
        self.call("dispatch", "review", "reject", cwd=b, prompt="review", rc=7)
        self.call("begin", "reject", "--base", "HEAD", "--spec", "spec.md",
                  script=SCRIPTS / "review-state.sh", cwd=b, rc=7)
        self.assertFalse(state_b.exists())
        self.call("new", "options", cwd=a)
        self.assertTrue(list(state_a.glob("options.archive.*")))
        self.assertEqual(list(a.iterdir()), [])

    def test_named_and_implicit_resolution_across_worktrees(self):
        other = self.tmp / "other"
        self.git("worktree", "add", "-qb", "side", str(other))
        self.call("dispatch", "ask", "question", prompt="first")
        self.call("dispatch", "plan", "design", cwd=other, prompt="second")
        self.assertEqual(self.call("resolve").stdout.strip(), "question")
        self.assertEqual(self.call("resolve", cwd=other).stdout.strip(), "design")
        self.assertEqual(self.call("resolve", "design").stdout.strip(), "design")
        self.assertIn("question", self.call("resolve", "missing", rc=6).stderr)
        self.call("begin", "gate", "--base", "HEAD", "--spec", "spec.md", script=SCRIPTS / "review-state.sh")
        ambiguous = self.call("resolve", rc=8)
        self.assertIn("question", ambiguous.stderr)
        self.assertIn("gate", ambiguous.stderr)
        self.assertNotIn("design", ambiguous.stderr)
        self.assertEqual(self.call("resolve", "gate").stdout.strip(), "gate")
        self.call("new", "gate")
        (self.state() / "question.worktree").unlink()  # Legacy shared session.
        self.assertIn("question", self.call("resolve", rc=8).stderr)
        self.assertEqual(self.call("resolve", "question").stdout.strip(), "question")

    def test_quoted_transcripts_count_as_one_dispatch(self):
        heading = "## 2026-11-01T10:10:10Z mode=review"
        self.call("dispatch", "review", "archive", "main", prompt="Check this log\n" + heading,
                  env={**self.env, "FAKE_CLAUDE_RESULT": heading + "\nLooks fine"})
        self.assertIn("rounds=1\t", self.call("status", "archive").stdout)

    def test_first_worker_and_active_lease_status(self):
        env = {**self.env, "FAKE_CLAUDE_SLEEP_SECONDS": "3"}
        with subprocess.Popen(["bash", DRIVER, "dispatch", "ask", "live"], cwd=self.repo,
                              env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True) as worker:
            worker.stdin.write("Question")
            worker.stdin.close()
            for _ in range(200):
                if self.prompt_log.exists():
                    break
                time.sleep(0.05)
            state = self.state()
            self.assertFalse((state / "live.id").exists())
            self.assertIn("state=busy", self.call("status", "live").stdout)
            self.assertEqual(self.call("resolve").stdout.strip(), "live")
            self.assertEqual(worker.wait(timeout=15), 0, worker.stderr.read())
        os.utime(state / "live.log", (946684800, 946684800))
        self.assertIn("last_activity=946684800", self.call("status", "live").stdout)
        lock = state / "dead.active"; lock.mkdir()
        (lock / "pid").write_text("999999999")
        self.assertNotIn("dead", self.call("status").stdout)
        self.assertEqual(self.call("resolve").stdout.strip(), "live")

    def test_reply_does_not_recreate_a_concurrently_reset_thread(self):
        self.call("dispatch", "ask", "hello", prompt="first")
        shim = self.tmp / "bin"; shim.mkdir()
        signal = self.tmp / "reading"
        cat = shim / "cat"
        cat.write_text('#!/bin/sh\nif [ "$#" -eq 0 ]; then : > "$READING"; fi\nexec /bin/cat "$@"\n')
        cat.chmod(0o755)
        env = {**self.env, "PATH": str(shim) + ":" + self.env["PATH"], "READING": str(signal)}
        with subprocess.Popen(["bash", DRIVER, "reply", "hello"], cwd=self.repo, env=env,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True) as worker:
            for _ in range(200):
                if signal.exists():
                    break
                time.sleep(0.05)
            self.assertTrue(signal.exists())
            self.call("new", "hello")
            _, error = worker.communicate("follow up", timeout=20)
            self.assertEqual(worker.returncode, 6, error)
        self.assertEqual(self.args_log.read_text().splitlines().count("-p"), 1)


if __name__ == "__main__":
    unittest.main()
