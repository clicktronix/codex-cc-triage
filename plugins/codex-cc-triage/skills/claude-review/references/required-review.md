# Required review

Use `--required --base <ref> --spec <repo-relative-path> --thread <name> [--cap N]` for a clean Git candidate. Use foreground, persistent mode. A new contract defaults to seven calls. Pass an explicit cap of 1–7 when the owner specifies one. Omit it on resume to preserve a pinned cap. Per-process USD and effort follow the [owner's budget](../../references/ownership.md).

## Claim and dispatch

Resolve the base to a literal commit, and keep it for the lifetime of the thread. Use a tracked spec. Quote paths throughout, including spaces and Unicode. From the candidate checkout:

```bash
gate="$plugin_root/scripts/review-state.sh"
driver="$plugin_root/scripts/claude-thread.sh"
begin=$(bash "$gate" begin "$thread" --base "$base" --spec "$spec" ${cap:+--cap "$cap"}) || exit $?
claim=${begin##* claim=}
claim=${claim%% *}
header=$(bash "$gate" header "$thread") || exit $?
printf '%s\n%s\n' "$header" "$review_request" | bash "$driver" dispatch review "$thread" "$base"
```

The header supplies the four scope lines exactly once. Include the complete review scope, acceptance evidence and instruction to end with `APPROVE` or `REQUEST_CHANGES`. A blocker needs a file and line. For an integration merge directly on an approved first parent, add `--integration` to `begin`. It spends one authorized call and preserves the attempt count.

## Record the result before editing

After the foreground result, including blocking findings, immediately run:

```bash
bash "$gate" record "$thread" foreground "$claim"
```

If the worker is still running, follow the same process. For a provider budget-exhausted result record the incomplete round. For a dispatch failure without a completed result, call `abort "$thread" dispatch-failure "$claim"` on the gate (other reasons are `timeout` and `tool-failure`). If it reports `ROUND_COMPLETED`, record the result. A rejected preflight costs zero; a launched call is spent, even if it fails.

Use `bash "$gate" check "$thread"` on the approved candidate. Its final line is the evidence for the owner:

```text
CODEX_CC_REQUIRED_REVIEW APPROVE thread=<thread> head=<sha> tree=<sha> fingerprint=<sha256> base_sha=<sha> spec_path=<path>
```

The final `spec_path=` value occupies the rest of the line. Preserve it intact. The owning workflow decides where it may publish.

## Continue on the same thread

- For `REQUEST_CHANGES`, validate the findings, make authorized repairs, verify affected criteria and begin a fresh round. If all findings are refuted or waived by the owner, a fresh review can cover the same SHA.
- `NO_FINDINGS` means the response requested changes without locating a blocker. The launched call consumes budget. Retry within the remaining grant. A technical integration retry covers the same merge. Blocking findings require a normal round.
- At `CAP_REACHED`, report missing approval once and continue safe repairs. With a new grant, call `bash "$gate" renew "$thread" --by "$owner" --rounds "$calls" --grant "$decision_id"`. Reuse that ID on replay. Omitting `--rounds` grants one call. A prior approval on a changed HEAD can be renewed directly once its grant is exhausted.
- For unresolved divergence, mark a pending claim with `stop "$thread" divergence "$claim"`. Follow [thread recovery](../../claude-thread/SKILL.md#recovery) for a damaged contract or a resolved divergence. Restore confirmed state or the remaining authorized grant. A thread reset grants no calls.

The candidate must remain stable during review. A clean fingerprint at each endpoint cannot establish what happened between them.
