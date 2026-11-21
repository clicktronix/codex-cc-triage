# Required review

Use `--required --base <ref> --spec <repo-relative-path> --thread <name> [--cap N]` for a clean Git candidate. Use foreground, persistent mode. A new contract allows seven rounds. Pass an explicit cap of 1–7 when the owner specifies one. Omit it on resume to preserve a pinned cap. Model and effort follow the [ownership rules](../../references/ownership.md).

## Claim and dispatch

Resolve the base to a literal commit, and keep it for the lifetime of the thread. Use a tracked spec. Quote paths throughout, including spaces and Unicode. From the candidate checkout, fill the placeholders and run:

```bash
thread='<thread>' base='<base-sha>' spec='<spec-path>' cap='<1-7, or empty to keep the pinned cap>'
gate="<plugin-root>/scripts/review-state.sh"
bash "$gate" begin "$thread" --base "$base" --spec "$spec" ${cap:+--cap "$cap"} || exit $?
header=$(bash "$gate" header "$thread") || exit $?
{ printf '%s\n' "$header"; cat; } <<'CODEX_CC_TRIAGE_PROMPT' | bash "<plugin-root>/scripts/claude-thread.sh" dispatch review "$thread" "$base"
<complete review scope, acceptance evidence and the instruction to end with APPROVE or REQUEST_CHANGES>
CODEX_CC_TRIAGE_PROMPT
```

`begin` prints `PENDING ... claim=<claim> attempt=<n>/<cap>`; keep that claim for `record`. The header supplies the four scope lines exactly once. A blocker needs a file and line. A merge that integrates an advanced target is a new candidate and takes an ordinary round.

## Record the result before editing

After the foreground result, including blocking findings, immediately run:

```bash
bash "<plugin-root>/scripts/review-state.sh" record "<thread>" foreground "<claim>"
```

If the dispatch is still running (`claude-thread.sh status "<thread>"` shows `state=busy`), wait for that process to exit, then run the same `record` command. For a response stopped by the dollar cap, record the incomplete round. For a dispatch failure without a completed result, run `review-state.sh abort "<thread>" dispatch-failure "<claim>"` (other reasons are `timeout` and `tool-failure`); it returns the round. If it reports `ROUND_COMPLETED`, record the result instead. A dispatch refused before Claude starts (exit 10, 11 or 14) leaves the claim pending: correct the request and dispatch again.

Use `review-state.sh check "<thread>"` on the approved candidate. Its final line is the evidence for the owner:

```text
CODEX_CC_REQUIRED_REVIEW APPROVE thread=<thread> head=<sha> tree=<sha> fingerprint=<sha256> base_sha=<sha> spec_path=<path>
```

The final `spec_path=` value occupies the rest of the line. Preserve it intact. The owning workflow decides where it may publish.

## Continue on the same thread

- For `REQUEST_CHANGES`, validate the findings, make authorized repairs, verify affected criteria and begin a fresh round. If all findings are refuted or waived by the owner, a fresh review can cover the same SHA.
- At `CAP_REACHED`, report missing approval once and continue safe repairs. When the owner authorizes more rounds, run `review-state.sh renew "<thread>" --by "<owner>"`. It resets the round count and keeps the base, spec, cap and Claude session. It accepts only a `CAP_REACHED` thread, so a second renewal needs a round in between.
- For unresolved divergence, mark a pending claim with `review-state.sh stop "<thread>" divergence "<claim>"`. Follow [thread recovery](../../claude-thread/SKILL.md#recovery) for a damaged contract or a resolved divergence. Restore confirmed state. A thread reset adds no rounds.

The candidate must remain stable during review. A clean fingerprint at each endpoint cannot establish what happened between them.
