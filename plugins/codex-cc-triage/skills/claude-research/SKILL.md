---
name: claude-research
description: Investigate a current technical question using primary sources and an authorized independent Claude assessment.
---

# Claude Research

Clarify the decision and freshness requirement. Codex retrieves relevant primary sources using its available search or documentation tools; for repository-local research read the actual implementation. Capture the URL or path, date/version and a relevant excerpt. If a needed source is inaccessible, report the specific evidence gap.

Apply the [shared budget and dispatch rules](../references/ownership.md). Send the question and excerpts via `claude-thread.sh dispatch ask "$thread"`. Ask Claude to compare claims, identify unsupported inferences and explain what could change the answer. The reviewer can inspect local files but has no web tool. Codex verifies each cited source and returns the answer with its evidence and remaining uncertainty. One pass is the default.
