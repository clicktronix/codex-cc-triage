"""Deterministic interleavings for the directory locks, ordered through a PATH-shimmed cat."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "plugins/codex-cc-triage/scripts"

# Count reads of one lock's owner file per role. At the configured read, capture
# the owner, publish <role>.ready, wait for <role>.go, then print what was read.
SHIM = r"""#!/bin/sh
case "$1" in
  *"$SHIM_LOCK/owner")
    out="$(/bin/cat "$@")"; rc=$?
    n=$(( $(/bin/cat "$SHIM_DIR/$SHIM_ROLE.count" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$SHIM_DIR/$SHIM_ROLE.count"
    if [ "$n" = "$SHIM_PAUSE_AT" ]; then
      : > "$SHIM_DIR/$SHIM_ROLE.ready"
      while [ ! -e "$SHIM_DIR/$SHIM_ROLE.go" ]; do sleep 0.05; done
    fi
    [ -z "$out" ] || printf '%s\n' "$out"
    exit "$rc"
    ;;
esac
exec /bin/cat "$@"
"""


class LockRaces(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name).resolve()
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=self.repo, check=True)
        self.signals = self.tmp / "signals"
        self.signals.mkdir()
        shim_bin = self.tmp / "bin"
        shim_bin.mkdir()
        (shim_bin / "cat").write_text(SHIM)
        (shim_bin / "cat").chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("CODEX_CC_TRIAGE_")}
        self.env.update(PATH=f"{shim_bin}:{os.environ['PATH']}", SHIM_DIR=str(self.signals),
                        CODEX_CC_TRIAGE_PROJECT_DIR=str(self.repo))
        self.workers = []

    def start(self, role, pause_at, argv, lock):
        env = {**self.env, "SHIM_ROLE": role, "SHIM_PAUSE_AT": str(pause_at), "SHIM_LOCK": lock}
        worker = subprocess.Popen(argv, cwd=self.repo, env=env, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
        self.workers.append((role, worker))
        self.addCleanup(self.finish, role, worker)
        return worker

    def finish(self, role, worker):
        (self.signals / f"{role}.go").touch()
        if worker.poll() is None:
            worker.kill()
        worker.communicate()

    def wait_for(self, predicate, what):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail(f"timed out waiting for {what}")

    def paused(self, role):
        return (self.signals / f"{role}.ready").exists()

    def reads(self, role):
        try:
            return int((self.signals / f"{role}.count").read_text())
        except (OSError, ValueError):
            return 0

    def assert_reclaim_respects_a_new_generation(self, argv, lock_dir):
        """H holds the lock, C samples H inside the staleness check, H exits, T takes a
        fresh lock, then C resumes. C must leave T's generation in place."""
        lock = lock_dir.name
        holder = self.start("holder", 1, argv, lock)
        self.wait_for(lambda: self.paused("holder"), "the holder to own the lock")
        contender = self.start("contender", 2, argv, lock)
        self.wait_for(lambda: self.paused("contender"), "the contender's staleness read")
        (self.signals / "holder.go").touch()
        _, error = holder.communicate(timeout=20)
        self.assertEqual(holder.returncode, 0, error)
        third = self.start("third", 1, argv, lock)
        self.wait_for(lambda: self.paused("third") or third.poll() is not None,
                      "the third caller to take the lock or finish")
        third_holds = self.paused("third") and third.poll() is None
        (self.signals / "contender.go").touch()
        self.wait_for(lambda: contender.poll() is not None or self.reads("contender") >= 3,
                      "the contender to decide")
        if third_holds:
            owner = lock_dir / "owner"
            self.assertTrue(owner.is_file(), "the third caller's lock was moved away")
            self.assertEqual(owner.read_text().strip(), str(third.pid))
        self.assertNotEqual(contender.poll(), 7, "the contender reclaimed a live generation")
        (self.signals / "third.go").touch()
        for role, worker in (("third", third), ("contender", contender)):
            _, error = worker.communicate(timeout=20)
            self.assertEqual(worker.returncode, 0, f"{role}: {error}")
        leftovers = sorted(p.name for p in lock_dir.parent.iterdir() if ".stale" in p.name)
        self.assertEqual(leftovers, [])

    def test_review_lock_reclaim_rechecks_the_owner_before_moving(self):
        state = self.tmp / "state"
        state.mkdir()
        self.env["CODEX_CC_TRIAGE_STATE_DIR"] = str(state)
        argv = ["bash", str(SCRIPTS / "review-state.sh"), "advisory-check", "t"]
        self.assert_reclaim_respects_a_new_generation(argv, state / "t.review-lock")

    def test_migration_lock_reclaim_rechecks_the_owner_before_moving(self):
        argv = ["bash", str(SCRIPTS / "state-dir.sh")]
        self.assert_reclaim_respects_a_new_generation(
            argv, self.repo / ".git/codex-cc-triage/migration.lock")

    def test_completed_state_resolution_skips_a_busy_migration_lock(self):
        helper = ["bash", str(SCRIPTS / "state-dir.sh")]
        first = subprocess.run(helper, cwd=self.repo, env=self.env, capture_output=True,
                               text=True, timeout=30)
        self.assertEqual(first.returncode, 0, first.stderr)
        owner = subprocess.Popen(["sleep", "30"])
        self.addCleanup(owner.kill)
        lock = self.repo / ".git/codex-cc-triage/migration.lock"
        lock.mkdir()
        (lock / "owner").write_text(f"{owner.pid}\n")
        started = time.monotonic()
        second = subprocess.run(helper, cwd=self.repo, env=self.env, capture_output=True,
                                text=True, timeout=30)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.stdout, first.stdout)
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual((lock / "owner").read_text(), f"{owner.pid}\n")


if __name__ == "__main__":
    unittest.main()
