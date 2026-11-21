---
name: claude-plan
description: Stress-test a proposed implementation plan or architecture with Claude when the task requests or authorizes an independent planning opinion.
---

# Claude Plan

Read the plan, constraints, existing evidence and relevant repository rules. Follow the [ownership and dispatch rules](../references/ownership.md). Send the decisions that require scrutiny, affected boundaries and what would falsify the approach.

```bash
bash "<plugin-root>/scripts/claude-thread.sh" dispatch plan "<thread>" <<'CODEX_CC_TRIAGE_PROMPT'
<plan, decisions to scrutinize and what would falsify them>
CODEX_CC_TRIAGE_PROMPT
```

Validate each objection against code or current primary sources. When a revised plan needs another assessment, reuse the thread. Finish on approval, optional comments only, or the round limit: five rounds for a new iterative plan, fewer when the owner sets fewer. `--once` and `--oneshot` both finish after the first response. Report the recommendation, remaining uncertainty and, for persistent sessions, the thread name.
