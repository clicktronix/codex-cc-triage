---
name: claude-thread
description: Use only when the user explicitly asks Codex to list, inspect, reset, or start fresh from codex-cc-triage Claude thread state.
---

# Claude Thread

Resolve `<plugin-root>` as two directories above this skill's directory (the parent of `skills/`),
not as the `skills/` directory itself, then run one operation:

```bash
bash "<plugin-root>/scripts/claude-thread.sh" status
bash "<plugin-root>/scripts/claude-thread.sh" status "<thread>"
bash "<plugin-root>/scripts/claude-thread.sh" new "<thread>"
bash "<plugin-root>/scripts/claude-thread.sh" name "<ask|plan|review>" "<task-label>"
```

- `status` lists task thread, mode, pinned review-base commit, completed rounds, health state, and
  Claude session ID. A failed first dispatch remains visible with `state=failed` and no session ID.
- `name` normalizes a branch or task label into the exact ASCII thread name accepted by the driver.
- `new` deletes only the named thread's local ID, log, context, and diagnostics. The next
  `$codex-cc-triage:claude-second-opinion`, `$codex-cc-triage:claude-plan`, or
  `$codex-cc-triage:claude-review` call with that name starts a fresh Claude session.
- Never reset a thread while another call owns its active lock. The driver returns exit 10.
- Thread state is local under `.agent-state/codex-cc-triage/` and ignored by its own `.gitignore`,
  but may contain prompts and review output. Do not commit it with `git add -f`.
