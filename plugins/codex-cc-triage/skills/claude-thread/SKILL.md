---
name: claude-thread
description: Use to inspect codex-cc-triage Claude threads and archives, or maintain an owned idle thread during an authorized workflow. Starts no Claude call.
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
bash "<plugin-root>/scripts/claude-thread.sh" resolve [known-or-explicit-name]
bash "<plugin-root>/scripts/claude-thread.sh" new "<thread>"
bash "<plugin-root>/scripts/claude-thread.sh" name "<ask|plan|review>" "<task-label>"
```

- `status` lists task thread, mode, pinned review-base commit, completed rounds, health state, and
  Claude session ID. For a required lifecycle it also reports the authoritative `required`,
  `gate_eligible`, `verdict`, `reason`, and claim-expiry fields, including `PENDING`, `STALE`,
  `CAP_REACHED`, and `DIVERGED`. It also shows retained archive count, bytes and location,
  including a named thread whose live state was reset. Use `review-state.sh check` for approval.
- `resolve` selects a requested or sole eligible thread, including a renewed required contract. Explicit names can refer to a linked worktree. Ask for a choice on ambiguity.
- `name` normalizes a branch or task label into the exact ASCII thread name accepted by the driver.
- `new` archives the named thread's plugin state before clearing its ID, log, context,
  diagnostics and required-review lifecycle, including the round count and approval. It
  starts no Claude call and adds no approval or rounds. The next
  `$codex-cc-triage:claude-second-opinion`, `$codex-cc-triage:claude-plan`, or
  `$codex-cc-triage:claude-review` call with that name starts a fresh Claude session.
- Never reset a thread while another call owns its active lock or required-review mutex. The driver
  returns exit 10. An abandoned claim with a dead lease can be aborted and resumed without reset.
- In a Git checkout thread and required-review state lives under the common Git directory reported by
  `scripts/state-dir.sh`, survives disposable-worktree removal, and may contain prompts and review
  output. It is outside the worktree and Git index; do not copy it into committed files.

## Recovery

For `state=budget_exhausted` (the dollar cap set by `CODEX_CC_TRIAGE_MAX_BUDGET_USD` stopped
the response), the session ID and review base are retained, but the review is incomplete.
Continue with `reply` or `dispatch` on the same thread. Do not reset or infer approval from a
partial result. Older plugin
versions may retain identity only in `last-error.json`; do not start a fresh session
silently when that state needs recovery.

For `INVALID_CLAIM_STATE`, inspect the claim, loop, log and saved result; a malformed
claim does not necessarily invalidate the round count. Restore an intact matching snapshot
if available; never invent state fields or approval. If restoration is impossible, or
the owner has resolved a terminal divergence, archive/reset the owned idle thread with
`new`. Carry findings and the confirmed remaining rounds into the next lifecycle, counting
completed or unresolved claims as used. If no rounds remain or the count is unknown,
report once and continue safe work; more rounds need the owner's authorization, reusing a
decision already given. Corruption or divergence itself adds no rounds.

For `INVALID_DISPATCH_LEASE`, establish whether a dispatch is still running before
recovery. Never remove a lease whose owner might be active.
