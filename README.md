# codex-cc-triage

A Codex plugin for bounded, read-only Claude opinions. The owning agent chooses the skill from the task, checks the evidence and controls delivery. A requested Claude opinion or an existing external-review agreement supplies the authority for the call.

## Install

Use Git, Python 3.8+ and an authenticated Claude Code CLI. The Claude process needs outbound access to its configured provider.

```bash
codex plugin marketplace add clicktronix/codex-cc-triage --ref main
codex plugin add codex-cc-triage@codex-cc-triage
```

Start a fresh Codex session for skill discovery. You can also invoke any skill explicitly.

| Skill | Use |
| --- | --- |
| `claude-second-opinion` | Ask a focused technical question. |
| `claude-plan` | Stress-test a design or implementation plan. |
| `claude-review` | Review a branch, check pasted findings, or run a required review. |
| `claude-research` | Assess evidence from primary sources gathered by Codex. |
| `claude-debate` | Compare rival positions and surface the disagreement that matters. |
| `claude-reply` | Continue the named, known or sole eligible thread. |
| `claude-thread` | Inspect status and retained archives, or reset an owned idle thread. |

```text
$codex-cc-triage:claude-review --required --base <sha> --spec "docs/План работ.md" --thread billing-review
$codex-cc-triage:claude-reply re-evaluate the transaction after the fix
$codex-cc-triage:claude-thread status
```

A persistent advisory call resumes the same Claude session. Use `--once` for a single pass with history and `--oneshot` for one ephemeral answer. Codex can follow a long advisory call through its process handle. Required review and branch snapshots need Git. Standalone advisory conversations use a separate context for each directory.

## Review budget and evidence

A new required review defaults to seven authorized calls. Use `--cap 1..7` for a smaller grant. Older threads retain their pinned base, spec and budget. A rejected preflight spends zero calls. Every launch spends one, including a failed call and a technical finding with no usable location. Integration also spends one call. After an authorized extension, `review-state.sh renew "$thread" --by "$owner" --rounds "$calls" --grant "$decision_id"` continues the same thread. Replaying a decision preserves its balance.

Record the foreground result against its claim **before editing or committing**. The driver checks the actual comparison base, clean candidate, tree, fingerprint, spec, prompt and round. Only a current approval produces `CODEX_CC_REQUIRED_REVIEW APPROVE`. A reviewer timeout, budget-exhausted response or unresolved finding leaves delivery pending. See [the exact protocol](plugins/codex-cc-triage/skills/claude-review/references/required-review.md) and [recovery](plugins/codex-cc-triage/skills/claude-thread/SKILL.md#recovery).

## Claude's access and state

The child runs with `--safe-mode`, `--permission-mode dontAsk`, `--strict-mcp-config` and the built-in Read, Glob and Grep tools. Codex gathers web, test, browser and database evidence within its own task permissions. A review request includes committed, staged, unstaged and untracked changes. An oversized context fails before the model call. A fingerprint check compares the Git worktree at the endpoints; keep the candidate stable throughout review.

Git thread state lives under `<git-common-dir>/codex-cc-triage/threads/` so named sessions survive worktree removal. The disposable Git context is self-ignored under `.agent-state/codex-cc-triage/`. Legacy state migration preserves its source. Status and recovery retain the known session ID and partial diagnostics after provider budget exhaustion. Reset archives the named thread. Inspect archives before disposal.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `CODEX_CC_TRIAGE_CLAUDE_BIN` | `claude` | Claude Code executable |
| `CODEX_CC_TRIAGE_PYTHON_BIN` | `python3` | Python interpreter |
| `CODEX_CC_TRIAGE_MODEL` | `sonnet` | Claude model or alias |
| `CODEX_CC_TRIAGE_EFFORT` | Provider default | Effort, capability-checked when supplied |
| `CODEX_CC_TRIAGE_MAX_BUDGET_USD` | $5 review, $1 ask/plan | Ceiling for one Claude invocation; keep any lower authorized amount |
| `CODEX_CC_TRIAGE_TIMEOUT_SECONDS` | 900 | Per-process wall-clock timeout |
| `CODEX_CC_TRIAGE_TARGET_REF` | Detected | Default review base |
| `CODEX_CC_TRIAGE_CONTEXT_LIMIT` | 5242880 | Complete review context limit, bytes |
| `CODEX_CC_TRIAGE_FILE_LIMIT` | 1048576 | Inline limit per untracked text file, bytes |
| `CODEX_CC_TRIAGE_REFRESH_CAPABILITIES` | 0 | Set to 1 after changing a Claude wrapper to refresh the help cache |

The per-process ceiling is independent of the number of rounds and of measured spend. Run `bash tests/run.sh` for the offline regression suite.

## License

MIT
