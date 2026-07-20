---
name: claude-reply
description: Use only when the user explicitly asks Codex to continue, reply to, or re-evaluate an existing codex-cc-triage Claude thread by name.
---

# Claude Reply

Continue an existing Claude session without changing its plan/review role or review base.

1. Require the exact thread name shown by a previous call or by
   `$codex-cc-triage:claude-thread status`.
2. Resolve `<plugin-root>` as two directories above this skill's directory (the parent of
   `skills/`), not as the `skills/` directory itself.
3. Send a focused follow-up on stdin:

   ```bash
   bash "<plugin-root>/scripts/claude-thread.sh" reply "<thread>" <<'CODEX_CC_TRIAGE_PROMPT'
   <prompt text>
   CODEX_CC_TRIAGE_PROMPT
   ```

4. For review threads, the driver regenerates the complete current diff before resuming. Ask for a
   full re-review after fixes, not only confirmation of prior findings.
5. Validate the response independently. Do not treat a confident verdict as proof.

Missing, malformed, or mode-corrupt threads are hard failures. Never fall back to a new session
without telling the user.

The Claude subprocess requires outbound network access. If Codex blocks it, request approval for
this bridge command or explain the narrow `workspace-write` network setting; never recommend
disabling sandboxing globally.
