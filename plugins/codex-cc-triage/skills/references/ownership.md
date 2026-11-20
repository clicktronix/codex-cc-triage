# Working with a Claude opinion

The owning agent chooses the question, runs verification, decides findings and holds publication authority. Select a paid skill for a requested Claude opinion or a review already authorized for this task. Reuse a known budget and model choice. If another paid call is needed beyond that authority, ask once and continue independent work.

## Budget and context

The default per-process ceilings are $5 for review and $1 for ask or plan, including discussions that use those modes. The default model is Sonnet with provider-default effort. State the ceiling and effort for the intended run, preserve a lower authorized ceiling through `CODEX_CC_TRIAGE_MAX_BUDGET_USD`, and pass authorized model or effort overrides through `CODEX_CC_TRIAGE_MODEL` and `CODEX_CC_TRIAGE_EFFORT`. A per-call limit and a round limit are separate. Charge additional calls to the same authorized total. Values are ceilings, not observed spend.

Resolve the plugin root two directories above the active skill directory. Prefer the thread already identified in the current task. For a new thread run `scripts/claude-thread.sh name ask|plan|review [task-label]` with the chosen mode. Supply a distinct task label for an integration branch, detached checkout, standalone context or unrelated task on the same branch.

## Dispatch

Use the public driver and send the prompt on stdin. Supply relevant scope, available evidence, and applicable rule paths. Claude has read-only Read/Glob/Grep tools. Codex runs delegated tests, looks up first-party sources and returns the relevant excerpt. Release, external comments, changes of scope and acceptance waivers belong to the owner.

- `--once` requests one pass on the named persistent conversation. `--oneshot` means one ephemeral response: append `--oneshot` to the advisory dispatch. Return the answer directly.
- For an authorized background advisory call, start the same driver once using the host's yielding process tool. Continue observing that process by its returned session handle. If no such tool is available, wait in the foreground. On an interrupted wait inspect thread status before considering a retry. Required review uses the foreground result and its claim.
- A failed resume retains its identity. Surface the driver diagnostic, resolve what it asks for and use the same thread. If the session must be replaced or the authorization expanded, tell the owner why. After a budget-exhausted response use the recorded status and remaining authorization.

Return validated findings and the checks that support them. A reviewer can request evidence within the original task. Address confirmed defects and their causes across affected consumers. After a changed candidate, refresh the affected evidence. Group genuine decisions for the user and continue the parts already authorized.
