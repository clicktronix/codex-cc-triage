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
  Claude session ID. For a required lifecycle it also reports the authoritative `required`,
  `gate_eligible`, `verdict`, `reason`, and claim-expiry fields, including `PENDING`, `STALE`,
  `CAP_REACHED`, and `DIVERGED`. A log verdict is not a substitute for those fields.
- `name` normalizes a branch or task label into the exact ASCII thread name accepted by the driver.
- `new` deletes only the named thread's local ID, log, context, diagnostics, and required-review
  lifecycle. The next
  `$codex-cc-triage:claude-second-opinion`, `$codex-cc-triage:claude-plan`, or
  `$codex-cc-triage:claude-review` call with that name starts a fresh Claude session.
- Never reset a thread while another call owns its active lock or required-review mutex. The driver
  returns exit 10. Reset is the explicit recovery from a terminal cap/divergence or abandoned claim;
  it is not part of an ordinary repair round.
- Thread and required-review state lives under the repository common Git directory reported by
  `scripts/state-dir.sh`, survives disposable-worktree removal, and may contain prompts and review
  output. It is outside the worktree and Git index; do not copy it into committed files.
