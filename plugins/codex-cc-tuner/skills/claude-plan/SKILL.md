---
name: claude-plan
description: Use only when the user explicitly asks Codex to get a Claude Code second opinion, critique, or adversarial stress-test of an implementation plan or technical design.
---

# Claude Plan

Use Claude Code as a read-only second-opinion planner. Codex remains the judge: validate every
objection against the repository before changing the plan.

1. Read the relevant plan, task, repository instructions, and architecture boundaries yourself.
2. Derive a task-scoped thread name: `plan-<branch-or-task-slug>`. Never use a shared `plan` thread
   across unrelated tasks. Reuse the same name only for another round on the same plan.
3. Resolve `<plugin-root>` as two directories above this skill's directory (the parent of
   `skills/`), not as the `skills/` directory itself.
4. Build a concise prompt containing the plan path or proposal, important constraints, unresolved
   decisions, and the exact stress-test requested. Do not paste secrets or unrelated proprietary
   context.
5. Send it on stdin without shell interpolation:

   ```bash
   bash "<plugin-root>/scripts/claude-thread.sh" dispatch plan "<thread>" <<'CODEX_CC_TUNER_PROMPT'
   <prompt text>
   CODEX_CC_TUNER_PROMPT
   ```

6. Report the thread name. Check Claude's findings against live code and current primary docs;
   accept, reject, or qualify each material objection with evidence.
7. After plan edits, invoke the same thread for a fresh re-evaluation. Do not start a new session
   merely to seek an easier verdict.

If the driver exits non-zero, report its exact diagnostic. Do not silently replace a failed resume
with a new thread.

The Claude subprocess requires outbound network access. If Codex blocks it, request approval for
this bridge command or explain the narrow `workspace-write` network setting; never recommend
disabling sandboxing globally.
