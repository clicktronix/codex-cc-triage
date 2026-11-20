---
name: claude-reply
description: Continue an existing Claude opinion, plan or review when the current task authorizes the follow-up, including after a technical failure or a budget renewal.
---

# Claude Reply

Follow the [ownership and budget rules](../references/ownership.md).

1. Pass the explicit name, otherwise the thread known from this conversation, to `claude-thread.sh resolve "$name"`. With neither, call `claude-thread.sh resolve`. A single eligible thread is selected automatically. Exit 8 lists an ambiguity; ask once which to use. Exit 6 identifies a missing target. Preserve an explicitly requested name.
2. In a Git checkout run `review-state.sh mode "$thread"`. For `required`, read the saved contract, reconcile any pending claim, and follow [required review](../claude-review/references/required-review.md). A renewed grant continues on this thread. Standalone conversations are advisory.
3. For an advisory thread, answer the question or provide the relevant result of a delegated check. Send the follow-up with its original role and pinned base:

   ```bash
   bash "$plugin_root/scripts/claude-thread.sh" reply "$thread" < "$prompt_file"
   ```

4. Validate the response and report what changed. Use `claude-thread.sh status "$thread"` to diagnose a failed resume.
