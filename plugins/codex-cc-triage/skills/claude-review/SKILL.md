---
name: claude-review
description: Obtain a Claude review of a branch, working tree or pasted findings when requested or covered by the task's external review agreement. Use required mode for exact-candidate approval.
---

# Claude Review

Use the [ownership and budget rules](../references/ownership.md). For `--required` follow [required review](references/required-review.md). Ordinary advisory results inform the owner’s judgement.

1. Resolve the requested scope, comparison base, evidence and relevant lens. Choose correctness, architecture, data/security, performance, UX or a quick check according to the task. For pasted third-party findings, request one classification pass against the actual code and consumers.
2. Use the explicit or ongoing thread, otherwise generate one with `claude-thread.sh name review [task-label]`. For a persistent advisory call check `review-state.sh advisory-check "$thread"`. An ephemeral call skips this reservation.
3. Dispatch the review. Supply the pinned base when known. The driver includes committed and working-tree changes and refuses an incomplete snapshot.

   ```bash
   bash "$plugin_root/scripts/claude-thread.sh" dispatch review "$thread" "$base" < "$prompt_file"
   ```

   Omit the base if the driver should resolve it. Append `--oneshot` for an ephemeral call. Request a final `APPROVE`, `REQUEST_CHANGES` or `COMMENT`, with a location and consequence for every blocker.
4. Validate findings. Finish after one pass with `--once`, `--oneshot` or pasted findings, and on approval or a nonblocking `COMMENT`. Within a requested fix-and-review loop, correct confirmed issues, rerun affected checks, and ask the same thread to reassess. The default ceiling for a new advisory review is seven calls or the owner's smaller grant. Respect the remaining grant on resume.
5. Return accepted and refuted findings, unresolved decisions and the evidence examined. Include the thread name for persistent reviews.
