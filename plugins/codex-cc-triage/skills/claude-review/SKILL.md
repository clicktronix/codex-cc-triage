---
name: claude-review
description: Use when the user explicitly asks Codex to have Claude Code review the current branch, worktree, implementation, or fixes, or when an owning workflow invokes the required exact-candidate review contract.
---

# Claude Review

Use Claude Code as a read-only reviewer. The wrapper builds a bounded branch snapshot containing
committed, staged, unstaged, and untracked changes. It hard-fails rather than truncating a diff.
Codex owns final triage and verification. Follow [ownership.md](../references/ownership.md).

## Required delivery contract

For `--required --base <ref> --spec <path> --thread <thread> --cap <1..5>`, read
[required-review.md](references/required-review.md) before dispatch. It owns claim,
actual base/candidate attribution, recording, recovery and the final marker.

## Advisory review

1. Inspect the branch and intended base ref yourself.
2. Resolve `<plugin-root>` as two directories above this skill's directory (the parent of
   `skills/`), not as the `skills/` directory itself.
3. Generate the thread name with the driver. On a feature branch, omit the source to use that
   branch; on `main`, `master`, or detached HEAD, pass a concise task label:

   ```bash
   thread="$(bash "<plugin-root>/scripts/claude-thread.sh" name review)"
   # On main, master, or detached HEAD:
   thread="$(bash "<plugin-root>/scripts/claude-thread.sh" name review "<task-label>")"
   ```

   Never reuse the result across unrelated changes.
4. Reserve the name for advisory use before dispatch. This refuses a thread that already owns
   required-review state:

   ```bash
   bash "<plugin-root>/scripts/review-state.sh" advisory-check "$thread"
   ```

5. Build a concise review request with the task intent, acceptance criteria, requested lenses, and
   any known test results. Do not bias Claude with your suspected findings.
6. Pass the integration target explicitly when known. The first round pins it to a commit; if that
   ref moves later, keep passing its stored literal SHA. The owner integrates target movement
   and refreshes evidence without discarding the conversation. Change the base only as an
   explicit new review contract:

   ```bash
   bash "<plugin-root>/scripts/claude-thread.sh" \
     dispatch review "$thread" "<target-ref>" <<'CODEX_CC_TRIAGE_PROMPT'
   <prompt text>
   CODEX_CC_TRIAGE_PROMPT
   ```

   If no target is known, omit it; the driver tries `origin/main`, `main`, `origin/master`, then
   `master`, and otherwise reviews worktree changes against `HEAD`.

7. Validate every finding against the actual code. Fix accepted findings within scope and reject
   false positives explicitly.
8. Re-run the same thread within the authorized budget. Each round supplies the complete snapshot;
   ask for affected invariants and regressions after fixes, and complete coverage before final approval.
   Reuse valid verification evidence instead of requesting identical builds.
9. Report the thread name, accepted/rejected findings, fixes, and verification. Outside required
   mode, Claude approval is supporting evidence, not a delivery gate or substitute for tests.

If the driver exits non-zero, report its exact diagnostic. Do not silently create a fresh session
after a failed resume.

The Claude subprocess requires outbound network access. If Codex blocks it, request approval for
this bridge command or explain the narrow `workspace-write` network setting; never recommend
disabling sandboxing globally.
