---
name: claude-thread
description: Use only when the user explicitly asks Codex to list, inspect, reset, or start fresh from codex-cc-tuner Claude thread state.
---

# Claude Thread

Resolve `<plugin-root>` as the directory two levels above this `SKILL.md`, then run one operation:

```bash
bash "<plugin-root>/scripts/claude-thread.sh" status
bash "<plugin-root>/scripts/claude-thread.sh" status "<thread>"
bash "<plugin-root>/scripts/claude-thread.sh" new "<thread>"
```

- `status` lists task thread, mode, review base, and Claude session ID.
- `new` deletes only the named thread's local ID, log, context, and diagnostics. The next
  `$claude-plan` or `$claude-review` call with that name starts a fresh Claude session.
- Never reset a thread while another call owns its active lock. The driver returns exit 10.
- Thread state is local and ignored, but may contain prompts and review output. Do not commit it.
