---
name: claude-review
description: Use when the user explicitly asks Codex to have Claude Code review the current branch, worktree, implementation, or fixes, or when an owning workflow invokes the required exact-candidate review contract.
---

# Claude Review

Use Claude Code as a read-only reviewer. The wrapper builds a bounded branch snapshot containing
committed, staged, unstaged, and untracked changes. It hard-fails rather than truncating a diff.
Codex owns final triage and verification.

## Required delivery contract

An owning workflow may invoke this skill with the exact request:

```text
$codex-cc-triage:claude-review --required --base <ref> --spec <repo-relative-path> --thread <thread> --cap <1..5> <intent>
```

Treat these tokens as a machine contract, not prose. Require every flag, reject duplicate/unknown
flags, and reject a dirty candidate. Required mode is foreground and read-only; a timeout, tool
failure, missing verdict, cap, divergence, candidate movement, or `REQUEST_CHANGES` never approves.

1. Resolve `<plugin-root>`, then capture the candidate before dispatch:

   ```bash
   bash "<plugin-root>/scripts/review-state.sh" begin <thread> \
     --base <ref> --spec <repo-relative-path> --cap <1..5>
   ```

2. Read the canonical `head`, `base_sha`, and `spec_path` from the reported/state candidate. Prepend
   these exact lines to the unbiased review request:

   ```text
   REQUIRED_REVIEW
   BASE_SHA: <canonical base SHA>
   CANDIDATE_SHA: <candidate HEAD>
   SPEC_PATH: <repo-relative spec path>
   ```

   Ask Claude for complete correctness, architecture/systemic, security/data, and
   testing/operability review against the spec. Require its final decision on a standalone line:
   `APPROVE` or `REQUEST_CHANGES`. Do not seed suspected findings or cap their count.

3. Dispatch `review` to the explicit thread and canonical base using the ordinary driver command
   below. After it returns, immediately record and self-verify:

   ```bash
   bash "<plugin-root>/scripts/review-state.sh" record <thread>
   ```

   Only exit 0 is approval. Its final stdout line must be returned verbatim:

   ```text
   CODEX_CC_REQUIRED_REVIEW APPROVE thread=<thread> head=<sha> tree=<sha> fingerprint=<sha256> base_sha=<sha> spec_path=<path>
   ```

4. On `REQUEST_CHANGES`, validate the findings and return them to the owning workflow. It must enter
   its implementation fix transition, test and commit a new candidate, then invoke this same thread
   again. `--cap` limits paid repair rounds, not findings. At cap or divergence, call
   `review-state.sh stop <thread> <cap|divergence>` and hard-stop without a marker.

Never synthesize the marker from Claude prose. Only `review-state.sh record/check` may emit it.

## Advisory review

1. Inspect the branch and intended base ref yourself.
2. Resolve `<plugin-root>` as two directories above this skill's directory (the parent of
   `skills/`), not as the `skills/` directory itself.
3. Generate the thread name with the driver. On a feature branch, omit the source to use that
   branch; on `main`, `master`, or detached HEAD, pass a concise task label:

   ```bash
   thread="$(bash "<plugin-root>/scripts/claude-thread.sh" name review)"
   # On main, master, or detached HEAD:
   thread="$(bash "<plugin-root>/scripts/claude-thread.sh" name review "<task-label>")"
   ```

   Never reuse the result across unrelated changes.
4. Build a concise review request with the task intent, acceptance criteria, requested lenses, and
   any known test results. Do not bias Claude with your suspected findings.
5. Pass the integration target explicitly when known. The first round pins it to a commit; if that
   ref moves later, start a new thread instead of mixing review bases:

   ```bash
   bash "<plugin-root>/scripts/claude-thread.sh" \
     dispatch review "$thread" "<target-ref>" <<'CODEX_CC_TRIAGE_PROMPT'
   <prompt text>
   CODEX_CC_TRIAGE_PROMPT
   ```

   If no target is known, omit it; the driver tries `origin/main`, `main`, `origin/master`, then
   `master`, and otherwise reviews worktree changes against `HEAD`.

6. Validate every finding against the actual code. Fix accepted findings within scope and reject
   false positives explicitly.
7. Re-run the same thread after fixes. Each round regenerates the entire review snapshot and asks
   for a complete fresh review, so regressions introduced by fixes remain visible.
8. Report the thread name, accepted/rejected findings, fixes, and verification. Outside required
   mode, Claude approval is supporting evidence, not a delivery gate or substitute for tests.

If the driver exits non-zero, report its exact diagnostic. Do not silently create a fresh session
after a failed resume.

The Claude subprocess requires outbound network access. If Codex blocks it, request approval for
this bridge command or explain the narrow `workspace-write` network setting; never recommend
disabling sandboxing globally.
