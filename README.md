# codex-cc-triage

A Codex plugin for bounded, read-only Claude opinions. The owning agent chooses the skill from the task, checks the evidence and controls delivery. A requested Claude opinion or an existing external-review agreement supplies the authority for the call.

Since 0.8.0 every skill allows implicit invocation, so Codex can pick one from the task; an opinion still starts only on the user's request or a required review step, because it sends repository content to another provider.

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

## Required review and evidence

A new required review allows seven rounds; `--cap 1..7` sets fewer. A thread keeps its pinned base, spec and cap, including a thread started by 0.7.x. Each `begin` claims one round, and an abort before any result returns it. At `CAP_REACHED`, once the owner authorizes more rounds, `review-state.sh renew "$thread" --by "$owner"` resets the count on the same thread and Claude session.

Record the foreground result against its claim **before editing or committing**. The driver checks the actual comparison base, clean candidate, tree, fingerprint, spec, prompt and round. Only a current approval produces `CODEX_CC_REQUIRED_REVIEW APPROVE`. A reviewer timeout, a response stopped by the dollar cap or an unresolved finding leaves delivery pending. See [the exact protocol](plugins/codex-cc-triage/skills/claude-review/references/required-review.md) and [recovery](plugins/codex-cc-triage/skills/claude-thread/SKILL.md#recovery).

## Claude's access and state

The child runs with `--safe-mode`, `--permission-mode dontAsk`, `--strict-mcp-config` and the built-in Read, Glob and Grep tools. Codex gathers web, test, browser and database evidence within its own task permissions. A review request includes committed, staged, unstaged and untracked changes. An oversized context fails before the model call. A fingerprint check compares the Git worktree at the endpoints; keep the candidate stable throughout review.

Git thread state lives under `<git-common-dir>/codex-cc-triage/threads/` so named sessions survive worktree removal. The disposable Git context is self-ignored under `.agent-state/codex-cc-triage/`. Legacy state migration preserves its source. Status and recovery retain the known session ID and partial diagnostics after a response stopped by the dollar cap. Reset archives the named thread. Inspect archives before disposal.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `CODEX_CC_TRIAGE_CLAUDE_BIN` | `claude` | Claude Code executable |
| `CODEX_CC_TRIAGE_PYTHON_BIN` | `python3` | Python interpreter |
| `CODEX_CC_TRIAGE_MODEL` | `sonnet` | Claude model or alias |
| `CODEX_CC_TRIAGE_EFFORT` | Provider default | Effort, capability-checked when supplied |
| `CODEX_CC_TRIAGE_MAX_BUDGET_USD` | Unset (no ceiling) | Dollar ceiling for one Claude process, passed only when set |
| `CODEX_CC_TRIAGE_TIMEOUT_SECONDS` | 900 | Per-process wall-clock timeout |
| `CODEX_CC_TRIAGE_TARGET_REF` | Detected | Default review base |
| `CODEX_CC_TRIAGE_CONTEXT_LIMIT` | 5242880 | Complete review context limit, bytes |
| `CODEX_CC_TRIAGE_FILE_LIMIT` | 1048576 | Inline limit per untracked text file, bytes |
| `CODEX_CC_TRIAGE_REFRESH_CAPABILITIES` | 0 | Set to 1 after changing a Claude wrapper to refresh the help cache |

Run `bash tests/run.sh` for the offline regression suite.

## Contract for callers

Another tool can drive a required review through `plugins/codex-cc-triage/scripts/review-state.sh` without this plugin knowing it. These verbs, their exit codes and the marker line are a public contract.

| Verb | Result |
| --- | --- |
| `begin <thread> --base <ref> --spec <path> [--cap 1..7]` | Claims a round: `PENDING head=<sha> tree=<sha> fingerprint=<sha256> claim=<token> attempt=<n>/<cap>` |
| `header <thread>` | The four scope lines that open the review request |
| `record <thread> foreground <claim>` | Records the dispatched result; the marker on approval |
| `abort <thread> dispatch-failure\|timeout\|tool-failure <claim>` | Returns a round that produced no result; exits 10 with `ABORTED` |
| `stop <thread> cap\|divergence <claim>` | Ends a pending round without approval; exits 10 |
| `check <thread>` | The marker, while the approval covers the clean `HEAD` |
| `renew <thread> --by <who>` | After `CAP_REACHED`, resets the round count on the same thread |
| `mode <thread>` | `required` or `advisory` |

The request goes to `scripts/claude-thread.sh dispatch review <thread> <base>` on stdin and must start with the `header` lines.

Exit codes: 0 for `begin`, `header`, `mode`, `renew`, and `record` or `check` with the marker; 2 usage; 7 state or runtime failure, with a pending claim kept for retry; 10 refused by the lifecycle (`PENDING`, `REQUEST_CHANGES`, `NO_DECISION`, `CAP_REACHED`, `RENEW_REFUSED`, `NO_APPROVAL`, `INVALID_CLAIM_STATE` and similar, named on stderr); 11 `STALE`; 13 the candidate is not clean or the spec is untracked or a symlink; 14 the request does not start with the `header` lines.

The approval marker is one line:

```text
CODEX_CC_REQUIRED_REVIEW APPROVE thread=<thread> head=<sha> tree=<sha> fingerprint=<sha256> base_sha=<sha> spec_path=<path>
```

The first seven fields are separated by single spaces. `spec_path=` comes last and its value is the rest of the line: it may contain spaces and Unicode, so a caller reads it to the end of the line instead of splitting on whitespace.

## License

MIT
