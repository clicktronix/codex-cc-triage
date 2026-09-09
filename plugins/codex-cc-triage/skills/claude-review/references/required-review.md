## Required delivery contract

An owning workflow may invoke this skill with the exact request:

```text
$codex-cc-triage:claude-review --required --base <ref> --spec <repo-relative-path> --thread <thread> --cap <1..5> <intent>
```

Treat these tokens as a machine contract, not prose. Require every flag, reject duplicate/unknown
flags, and reject a dirty candidate. Required mode is foreground and read-only; a timeout, tool
failure, missing verdict, cap, divergence, candidate movement, or `REQUEST_CHANGES` never approves.

1. Resolve `<plugin-root>`, then capture the candidate before dispatch. Preserve the exact `claim`
   token printed by `begin`; it reserves this attempt and cannot be reused for another:

   ```bash
   bash "<plugin-root>/scripts/review-state.sh" begin <thread> \
     --base <ref> --spec <repo-relative-path> --cap <1..5>
   ```

2. Read the canonical `head`, `base_sha`, and `spec_path` from the reported/state candidate. The
   first four prompt lines must be exactly the following, in this order and exactly once:

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
   below. A second dispatch cannot share the same claim. After one successful foreground dispatch,
   immediately record and self-verify:

   ```bash
   bash "<plugin-root>/scripts/claude-thread.sh" \
     dispatch review <thread> <canonical-base-sha> <<'CODEX_CC_REQUIRED_PROMPT'
   REQUIRED_REVIEW
   BASE_SHA: <canonical-base-sha>
   CANDIDATE_SHA: <candidate-head-sha>
   SPEC_PATH: <canonical-spec-path>
   <unbiased review request and exact verdict instruction>
   CODEX_CC_REQUIRED_PROMPT

   bash "<plugin-root>/scripts/review-state.sh" record <thread> foreground <claim-token>
   ```

   Only exit 0 is approval. Its final stdout line must be returned verbatim:

   ```text
   CODEX_CC_REQUIRED_REVIEW APPROVE thread=<thread> head=<sha> tree=<sha> fingerprint=<sha256> base_sha=<sha> spec_path=<path>
   ```

4. If dispatch fails before producing a completed round, release only that claim with
   `review-state.sh abort <thread> <dispatch-failure|timeout|tool-failure> <claim-token>`. `abort`
   refuses a claim after any dispatch result was recorded and returns the unspent cap slot. A crash
   while publishing the returned slot remains fail-closed as `PENDING`.
   If `abort` reports `ROUND_COMPLETED`, record the completed round instead. For damaged
   claims or leases, follow [thread recovery](../../claude-thread/SKILL.md#recovery).
5. On `REQUEST_CHANGES`, validate every finding. Commit accepted fixes as a new clean candidate, or
   keep the same immutable candidate when all findings are explicitly refuted or explicitly waived by the user. Either
   path requires a fresh `begin`, one fresh review dispatch, and its new claim; review history alone
   is not approval. `--cap` counts `begin` claims including the first dispatch, not findings or five
   repair cycles.
6. `CAP_REACHED` and `DIVERGED` are terminal and never approve. If an owning workflow detects cap or
   divergence while a claim is still `PENDING`, call
   `review-state.sh stop <thread> <cap|divergence> <claim-token>`. Otherwise preserve the recorded
   terminal state. Continue safe repairs and return the missing approval to the owner in one request.
   Use [thread recovery](../../claude-thread/SKILL.md#recovery) for a new lifecycle after
   resolving divergence. Exhausting the review budget requires renewed user authorization;
   reuse an existing decision rather than asking again.

Never synthesize the marker from Claude prose. Only `review-state.sh record/check` may emit it.

The driver refuses a required comparison against another base before the paid call; record
also checks actual base metadata. After Python validation, a later reply or failed dispatch
revokes previous approval; a missing runtime leaves state intact. On a dead lease,
abort the unfinished claim and reuse this thread: recovery
preserves its session id and log. Do not reset merely to clear a stale process marker.

A clean candidate and endpoint fingerprints do not prove an immutable filesystem for
the entire call. Keep the candidate stable; the owner owns concurrent worktree activity.
