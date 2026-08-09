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

echo "== exact clean candidate approval =="
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null
dispatch APPROVE "$(required_prompt)"
OUT="$(reviewctl record review-run-1 2>&1)"; rc=$?
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

echo "== unattributed and blocking results fail closed =="
reset_review
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null
dispatch APPROVE "Review this candidate without machine markers."
reviewctl record review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && ok "reply cannot spoof missing prompt scope" || bad "reply spoof approved"

reset_review
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null
dispatch APPROVE "$(required_prompt)
BASE_SHA: $BASE"
reviewctl record review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && ok "duplicate prompt scope is rejected" || bad "duplicated scope approved"

reset_review
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null
dispatch APPROVE "Introductory prose.
$(required_prompt)"
reviewctl record review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && ok "required scope must be the leading prompt block" || bad "non-leading scope approved"

reset_review
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null
dispatch APPROVE "\`\`\`
$(required_prompt)\`\`\`"
reviewctl record review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && ok "fenced prompt scope is rejected" || bad "fenced scope approved"

reset_review
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null
dispatch APPROVE "> REQUIRED_REVIEW
> BASE_SHA: $BASE
> CANDIDATE_SHA: $HEAD
> SPEC_PATH: docs/spec.md"
reviewctl record review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 11 ] && ok "quoted prompt scope is rejected" || bad "quoted scope approved"

reset_review
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null
dispatch $'REQUEST_CHANGES\nAPPROVE' "$(required_prompt)"
reviewctl record review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "contradictory verdicts do not approve" || bad "contradictory verdict approved"

reset_review
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null
dispatch $'APPROVE\nAdditional trailing analysis.' "$(required_prompt)"
reviewctl record review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "approval must be the final decision" || bad "non-final approval accepted"

reset_review
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null
dispatch '    APPROVE' "$(required_prompt)"
reviewctl record review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "indented code-block verdict is rejected" || bad "indented verdict approved"

reset_review
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null
dispatch $'```text\nAPPROVE\n```' "$(required_prompt)"
reviewctl record review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "fenced verdict is rejected" || bad "fenced verdict approved"

reset_review
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null
dispatch $'```text\n~~~\nAPPROVE\n~~~\n```' "$(required_prompt)"
reviewctl record review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "mixed fence markers cannot expose a verdict" || bad "mixed fences approved"

reset_review
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null
dispatch $'````text\n```\nAPPROVE' "$(required_prompt)"
reviewctl record review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "shorter fence cannot close a code block" || bad "short fence exposed approval"

reset_review
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null
dispatch $'```text\n```not-a-close\nAPPROVE' "$(required_prompt)"
reviewctl record review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "fence with trailing text cannot expose a verdict" || bad "invalid closing fence approved"

reset_review
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null
dispatch '> APPROVE' "$(required_prompt)"
reviewctl record review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "quoted verdict is rejected" || bad "quoted verdict approved"

reset_review
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 1 >/dev/null
dispatch REQUEST_CHANGES "$(required_prompt)"
reviewctl record review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "REQUEST_CHANGES at cap never approves" || bad "request changes approved"
reviewctl check review-run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "cap has no approval side effect" || bad "cap created approval"
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] && ok "cap is terminal until explicit thread reset" || bad "cap was silently restarted"

reset_review
reviewctl begin review-run-1 --base "$BASE" --spec docs/spec.md --cap 5 >/dev/null
dispatch APPROVE "$(required_prompt)"
reviewctl stop review-run-1 divergence >/dev/null 2>&1; rc=$?
[ "$rc" -eq 10 ] || bad "divergence stop did not hard-stop"
reviewctl record review-run-1 >/dev/null 2>&1; rc=$?
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
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$attempts" -eq 2 ]; then
  ok "concurrent begin calls retain both attempt increments"
else
  bad "concurrent begin lost state (rc=$rc1/$rc2 attempts=${attempts:-missing})"
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
if [ "$successes" -eq 5 ] && [ "$attempts" -eq 5 ] \
    && [ ! -e "$STATE/stale-contention.review-lock-reclaim" ]; then
  ok "concurrent stale takeover preserves serialization and cap"
else
  bad "stale takeover bypassed serialization (successes=$successes attempts=${attempts:-missing})"
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
mkdir -p "$STATE/reset-lock-run.review-lock"
printf '%s\n' "$$" > "$STATE/reset-lock-run.review-lock/owner"
CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" CODEX_CC_TRIAGE_STATE_DIR="$STATE" \
  bash "$DRIVER" new reset-lock-run >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 10 ] && [ -f "$STATE/reset-lock-run.review-lock/owner" ]; then
  ok "thread reset refuses an active required-review lock"
else
  bad "thread reset raced an active required-review operation"
fi
rm -f "$STATE/reset-lock-run.review-lock/owner"
rmdir "$STATE/reset-lock-run.review-lock"

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
if [ "$rc" -eq 0 ] \
    && [ ! -e "$CONFLICT_REPO/.git/codex-cc-triage/threads/stale.review-lock" ]; then
  ok "identical legacy state is accepted and transient review locks are not migrated"
else
  bad "identical legacy state or transient lock exclusion failed"
fi

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
  bad "stale migration takeover was not serialized"
fi

echo "PASS=$passes FAIL=$failures"
exit "$failures"
