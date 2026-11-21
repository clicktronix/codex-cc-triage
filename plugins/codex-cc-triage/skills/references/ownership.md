# Working with a Claude opinion

The owning agent chooses the question, runs verification, decides findings and holds publication authority. A Claude opinion starts on the user's request or when the owning workflow's review step requires it, because it sends repository content to another provider. Reuse the thread, model and effort already chosen for the task. If a further opinion goes beyond that request, ask once and continue independent work.

## Request

Send the question, relevant scope, available evidence and applicable rule paths. Keep the request unbiased: do not seed the findings you suspect and do not cap how many Claude may report. Do not paste secrets or unrelated proprietary context.

The default model is Sonnet with provider-default effort. Pass an authorized model or effort through `CODEX_CC_TRIAGE_MODEL` and `CODEX_CC_TRIAGE_EFFORT`. `CODEX_CC_TRIAGE_MAX_BUDGET_USD` caps each Claude process in dollars only when it is set.

## Running the driver

In every recipe, `<plugin-root>` is two directories above the active skill's directory (the parent of `skills/`), not `skills/` itself. Pass the request on stdin through a quoted heredoc, which keeps the checkout clean for a required-review candidate:

```bash
bash "<plugin-root>/scripts/claude-thread.sh" dispatch ask "<thread>" <<'CODEX_CC_TRIAGE_PROMPT'
<request>
CODEX_CC_TRIAGE_PROMPT
```

The Claude subprocess requires outbound network access. If Codex's sandbox blocks it, request approval for this bridge command or explain the narrow `workspace-write` network setting; never recommend disabling the sandbox globally.

Prefer the thread already identified in the current task. For a new thread run `claude-thread.sh name ask|plan|review [task-label]` with the chosen mode. Supply a distinct task label for an integration branch, detached checkout, standalone context or unrelated task on the same branch.

## Dispatch

Claude has read-only Read/Glob/Grep tools. Codex runs delegated tests, looks up first-party sources and returns the relevant excerpt. Release, external comments, changes of scope and acceptance waivers belong to the owner.

- `--once` requests one pass on the named persistent conversation. `--oneshot` means one ephemeral response: append `--oneshot` to the advisory dispatch. Return the answer directly.
- For an advisory call in the background, start the same driver once using the host's yielding process tool. Continue observing that process by its returned session handle. If no such tool is available, wait in the foreground. On an interrupted wait inspect thread status before considering a retry. Required review uses the foreground result and its claim.
- A failed resume retains its identity. Surface the driver diagnostic, resolve what it asks for and use the same thread. If the session must be replaced, tell the owner why. A response stopped by the dollar cap is incomplete; continue on the same thread.

Return validated findings and the checks that support them. A reviewer can request evidence within the original task. Address confirmed defects and their causes across affected consumers. After a changed candidate, refresh the affected evidence. Group genuine decisions for the user and continue the parts already requested.
