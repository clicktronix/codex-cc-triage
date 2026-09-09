---
name: claude-thread
description: Use to inspect codex-cc-triage Claude threads and archives, or maintain an owned idle thread during an authorized workflow. Does not start paid calls.
---

# Claude Thread

Follow [ownership.md](../references/ownership.md). Inspect state as needed without a new
permission question; reset only your owned idle obsolete advisory threads or follow
[Recovery](#recovery). Preserve threads needed by active work and required delivery.

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
  `CAP_REACHED`, and `DIVERGED`. It also shows retained archive count, bytes and location,
  including a named thread whose live state was reset. Use `review-state.sh check` for approval.
- `name` normalizes a branch or task label into the exact ASCII thread name accepted by the driver.
- `new` archives the named thread's plugin state before clearing its ID, log, context,
  diagnostics and required-review lifecycle, including the attempt count and approval. It
  starts no paid call and grants no approval or extra review budget. The next
  `$codex-cc-triage:claude-second-opinion`, `$codex-cc-triage:claude-plan`, or
  `$codex-cc-triage:claude-review` call with that name starts a fresh Claude session.
- Never reset a thread while another call owns its active lock or required-review mutex. The driver
  returns exit 10. An abandoned claim with a dead lease can be aborted and resumed without reset.
- Thread and required-review state lives under the repository common Git directory reported by
  `scripts/state-dir.sh`, survives disposable-worktree removal, and may contain prompts and review
  output. It is outside the worktree and Git index; do not copy it into committed files.

## Recovery

For `INVALID_CLAIM_STATE`, inspect the claim, loop, log and saved result; a malformed
claim does not necessarily invalidate the budget. Restore an intact matching snapshot
if available; never invent state fields or approval. If restoration is impossible, or
the owner has resolved a terminal divergence, archive/reset the owned idle thread with
`new`. Carry findings and confirmed remaining authorized attempts into the next lifecycle,
counting completed or unresolved claims as spent. If the budget is exhausted or unknown,
report once and continue safe work; paid review needs renewed authorization, reusing a
decision already given. Corruption or divergence itself grants no extra budget.

For `INVALID_DISPATCH_LEASE`, establish whether a dispatch is still running before
recovery. Never remove a lease whose owner might be active.
