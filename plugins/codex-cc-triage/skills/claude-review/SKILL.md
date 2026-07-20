---
name: claude-review
description: Use only when the user explicitly asks Codex to have Claude Code review the current branch, worktree, implementation, or fixes as an independent second opinion.
---

# Claude Review

Use Claude Code as a read-only reviewer. The wrapper builds a bounded branch snapshot containing
committed, staged, unstaged, and untracked changes. It hard-fails rather than truncating a diff.
Codex owns final triage and verification.

1. Inspect the branch and intended base ref yourself. Derive a task-scoped thread name such as
   `review-feat-billing`; never reuse a generic `review` thread across unrelated changes.
2. Resolve `<plugin-root>` as two directories above this skill's directory (the parent of
   `skills/`), not as the `skills/` directory itself.
3. Build a concise review request with the task intent, acceptance criteria, requested lenses, and
   any known test results. Do not bias Claude with your suspected findings.
4. Pass the integration target explicitly when known. The first round pins it to a commit; if that
   ref moves later, start a new thread instead of mixing review bases:

   ```bash
   bash "<plugin-root>/scripts/claude-thread.sh" \
     dispatch review "<thread>" "<target-ref>" <<'CODEX_CC_TRIAGE_PROMPT'
   <prompt text>
   CODEX_CC_TRIAGE_PROMPT
   ```

   If no target is known, omit it; the driver tries `origin/main`, `main`, `origin/master`, then
   `master`, and otherwise reviews worktree changes against `HEAD`.

5. Validate every finding against the actual code. Fix accepted findings within scope and reject
   false positives explicitly.
6. Re-run the same thread after fixes. Each round regenerates the entire review snapshot and asks
   for a complete fresh review, so regressions introduced by fixes remain visible.
7. Report the thread name, accepted/rejected findings, fixes, and verification. Claude approval is
   supporting evidence, not a substitute for tests or Codex's own review.

If the driver exits non-zero, report its exact diagnostic. Do not silently create a fresh session
after a failed resume.

The Claude subprocess requires outbound network access. If Codex blocks it, request approval for
this bridge command or explain the narrow `workspace-write` network setting; never recommend
disabling sandboxing globally.
