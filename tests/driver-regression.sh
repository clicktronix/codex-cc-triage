#!/usr/bin/env bash
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
DRIVER="$ROOT/plugins/codex-cc-triage/scripts/claude-thread.sh"
FAKE="$ROOT/tests/fixtures/fake-claude.sh"
TMP="$(mktemp -d)" || exit 1
REPO="$TMP/repo"
ARGS_LOG="$TMP/args.log"
PROMPT_LOG="$TMP/prompt.log"
STATE_REL=".agent-state/codex-cc-triage"
failures=0

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

pass() {
  echo "PASS $1"
}

fail() {
  echo "FAIL $1" >&2
  failures=$((failures + 1))
}

run_bridge() {
  prompt="$1"
  shift
  printf '%s' "$prompt" | env \
    CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" \
    CODEX_CC_TRIAGE_CLAUDE_BIN="$FAKE" \
    CODEX_CC_TRIAGE_MODEL="haiku" \
    CODEX_CC_TRIAGE_MAX_BUDGET_USD="0.25" \
    FAKE_CLAUDE_ARGS_LOG="$ARGS_LOG" \
    FAKE_CLAUDE_PROMPT_LOG="$PROMPT_LOG" \
    FAKE_CLAUDE_PROJECT_DIR="$REPO" \
    "$@" \
    bash "$DRIVER" "${BRIDGE_ARGS[@]}"
}

mkdir -p "$REPO"
(
  cd "$REPO" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name test
  git checkout -qb main
  printf 'base\n' > tracked.txt
  printf 'stable\n' > mutable.txt
  git add tracked.txt mutable.txt
  git commit -qm init
  git checkout -qb feat/billing
  printf 'committed feature\n' >> tracked.txt
  git add tracked.txt
  git commit -qm feature
  printf 'unstaged feature\n' >> tracked.txt
  printf 'new file\n' > untracked.txt
) || exit 1
EXCLUDE_BEFORE="$(cat "$REPO/.git/info/exclude" 2>/dev/null || true)"
MAIN_BASE="$(git -C "$REPO" rev-parse main)"

: > "$ARGS_LOG"
BRIDGE_ARGS=(dispatch review review-feat-billing main)
output="$(run_bridge "Review billing changes" env 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$output" | grep -q 'FAKE_INITIAL' \
  && printf '%s' "$output" | grep -q '"cost_usd":0.0123' \
  && [ -f "$REPO/$STATE_REL/review-feat-billing.id" ] \
  && [ "$(cat "$REPO/$STATE_REL/review-feat-billing.base")" = "$MAIN_BASE" ] \
  && grep -q 'Review billing changes' "$PROMPT_LOG"; then
  pass "initial review persists session"
else
  fail "initial review persists session (rc=$rc, output=$output)"
fi

context="$REPO/$STATE_REL/review-feat-billing.context.md"
if grep -q 'committed feature' "$context" \
  && grep -q 'unstaged feature' "$context" \
  && grep -q 'new file' "$context"; then
  pass "review context covers committed, unstaged, and untracked changes"
else
  fail "review context covers committed, unstaged, and untracked changes"
fi

if grep -qx -- '--safe-mode' "$ARGS_LOG" \
  && grep -qx -- '--permission-mode' "$ARGS_LOG" \
  && grep -qx -- 'dontAsk' "$ARGS_LOG" \
  && grep -qx -- 'Read,Glob,Grep' "$ARGS_LOG" \
  && grep -qx -- '--strict-mcp-config' "$ARGS_LOG" \
  && ! grep -q 'Review billing changes' "$ARGS_LOG" \
  && ! grep -qx -- '--max-turns' "$ARGS_LOG"; then
  pass "Claude invocation enforces current read-only flags"
else
  fail "Claude invocation enforces current read-only flags"
fi

: > "$ARGS_LOG"
BRIDGE_ARGS=(dispatch review review-feat-billing main)
output="$(run_bridge "Re-review after fixes" env 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$output" | grep -q 'FAKE_RESUME' \
  && grep -qx -- '--resume' "$ARGS_LOG"; then
  pass "review resumes existing Claude session"
else
  fail "review resumes existing Claude session (rc=$rc, output=$output)"
fi

BRIDGE_ARGS=(dispatch plan review-feat-billing)
output="$(run_bridge "Wrong mode" env 2>&1)"
rc=$?
if [ "$rc" -eq 6 ] && printf '%s' "$output" | grep -q "belongs to mode 'review'"; then
  pass "mode mismatch refuses thread pollution"
else
  fail "mode mismatch refuses thread pollution (rc=$rc, output=$output)"
fi

BRIDGE_ARGS=(dispatch review review-feat-billing feat/billing)
output="$(run_bridge "Wrong base" env 2>&1)"
rc=$?
if [ "$rc" -eq 6 ] && printf '%s' "$output" | grep -q "already reviews '$MAIN_BASE'"; then
  pass "base mismatch refuses scope drift"
else
  fail "base mismatch refuses scope drift (rc=$rc, output=$output)"
fi

git -C "$REPO" branch -f main HEAD
BRIDGE_ARGS=(dispatch review review-feat-billing main)
output="$(run_bridge "Moved base" env 2>&1)"
rc=$?
if [ "$rc" -eq 6 ] && printf '%s' "$output" | grep -q "main.*now resolves"; then
  pass "moving target ref cannot change a review thread base"
else
  fail "moving target ref cannot change a review thread base (rc=$rc, output=$output)"
fi
git -C "$REPO" branch -f main "$MAIN_BASE"

BRIDGE_ARGS=(reply missing-thread)
output="$(run_bridge "Missing" env 2>&1)"
rc=$?
if [ "$rc" -eq 6 ]; then
  pass "reply requires existing thread"
else
  fail "reply requires existing thread (rc=$rc, output=$output)"
fi

BRIDGE_ARGS=(dispatch plan plan-failure)
output="$(run_bridge "Fail" env FAKE_CLAUDE_FAIL=1 2>&1)"
rc=$?
if [ "$rc" -eq 3 ] \
  && [ -s "$REPO/$STATE_REL/plan-failure.last-error.json" ] \
  && [ -s "$REPO/$STATE_REL/plan-failure.last-error.stderr" ]; then
  pass "Claude failure preserves diagnostics"
else
  fail "Claude failure preserves diagnostics (rc=$rc, output=$output)"
fi

before_mutation="$(cat "$REPO/mutable.txt")"
BRIDGE_ARGS=(dispatch plan plan-mutation)
output="$(run_bridge "Mutate" env FAKE_CLAUDE_MUTATE=1 2>&1)"
rc=$?
if [ "$rc" -eq 5 ] && [ "$(cat "$REPO/mutable.txt")" != "$before_mutation" ]; then
  pass "mutation guard detects changed dirty content"
else
  fail "mutation guard detects changed dirty content (rc=$rc, output=$output)"
fi

BRIDGE_ARGS=(dispatch plan plan-stage-mutation)
output="$(run_bridge "Stage" env FAKE_CLAUDE_STAGE=1 2>&1)"
rc=$?
if [ "$rc" -eq 5 ] && ! git -C "$REPO" diff --cached --quiet -- tracked.txt; then
  pass "mutation guard detects index-only changes"
else
  fail "mutation guard detects index-only changes (rc=$rc, output=$output)"
fi
git -C "$REPO" reset -q HEAD -- tracked.txt

mkdir -p "$REPO/$STATE_REL/plan-locked.active"
printf '%s\n' "$$" > "$REPO/$STATE_REL/plan-locked.active/pid"
BRIDGE_ARGS=(dispatch plan plan-locked)
output="$(run_bridge "Locked" env 2>&1)"
rc=$?
if [ "$rc" -eq 10 ]; then
  pass "live lock serializes a thread"
else
  fail "live lock serializes a thread (rc=$rc, output=$output)"
fi
rm -f "$REPO/$STATE_REL/plan-locked.active/pid"
rmdir "$REPO/$STATE_REL/plan-locked.active"

mkdir -p "$REPO/$STATE_REL/plan-stale.active"
printf '99999999\n' > "$REPO/$STATE_REL/plan-stale.active/pid"
BRIDGE_ARGS=(dispatch plan plan-stale)
output="$(run_bridge "Stale" env 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$output" | grep -q 'FAKE_INITIAL'; then
  pass "stale lock is taken over"
else
  fail "stale lock is taken over (rc=$rc, output=$output)"
fi

status_output="$(CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" bash "$DRIVER" status review-feat-billing 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$status_output" | grep -q 'mode=review' \
  && printf '%s' "$status_output" | grep -q "base=$MAIN_BASE"; then
  pass "status reports mode and base"
else
  fail "status reports mode and base (rc=$rc, output=$status_output)"
fi

reset_output="$(CODEX_CC_TRIAGE_PROJECT_DIR="$REPO" bash "$DRIVER" new review-feat-billing 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$REPO/$STATE_REL/review-feat-billing.id" ]; then
  pass "new resets only named thread"
else
  fail "new resets only named thread (rc=$rc, output=$reset_output)"
fi

if git -C "$REPO" check-ignore -q "$STATE_REL/probe" \
  && [ "$(cat "$REPO/.git/info/exclude" 2>/dev/null || true)" = "$EXCLUDE_BEFORE" ]; then
  pass "thread state is locally ignored"
else
  fail "thread state is locally ignored"
fi

ORIGINAL_REPO="$REPO"
REPO="$TMP/head-repo"
mkdir -p "$REPO"
(
  cd "$REPO" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name test
  git checkout -qb main
  printf 'base\n' > tracked.txt
  printf 'stable\n' > mutable.txt
  git add tracked.txt mutable.txt
  git commit -qm init
  printf 'worktree change\n' >> tracked.txt
) || exit 1
expected_base="$(git -C "$REPO" rev-parse HEAD)"
BRIDGE_ARGS=(dispatch review review-main)
output="$(run_bridge "Review main worktree" env 2>&1)"
rc=$?
stored_base="$(cat "$REPO/$STATE_REL/review-main.base" 2>/dev/null || true)"
if [ "$rc" -eq 0 ] && [ "$stored_base" = "$expected_base" ]; then
  pass "HEAD fallback pins the original review base commit"
else
  fail "HEAD fallback pins the original review base commit (rc=$rc, base=$stored_base, output=$output)"
fi
REPO="$ORIGINAL_REPO"

BRIDGE_ARGS=(dispatch review review-too-large main)
output="$(run_bridge "Review bounded context" env CODEX_CC_TRIAGE_CONTEXT_LIMIT=256 2>&1)"
rc=$?
if [ "$rc" -eq 7 ] && printf '%s' "$output" | grep -q 'review context exceeds'; then
  pass "oversized review context fails instead of omitting files"
else
  fail "oversized review context fails instead of omitting files (rc=$rc, output=$output)"
fi

OUTSIDE_ID="$TMP/outside-id"
printf 'outside-safe\n' > "$OUTSIDE_ID"
ln -s "$OUTSIDE_ID" "$REPO/$STATE_REL/plan-file-link.id"
BRIDGE_ARGS=(dispatch plan plan-file-link)
output="$(run_bridge "Reject file symlink" env 2>&1)"
rc=$?
if [ "$rc" -eq 7 ] && [ "$(cat "$OUTSIDE_ID")" = "outside-safe" ]; then
  pass "symlinked thread file is rejected"
else
  fail "symlinked thread file is rejected (rc=$rc, output=$output)"
fi
rm -f "$REPO/$STATE_REL/plan-file-link.id"

mkdir "$REPO/$STATE_REL/plan-directory.id"
BRIDGE_ARGS=(dispatch plan plan-directory)
output="$(run_bridge "Reject non-file state" env 2>&1)"
rc=$?
if [ "$rc" -eq 7 ]; then
  pass "non-regular thread file is rejected"
else
  fail "non-regular thread file is rejected (rc=$rc, output=$output)"
fi
rmdir "$REPO/$STATE_REL/plan-directory.id"

SYMLINK_REPO="$TMP/symlink-repo"
SYMLINK_TARGET="$TMP/symlink-target"
mkdir -p "$SYMLINK_REPO" "$SYMLINK_TARGET"
(
  cd "$SYMLINK_REPO" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name test
  printf 'base\n' > tracked.txt
  git add tracked.txt
  git commit -qm init
  ln -s "$SYMLINK_TARGET" .agent-state
) || exit 1
REPO="$SYMLINK_REPO"
BRIDGE_ARGS=(dispatch plan plan-symlink)
output="$(run_bridge "Reject symlink" env 2>&1)"
rc=$?
if [ "$rc" -eq 7 ] && [ ! -e "$SYMLINK_TARGET/codex-cc-triage/plan-symlink.id" ]; then
  pass "symlinked state parent is rejected"
else
  fail "symlinked state parent is rejected (rc=$rc, output=$output)"
fi
REPO="$ORIGINAL_REPO"

exit "$failures"
