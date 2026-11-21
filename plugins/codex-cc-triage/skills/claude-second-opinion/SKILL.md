---
name: claude-second-opinion
description: Ask Claude one bounded technical question when a user requests a second opinion or an owning workflow has authorized the call.
---

# Claude Second Opinion

Read the relevant evidence and state the question and uncertainty. Follow the [ownership and dispatch rules](../references/ownership.md).

```bash
bash "<plugin-root>/scripts/claude-thread.sh" dispatch ask "<thread>" <<'CODEX_CC_TRIAGE_PROMPT'
<question, constraints and evidence already checked>
CODEX_CC_TRIAGE_PROMPT
```

Return the answer and supporting evidence after one call. For a direct follow-up use the same thread. A plan critique, branch review, source investigation and comparison of competing positions each have a dedicated skill.
