---
name: claude-plan
description: Stress-test a proposed implementation plan or architecture with Claude when the task requests or authorizes an independent planning opinion.
---

# Claude Plan

Read the plan, constraints, existing evidence and relevant repository rules. Follow the [shared budget and dispatch rules](../references/ownership.md). Send the decisions that require scrutiny, affected boundaries and what would falsify the approach.

```bash
bash "$plugin_root/scripts/claude-thread.sh" dispatch plan "$thread" < "$prompt_file"
```

Validate each objection against code or current primary sources. When a revised plan needs another assessment, reuse the thread within the owner's grant. Finish on approval, optional comments only, or the authorized limit (default five total calls for a new iterative plan). `--once` and `--oneshot` both finish after the first response. Report the recommendation, remaining uncertainty and, for persistent sessions, the thread name.
