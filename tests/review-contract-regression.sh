#!/usr/bin/env bash
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
DRIVER="$ROOT/plugins/codex-cc-triage/scripts/claude-thread.sh"
REVIEW_STATE="$ROOT/plugins/codex-cc-triage/scripts/review-state.sh"
STATE_HELPER="$ROOT/plugins/codex-cc-triage/scripts/state-dir.sh"
FAKE="$ROOT/tests/fixtures/fake-claude.sh"
T="$(mktemp -d)" || exit 1
REPO="$T/repo"; STATE="$REPO/.agent-state/codex-cc-triage"
ARGS_LOG="$T/args.log"; PROMPT_LOG="$T/prompt.log"
passes=0; failures=0
trap 'rm -rf "$T"' EXIT

ok() { echo "PASS $1"; passes=$((passes + 1)); }
bad() { echo "FAIL $1" >&2; failures=$((failures + 1)); }
reviewctl() {
  CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" CODEX_CC_TRIAGE_STATE_DIR="$STATE" \
    bash "$REVIEW_STATE" "$@"
}
begin_required() {
  begin_output="$(reviewctl begin "$@")" || return $?
  CLAIM="$(printf '%s\n' "$begin_output" | sed -n 's/.* claim=\([0-9a-f]*\) attempt=.*/\1/p')"
  [ -n "$CLAIM" ] || return 7
}
record_required() {
  reviewctl record "$1" foreground "$CLAIM"
}
dispatch() {
  result="$1"; prompt="$2"
  printf '%s\n' "$prompt" | env \
    CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" CODEX_CC_TRIAGE_STATE_DIR="$STATE" \
    CODEX_CC_TRIAGE_CLAUDE_BIN="$FAKE" CODEX_CC_TRIAGE_MODEL=haiku \
    CODEX_CC_TRIAGE_MAX_BUDGET_USD=0.25 FAKE_CLAUDE_RESULT="$result" \
    FAKE_CLAUDE_ARGS_LOG="$ARGS_LOG" FAKE_CLAUDE_PROMPT_LOG="$PROMPT_LOG" \
    FAKE_CLAUDE_PROJECT_DIR="$REPO" \
    bash "$DRIVER" dispatch review review-run-1 "$BASE" >/dev/null
}
required_prompt() {
  printf 'REQUIRED_REVIEW\nBASE_SHA: %s\nCANDIDATE_SHA: %s\nSPEC_PATH: docs/spec.md\nReview all material findings. End with a standalone verdict.\n' \
    "$BASE" "$HEAD"
}
reset_review() {
  CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" CODEX_CC_TRIAGE_STATE_DIR="$STATE" \
    bash "$DRIVER" new review-run-1 >/dev/null 2>&1 || true
}
reason_is() {
  [ "$(sed -n 's/^reason=//p' "$STATE/review-run-1.review-state")" = "$1" ]
}

mkdir -p "$REPO"
(
  cd "$REPO" && git init -q -b main && git config user.email test@example.com \
    && git config user.name test && mkdir -p docs \
    && printf '# Spec\n' > docs/spec.md && printf 'base\n' > file.txt \
    && printf '.agent-state/\n' > .gitignore \
    && git add docs/spec.md file.txt .gitignore && git commit -qm init \
    && git switch -qc task && printf 'feature\n' >> file.txt \
    && git add file.txt && git commit -qm feature
) || exit 1
BASE="$(git -C "$REPO" rev-parse main)"; HEAD="$(git -C "$REPO" rev-parse HEAD)"

status_output="$(CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" CODEX_CC_TRIAGE_STATE_DIR="$STATE" \
  bash "$DRIVER" status 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$status_output" | grep -q 'No Claude threads' \
    && [ ! -e "$STATE" ]; then
  ok "status is read-only before thread state exists"
else
  bad "status created or migrated state during a read-only lookup"
fi

echo "== exact clean candidate approval =="
LONG_THREAD="$(printf 'a%.0s' $(seq 1 81))"
reviewctl begin "$LONG_THREAD" --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$STATE/$LONG_THREAD.candidate" ] \
  && ok "required-review thread length matches the driver" \
  || bad "required-review accepted a thread longer than the driver"
for duplicate_case in \
  "base|--base does-not-exist --base $BASE --spec docs/spec.md --cap 5" \
  "spec|--base $BASE --spec missing.md --spec docs/spec.md --cap 5" \
  "cap|--base $BASE --spec docs/spec.md --cap 1 --cap 5"; do
  duplicate_name="${duplicate_case%%|*}"
  duplicate_args="${duplicate_case#*|}"
  # shellcheck disable=SC2086 -- the fixture intentionally expands one argument vector.
  reviewctl begin duplicate-run $duplicate_args >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$STATE/duplicate-run.candidate" ]; then
    ok "duplicate --$duplicate_name fails closed"
  else
    bad "duplicate --$duplicate_name was accepted"
    reviewctl reset duplicate-run >/dev/null 2>&1 || true
  fi
done

begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch APPROVE "$(required_prompt)"
OUT="$(record_required review-run-1 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -Eq \
  "^CODEX_CC_REQUIRED_REVIEW APPROVE thread=review-run-1 head=$HEAD tree=[0-9a-f]+ fingerprint=[0-9a-f]{64} base_sha=$BASE spec_path=docs/spec.md$"; then
  ok "exact approval emits the handoff marker"
else
  bad "exact approval marker (rc=$rc out=$OUT)"
fi

reviewctl begin canonical-run --base "$BASE" --spec ././docs/spec.md --cap 5 >/dev/null
if grep -qxF 'spec_path=docs/spec.md' "$STATE/canonical-run.candidate"; then
  ok "required spec path is canonicalized"
else
  bad "required spec path kept a leading ./"
fi

printf 'moved\n' >> "$REPO/file.txt"
reviewctl check review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && ok "worktree movement invalidates approval" || bad "moved approval was accepted"
git -C "$REPO" restore file.txt

echo "== required lifecycle ownership and attribution =="
reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
status_output="$(CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" CODEX_CC_TRIAGE_STATE_DIR="$STATE" \
  bash "$DRIVER" status review-run-1 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$status_output" | grep -q 'required=PENDING' \
    && printf '%s' "$status_output" | grep -q 'gate_eligible=false' \
    && printf '%s' "$status_output" | grep -Eq 'claim_expires_at=[0-9]+'; then
  ok "status exposes a required-only pending claim"
else
  bad "status hid the required pending state"
fi
dispatch APPROVE "$(required_prompt)"
reviewctl record review-run-1 foreground 0000000000000000000000000000000000000000 \
  >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 10 ] && grep -qxF status=PENDING "$STATE/review-run-1.review-state"; then
  ok "a mismatched claim cannot consume another invocation's review"
else
  bad "claim mismatch did not preserve the pending owner"
fi

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 3
dispatch REQUEST_CHANGES "$(required_prompt)"
record_required review-run-1 >/dev/null 2>&1; rc=$?
output="$(reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 2 2>&1)"; rc=$?
if [ "$rc" -eq 10 ] && printf '%s' "$output" | grep -q REVIEW_CONTRACT_CHANGED; then
  ok "base, spec, and cap stay pinned for the required lifecycle"
else
  bad "required lifecycle accepted a changed contract"
fi

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 1
dispatch REQUEST_CHANGES "$(required_prompt)"
dispatch APPROVE "$(required_prompt)"
record_required review-run-1 >/dev/null 2>&1; rc=$?
stale_reason="$(sed -n 's/^reason=//p' "$STATE/review-run-1.review-state")"
reviewctl check review-run-1 >/dev/null 2>&1; check_rc=$?
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 1 \
  >/dev/null 2>&1; cap_rc=$?
if [ "$rc" -eq 11 ] && [ "$stale_reason" = round_counter_mismatch ] \
    && [ "$check_rc" -eq 10 ] && [ "$cap_rc" -eq 10 ] \
    && grep -qxF status=CAP_REACHED "$STATE/review-run-1.review-state"; then
  ok "two dispatches cannot turn a cap-1 REQUEST_CHANGES into approval"
else
  bad "multiple dispatches were attributed to one cap-1 claim"
fi

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 2
dispatch REQUEST_CHANGES "$(required_prompt)"
record_required review-run-1 >/dev/null 2>&1; rc=$?
first_claim="$CLAIM"
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 2
second_claim="$CLAIM"
dispatch APPROVE "$(required_prompt)"
OUT="$(record_required review-run-1 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$first_claim" != "$second_claim" ] \
    && printf '%s' "$OUT" | grep -q '^CODEX_CC_REQUIRED_REVIEW APPROVE '; then
  ok "refuted or deferred findings require a fresh review of the same candidate"
else
  bad "same-candidate reconsideration did not require and accept a fresh claim"
fi

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 2
dispatch APPROVE "$(required_prompt)"
reviewctl abort review-run-1 timeout "$CLAIM" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 10 ] && grep -qxF status=PENDING "$STATE/review-run-1.review-state"; then
  ok "abort cannot discard a completed dispatch result"
else
  bad "abort discarded completed review evidence"
fi
record_required review-run-1 >/dev/null 2>&1 || bad "completed dispatch could not be recorded after refused abort"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 2
reviewctl abort review-run-1 tool-failure "$CLAIM" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 10 ] && grep -qxF status=ABORTED "$STATE/review-run-1.review-state"; then
  ok "abort releases only an unfinished claimed round"
else
  bad "abort did not record the required failure state"
fi
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 2
reviewctl stop review-run-1 divergence "$CLAIM" >/dev/null 2>&1; rc=$?
blocked="$(reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 2 2>&1)"; blocked_rc=$?
status_output="$(CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" CODEX_CC_TRIAGE_STATE_DIR="$STATE" \
  bash "$DRIVER" status review-run-1 2>&1)"; status_rc=$?
if [ "$rc" -eq 10 ] && [ "$blocked_rc" -eq 10 ] \
    && printf '%s' "$blocked" | grep -q DIVERGED \
    && [ "$status_rc" -eq 0 ] && printf '%s' "$status_output" | grep -q 'required=DIVERGED'; then
  ok "divergence is a terminal hard stop"
else
  bad "terminal divergence was restartable"
fi
reviewctl reset review-run-1 >/dev/null
if begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 1; then
  ok "explicit reset starts a fresh required lifecycle"
else
  bad "explicit reset did not clear terminal required state"
fi
reviewctl advisory-check review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "advisory review cannot reuse a required thread" \
  || bad "advisory review reused required state"
reset_review
reviewctl advisory-check review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "advisory review is separate from required state" \
  || bad "advisory review remained reserved after reset"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 2
dispatch APPROVE "$(required_prompt)"
reviewctl record review-run-1 background "$CLAIM" >/dev/null 2>&1; rc=$?
reviewctl check review-run-1 >/dev/null 2>&1; check_rc=$?
if [ "$rc" -eq 0 ] && [ "$check_rc" -eq 10 ] \
    && grep -qxF status=BACKGROUND_SINGLE_PASS "$STATE/review-run-1.review-state"; then
  ok "background approval never satisfies the required gate"
else
  bad "background approval became gate-eligible"
fi

echo "== granular stale reasons =="
reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch APPROVE "$(required_prompt)"
printf 'dirty\n' >> "$REPO/file.txt"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && reason_is dirty_worktree \
  && ok "dirty worktree has a distinct stale reason" \
  || bad "dirty worktree stale reason"
git -C "$REPO" restore file.txt

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch APPROVE "$(required_prompt)"
CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" CODEX_CC_TRIAGE_STATE_DIR="$STATE" \
  CODEX_CC_TRIAGE_PYTHON_BIN=/bin/false \
  bash "$REVIEW_STATE" record review-run-1 foreground "$CLAIM" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && reason_is fingerprint_unavailable \
  && ok "unavailable fingerprint has a distinct stale reason" \
  || bad "unavailable fingerprint stale reason"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch APPROVE "$(required_prompt)"
printf 'next head\n' >> "$REPO/file.txt"
git -C "$REPO" add file.txt && git -C "$REPO" commit -qm 'move head'
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && reason_is head_moved \
  && ok "moved HEAD has a distinct stale reason" \
  || bad "moved HEAD stale reason"
git -C "$REPO" reset -q --hard HEAD^

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch APPROVE "$(required_prompt)"
sed -i.bak 's/^tree=.*/tree=0000000000000000000000000000000000000000/' "$STATE/review-run-1.candidate"
rm -f "$STATE/review-run-1.candidate.bak"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && reason_is tree_moved \
  && ok "tree mismatch has a distinct stale reason" \
  || bad "tree mismatch stale reason"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch APPROVE "$(required_prompt)"
sed -i.bak 's/^fingerprint=.*/fingerprint=0000000000000000000000000000000000000000000000000000000000000000/' "$STATE/review-run-1.candidate"
rm -f "$STATE/review-run-1.candidate.bak"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && reason_is content_fingerprint_changed \
  && ok "content fingerprint mismatch has a distinct stale reason" \
  || bad "content fingerprint stale reason"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch APPROVE "$(required_prompt)"
printf '%064d\n' 0 > "$STATE/review-run-1.last-fingerprint"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && reason_is verdict_not_attributable_to_this_candidate \
  && ok "review attribution mismatch has a distinct stale reason" \
  || bad "review attribution stale reason"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch APPROVE "Review without the required scope."
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && reason_is prompt_scope_mismatch \
  && ok "prompt scope mismatch has a distinct stale reason" \
  || bad "prompt scope stale reason"

echo "== unattributed and blocking results fail closed =="
reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch APPROVE "Review this candidate without machine markers."
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && ok "reply cannot spoof missing prompt scope" || bad "reply spoof approved"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch APPROVE "$(required_prompt)
BASE_SHA: $BASE"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && ok "duplicate prompt scope is rejected" || bad "duplicated scope approved"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch APPROVE "Introductory prose.
$(required_prompt)"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && ok "required scope must be the leading prompt block" || bad "non-leading scope approved"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch APPROVE "\`\`\`
$(required_prompt)\`\`\`"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && ok "fenced prompt scope is rejected" || bad "fenced scope approved"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch APPROVE "> REQUIRED_REVIEW
> BASE_SHA: $BASE
> CANDIDATE_SHA: $HEAD
> SPEC_PATH: docs/spec.md"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && ok "quoted prompt scope is rejected" || bad "quoted scope approved"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch $'REQUEST_CHANGES\nAPPROVE' "$(required_prompt)"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "contradictory verdicts do not approve" || bad "contradictory verdict approved"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch $'APPROVE\nAdditional trailing analysis.' "$(required_prompt)"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "approval must be the final decision" || bad "non-final approval accepted"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch '    APPROVE' "$(required_prompt)"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "indented code-block verdict is rejected" || bad "indented verdict approved"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch $'```text\nAPPROVE\n```' "$(required_prompt)"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "fenced verdict is rejected" || bad "fenced verdict approved"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch $'```text\n~~~\nAPPROVE\n~~~\n```' "$(required_prompt)"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "mixed fence markers cannot expose a verdict" || bad "mixed fences approved"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch $'````text\n```\nAPPROVE' "$(required_prompt)"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "shorter fence cannot close a code block" || bad "short fence exposed approval"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch $'```text\n```not-a-close\nAPPROVE' "$(required_prompt)"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "fence with trailing text cannot expose a verdict" || bad "invalid closing fence approved"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch '> APPROVE' "$(required_prompt)"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "quoted verdict is rejected" || bad "quoted verdict approved"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 1
dispatch REQUEST_CHANGES "$(required_prompt)"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "REQUEST_CHANGES at cap never approves" || bad "request changes approved"
reviewctl check review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "cap has no approval side effect" || bad "cap created approval"
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "cap is terminal until explicit thread reset" || bad "cap was silently restarted"

reset_review
begin_required review-run-1 --base "$BASE" --spec docs/spec.md --cap 5
dispatch APPROVE "$(required_prompt)"
reviewctl stop review-run-1 divergence "$CLAIM" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] || bad "divergence stop did not hard-stop"
record_required review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "record cannot overwrite a terminal divergence" || bad "record overwrote divergence"
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "divergence is terminal until explicit thread reset" || bad "divergence was silently restarted"
reviewctl check review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "terminal divergence cannot produce approval" || bad "divergence produced approval"

echo "== review-state operations are serialized =="
reset_review
reviewctl begin concurrent-run --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null & p1=$!
reviewctl begin concurrent-run --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null & p2=$!
wait "$p1"; rc1=$?; wait "$p2"; rc2=$?
attempts="$(sed -n 's/^attempts=//p' "$STATE/concurrent-run.review-loop")"
successes=0
[ "$rc1" -eq 0 ] && successes=$((successes + 1))
[ "$rc2" -eq 0 ] && successes=$((successes + 1))
if [ "$successes" -eq 1 ] && [ "$attempts" -eq 1 ]; then
  ok "a pending claim rejects a concurrent begin without spending another attempt"
else
  bad "concurrent begin bypassed pending ownership (rc=$rc1/$rc2 attempts=${attempts:-missing})"
fi
mkdir "$STATE/stale-contention.review-lock"
printf '99999999\n' > "$STATE/stale-contention.review-lock/owner"
pids=""
for n in 1 2 3 4 5 6 7 8; do
  reviewctl begin stale-contention --base "$BASE" --spec docs/spec.md --cap 5 \
    >/dev/null 2>&1 &
  pids="$pids $!"
done
successes=0
for pid in $pids; do
  wait "$pid" && successes=$((successes + 1))
done
attempts="$(sed -n 's/^attempts=//p' "$STATE/stale-contention.review-loop")"
if [ "$successes" -eq 1 ] && [ "$attempts" -eq 1 ] \
    && [ ! -e "$STATE/stale-contention.review-lock-reclaim" ]; then
  ok "concurrent stale takeover preserves one pending claim"
else
  bad "stale takeover bypassed serialization (successes=$successes attempts=${attempts:-missing})"
fi
mkdir "$STATE/stale-dispatch.active"
printf '99999999\n' > "$STATE/stale-dispatch.active/pid"
mkdir "$STATE/stale-dispatch.active-reclaim"
printf '99999998\n' > "$STATE/stale-dispatch.active-reclaim/pid"
pids=""
for n in 1 2 3 4 5 6 7 8; do
  (
    printf 'Review the stale-lock contender.\n' | env \
      CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" CODEX_CC_TRIAGE_STATE_DIR="$STATE" \
      CODEX_CC_TRIAGE_CLAUDE_BIN="$FAKE" CODEX_CC_TRIAGE_MODEL=haiku \
      CODEX_CC_TRIAGE_MAX_BUDGET_USD=0.25 FAKE_CLAUDE_RESULT=APPROVE \
      FAKE_CLAUDE_SLEEP_SECONDS=0.5 \
      FAKE_CLAUDE_ARGS_LOG="$T/stale-dispatch-args-$n.log" \
      FAKE_CLAUDE_PROMPT_LOG="$T/stale-dispatch-prompt-$n.log" \
      FAKE_CLAUDE_PROJECT_DIR="$REPO" \
      bash "$DRIVER" dispatch review stale-dispatch "$BASE" >/dev/null 2>&1
    printf '%s\n' "$?" > "$T/stale-dispatch-status-$n"
  ) &
  pids="$pids $!"
done
for pid in $pids; do wait "$pid"; done
successes=0
for n in 1 2 3 4 5 6 7 8; do
  [ "$(cat "$T/stale-dispatch-status-$n")" -eq 0 ] && successes=$((successes + 1))
done
rounds="$(grep -Ec '^## .* mode=review$' "$STATE/stale-dispatch.log" 2>/dev/null || true)"
if [ "$successes" -eq 1 ] && [ "${rounds:-0}" -eq 1 ] \
    && [ ! -e "$STATE/stale-dispatch.active" ] \
    && [ ! -e "$STATE/stale-dispatch.active-reclaim" ]; then
  ok "concurrent stale dispatch-lock takeover preserves one dispatch"
else
  bad "stale dispatch-lock takeover bypassed serialization (successes=$successes rounds=${rounds:-0})"
fi
mkdir "$STATE/orphan-reclaimer.active" "$STATE/orphan-reclaimer.active-reclaim"
printf '99999999\n' > "$STATE/orphan-reclaimer.active/pid"
printf '99999998\n' > "$STATE/orphan-reclaimer.active-reclaim/pid"
CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" CODEX_CC_TRIAGE_STATE_DIR="$STATE" \
  bash "$DRIVER" new orphan-reclaimer >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$STATE/orphan-reclaimer.active" ] \
    && [ ! -e "$STATE/orphan-reclaimer.active-reclaim" ]; then
  ok "thread reset reclaims an orphaned dispatch reclaimer"
else
  bad "orphaned dispatch reclaimer permanently blocked the thread"
fi
mkdir -p "$T/outside-review-lock"
printf 'outside-owner\n' > "$T/outside-review-lock/owner"
ln -s "$T/outside-review-lock" "$STATE/symlink-lock-run.review-lock"
reviewctl begin symlink-lock-run --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 7 ] && grep -qxF outside-owner "$T/outside-review-lock/owner"; then
  ok "symlinked review-state lock is rejected without touching its target"
else
  bad "symlinked review-state lock was followed"
fi
mkdir -p "$T/outside-active"
printf '%s\n' "$$" > "$T/outside-active/pid"
ln -s "$T/outside-active" "$STATE/symlink-active-run.active"
reviewctl begin symlink-active-run --base "$BASE" --spec docs/spec.md --cap 5 \
  >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 7 ] && grep -qxF "$$" "$T/outside-active/pid"; then
  ok "symlinked dispatch lease is rejected without touching its target"
else
  bad "symlinked dispatch lease was followed"
fi
mkdir "$STATE/malformed-active-run.active"
printf 'not-a-pid\n' > "$STATE/malformed-active-run.active/pid"
reviewctl begin malformed-active-run --base "$BASE" --spec docs/spec.md --cap 5 \
  >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 10 ] && [ ! -f "$STATE/malformed-active-run.candidate" ]; then
  ok "malformed dispatch lease fails closed"
else
  bad "malformed dispatch lease was treated as free"
fi
printf 'outside-log\n' > "$T/outside-thread.log"
ln "$T/outside-thread.log" "$STATE/hardlink-run.log"
printf 'Review without mutating a linked log.\n' | env \
  CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" CODEX_CC_TRIAGE_STATE_DIR="$STATE" \
  CODEX_CC_TRIAGE_CLAUDE_BIN="$FAKE" CODEX_CC_TRIAGE_MODEL=haiku \
  CODEX_CC_TRIAGE_MAX_BUDGET_USD=0.25 FAKE_CLAUDE_RESULT=APPROVE \
  FAKE_CLAUDE_ARGS_LOG="$ARGS_LOG" FAKE_CLAUDE_PROMPT_LOG="$PROMPT_LOG" \
  FAKE_CLAUDE_PROJECT_DIR="$REPO" \
  bash "$DRIVER" dispatch review hardlink-run "$BASE" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 7 ] && grep -qxF outside-log "$T/outside-thread.log"; then
  ok "multiply-linked thread log is rejected before append"
else
  bad "driver appended through a multiply-linked thread log"
fi
rm -f "$STATE/hardlink-run.log"
mkdir -p "$STATE/reset-lock-run.review-lock"
printf '%s\n' "$$" > "$STATE/reset-lock-run.review-lock/owner"
reset_lock_output="$(CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" CODEX_CC_TRIAGE_STATE_DIR="$STATE" \
  bash "$DRIVER" new reset-lock-run 2>&1)"; rc=$?
if [ "$rc" -eq 10 ] && [ -f "$STATE/reset-lock-run.review-lock/owner" ]; then
  ok "thread reset refuses an active required-review lock"
else
  bad "thread reset raced an active required-review operation (rc=$rc output=$reset_lock_output)"
fi
rm -f "$STATE/reset-lock-run.review-lock/owner"
rmdir "$STATE/reset-lock-run.review-lock"
mkdir -p "$STATE/stale-reset-lock-run.review-lock"
printf '99999999\n' > "$STATE/stale-reset-lock-run.review-lock/owner"
CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" CODEX_CC_TRIAGE_STATE_DIR="$STATE" \
  bash "$DRIVER" new stale-reset-lock-run >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$STATE/stale-reset-lock-run.review-lock" ]; then
  ok "thread reset reclaims a dead required-review lock"
else
  bad "thread reset could not recover a dead required-review lock"
fi

printf 'dirty\n' >> "$REPO/file.txt"
reviewctl begin dirty-run --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 13 ] && ok "dirty candidate is rejected" || bad "dirty candidate accepted"
git -C "$REPO" restore file.txt

printf 'tracked\n' > "$REPO/.agent-state/codex-cc-triage/tracked.txt"
git -C "$REPO" add -f .agent-state/codex-cc-triage/tracked.txt
git -C "$REPO" commit -qm 'track forbidden state'
reviewctl begin tracked-run --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 13 ] && ok "tracked context state invalidates a candidate" || bad "tracked context state was excluded"
git -C "$REPO" reset -q --hard HEAD^

echo "== common Git state survives worktree removal =="
unset CODEX_CC_TRIAGE_STATE_DIR
git -C "$REPO" branch disposable
git -C "$REPO" worktree add -q "$T/disposable" disposable
SHARED="$(CODEX_CC_TRIAGE_PROJECT_DIR="$T/disposable" bash "$STATE_HELPER")"
printf 'Advisory persistence check.\n' | env \
  CODEX_CC_TRIAGE_PROJECT_DIR="$T/disposable" CODEX_CC_TRIAGE_CLAUDE_BIN="$FAKE" \
  CODEX_CC_TRIAGE_MODEL=haiku CODEX_CC_TRIAGE_MAX_BUDGET_USD=0.25 \
  FAKE_CLAUDE_RESULT=APPROVE FAKE_CLAUDE_ARGS_LOG="$ARGS_LOG" \
  FAKE_CLAUDE_PROMPT_LOG="$PROMPT_LOG" FAKE_CLAUDE_PROJECT_DIR="$T/disposable" \
  bash "$DRIVER" dispatch review review-disposable main >/dev/null
CONTEXT="$T/disposable/.agent-state/codex-cc-triage/review-disposable.context.md"
if [ -f "$SHARED/review-disposable.id" ] && [ -f "$CONTEXT" ] \
  && grep -Fq "$CONTEXT" "$PROMPT_LOG"; then
  ok "shared thread uses a readable worktree-local context"
else
  bad "thread/context ownership was mixed"
fi
git -C "$REPO" worktree remove -f "$T/disposable"
AFTER="$(CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" bash "$STATE_HELPER" --read-only)"
if [ "$SHARED" = "$AFTER" ] && [ -f "$AFTER/review-disposable.id" ]; then
  ok "thread state survives disposable worktree removal"
else
  bad "shared thread state was lost"
fi

echo "== legacy migration fails closed =="
SYMLINK_REPO="$T/symlink-repo"; SYMLINK_TARGET="$T/symlink-target"
mkdir -p "$SYMLINK_REPO/.agent-state" "$SYMLINK_TARGET"
git -C "$SYMLINK_REPO" init -q -b main
printf 'outside\n' > "$SYMLINK_TARGET/legacy.id"
ln -s "$SYMLINK_TARGET" "$SYMLINK_REPO/.agent-state/codex-cc-triage"
CODEX_CC_TRIAGE_PROJECT_DIR="$SYMLINK_REPO" bash "$STATE_HELPER" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 7 ] && [ ! -e "$SYMLINK_REPO/.git/codex-cc-triage/threads/legacy.id" ]; then
  ok "symlinked legacy directory is rejected without migration"
else
  bad "symlinked legacy directory was followed"
fi

PARENT_SYMLINK_REPO="$T/parent-symlink-repo"
PARENT_SYMLINK_TARGET="$T/parent-symlink-target"
mkdir -p "$PARENT_SYMLINK_REPO" "$PARENT_SYMLINK_TARGET/codex-cc-triage"
git -C "$PARENT_SYMLINK_REPO" init -q -b main
printf 'outside\n' > "$PARENT_SYMLINK_TARGET/codex-cc-triage/legacy.id"
ln -s "$PARENT_SYMLINK_TARGET" "$PARENT_SYMLINK_REPO/.agent-state"
CODEX_CC_TRIAGE_PROJECT_DIR="$PARENT_SYMLINK_REPO" bash "$STATE_HELPER" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 7 ] && [ ! -e "$PARENT_SYMLINK_REPO/.git/codex-cc-triage/threads/legacy.id" ]; then
  ok "symlinked legacy parent is rejected without migration"
else
  bad "symlinked legacy parent was followed"
fi

CONFLICT_REPO="$T/conflict-repo"
git -C "$T" init -q -b main conflict-repo
mkdir -p "$CONFLICT_REPO/.agent-state/codex-cc-triage" \
  "$CONFLICT_REPO/.git/codex-cc-triage/threads"
printf 'legacy\n' > "$CONFLICT_REPO/.agent-state/codex-cc-triage/thread.id"
printf 'shared\n' > "$CONFLICT_REPO/.git/codex-cc-triage/threads/thread.id"
CODEX_CC_TRIAGE_PROJECT_DIR="$CONFLICT_REPO" bash "$STATE_HELPER" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 7 ] && grep -qxF shared "$CONFLICT_REPO/.git/codex-cc-triage/threads/thread.id"; then
  ok "conflicting legacy state aborts without overwriting shared state"
else
  bad "conflicting legacy state did not fail closed"
fi
CODEX_CC_TRIAGE_PROJECT_DIR="$CONFLICT_REPO" bash "$STATE_HELPER" --read-only >/dev/null 2>&1; rc=$?
[ "$rc" -eq 7 ] && ok "read-only lookup also rejects conflicting legacy state" \
  || bad "read-only lookup continued with ambiguous shared state"
printf 'shared\n' > "$CONFLICT_REPO/.agent-state/codex-cc-triage/thread.id"
mkdir "$CONFLICT_REPO/.agent-state/codex-cc-triage/stale.review-lock"
printf '123\n' > "$CONFLICT_REPO/.agent-state/codex-cc-triage/stale.review-lock/owner"
CODEX_CC_TRIAGE_PROJECT_DIR="$CONFLICT_REPO" bash "$STATE_HELPER" >/dev/null 2>&1; rc=$?
MIGRATION_MARKER="$(find "$CONFLICT_REPO/.git/codex-cc-triage/migrations" -type f -name '*.state-v1' -print 2>/dev/null | head -1)"
CONFLICT_CANON="$(cd "$CONFLICT_REPO" && pwd -P)"
if [ "$rc" -eq 0 ] \
    && [ ! -e "$CONFLICT_REPO/.git/codex-cc-triage/threads/stale.review-lock" ] \
    && [ -n "$MIGRATION_MARKER" ] \
    && grep -qxF "legacy_dir=$CONFLICT_CANON/.agent-state/codex-cc-triage" "$MIGRATION_MARKER"; then
  ok "identical legacy state publishes a source-specific migration marker"
else
  bad "identical legacy state, transient lock exclusion, or migration marker failed"
fi
printf 'late legacy mutation\n' > "$CONFLICT_REPO/.agent-state/codex-cc-triage/thread.id"
CODEX_CC_TRIAGE_PROJECT_DIR="$CONFLICT_REPO" bash "$STATE_HELPER" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] \
    && grep -qxF shared "$CONFLICT_REPO/.git/codex-cc-triage/threads/thread.id"; then
  ok "completed migration ignores later legacy drift"
else
  bad "completed migration re-imported later legacy drift"
fi

DIRECTORY_REPO="$T/directory-repo"
git -C "$T" init -q -b main directory-repo
mkdir -p "$DIRECTORY_REPO/.agent-state/codex-cc-triage/nested"
CODEX_CC_TRIAGE_PROJECT_DIR="$DIRECTORY_REPO" bash "$STATE_HELPER" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 7 ] && ok "legacy directories are rejected instead of recursively migrated" \
  || bad "legacy directory was recursively migrated"

STALE_MIGRATION_REPO="$T/stale-migration-repo"
git -C "$T" init -q -b main stale-migration-repo
mkdir -p "$STALE_MIGRATION_REPO/.agent-state/codex-cc-triage" \
  "$STALE_MIGRATION_REPO/.git/codex-cc-triage/migration.lock"
printf 'legacy\n' > "$STALE_MIGRATION_REPO/.agent-state/codex-cc-triage/thread.id"
printf '99999999\n' > "$STALE_MIGRATION_REPO/.git/codex-cc-triage/migration.lock/owner"
pids=""
for n in 1 2 3 4 5 6 7 8; do
  CODEX_CC_TRIAGE_PROJECT_DIR="$STALE_MIGRATION_REPO" \
    bash "$STATE_HELPER" > "$T/stale-migration-$n.out" 2>/dev/null &
  pids="$pids $!"
done
successes=0
for pid in $pids; do
  wait "$pid" && successes=$((successes + 1))
done
if [ "$successes" -eq 8 ] \
    && grep -qxF legacy "$STALE_MIGRATION_REPO/.git/codex-cc-triage/threads/thread.id" \
    && [ ! -e "$STALE_MIGRATION_REPO/.git/codex-cc-triage/migration.lock" ] \
    && [ ! -e "$STALE_MIGRATION_REPO/.git/codex-cc-triage/migration-reclaim.lock" ]; then
  ok "concurrent stale migration takeover preserves one unambiguous state"
else
  bad "stale migration takeover was not serialized (successes=$successes)"
fi

echo "PASS=$passes FAIL=$failures"
exit "$failures"
