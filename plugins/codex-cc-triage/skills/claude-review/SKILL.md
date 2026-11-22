---
name: claude-review
description: Obtain a Claude review of a branch, working tree or pasted findings when requested or covered by the task's external review agreement. Use required mode for exact-candidate approval.
---

# Claude Review

Use the [ownership and dispatch rules](../references/ownership.md). For `--required` follow [required review](references/required-review.md). Ordinary advisory results inform the owner’s judgement.

1. Resolve the requested scope, comparison base, evidence and relevant lens. Choose correctness, architecture, data/security, performance, UX or a quick check according to the task. For pasted third-party findings, request one classification pass against the actual code and consumers.
2. Use the explicit or ongoing thread, otherwise generate one with `claude-thread.sh name review [task-label]`. For a persistent advisory call check `review-state.sh advisory-check "<thread>"`. An ephemeral call skips this reservation.
3. Dispatch the review. Supply the pinned base when known; omit it if the driver should resolve it. The driver includes committed and working-tree changes and refuses an incomplete snapshot. Append `--oneshot` for an ephemeral call. Request a final `APPROVE`, `REQUEST_CHANGES` or `COMMENT`, with a location and consequence for every blocker.

```bash
bash "<plugin-root>/scripts/claude-thread.sh" dispatch review "<thread>" "<base>" <<'CODEX_CC_TRIAGE_PROMPT'
<scope, lens, evidence and the verdict instruction>
CODEX_CC_TRIAGE_PROMPT
```

4. Validate findings. Finish after one pass with `--once`, `--oneshot` or pasted findings, and on approval or a nonblocking `COMMENT`. Within a requested fix-and-review loop, correct confirmed issues, rerun affected checks, and ask the same thread to reassess. A new advisory loop stops at seven rounds, fewer when the owner sets fewer; on resume count the rounds the thread already ran.
5. Return accepted and refuted findings, unresolved decisions and the evidence examined. Include the thread name for persistent reviews.
