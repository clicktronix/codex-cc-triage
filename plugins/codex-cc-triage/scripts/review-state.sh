#!/usr/bin/env bash
# Machine-readable required Claude review bound to one clean candidate.
#
# begin <thread> --base <ref> --spec <path> [--cap 1..7]
# mode|header|advisory-check <thread>
# preflight <thread> <mode> <base-sha> <fingerprint>   (prompt on stdin)
# record <thread> <foreground|background> [claim-token]
# abort <thread> <dispatch-failure|timeout|tool-failure> <claim-token>
# stop <thread> <cap|divergence> [claim-token]
# check <thread>
# renew <thread> --by <who>
# reset <thread>
set -u
umask 077

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lock-lib.sh
. "$SELF_DIR/lock-lib.sh"
STATE_HELPER="$SELF_DIR/state-dir.sh"
SNAPSHOT="$SELF_DIR/repo_snapshot.py"
PYTHON_BIN="${CODEX_CC_TRIAGE_PYTHON_BIN:-python3}"

die() { code="$1"; shift; echo "codex-cc-triage: $*" >&2; exit "$code"; }
usage() {
  die 2 "usage: review-state.sh begin <thread> --base <ref> --spec <path> [--cap 1..7] | mode|header|advisory-check <thread> | preflight <thread> <mode> <base-sha> <fingerprint> (prompt on stdin) | record <thread> <foreground|background> [claim-token] | abort <thread> <dispatch-failure|timeout|tool-failure> <claim-token> | stop <thread> <cap|divergence> [claim-token] | check <thread> | renew <thread> --by <who> | reset <thread>"
}

VERB="${1:-}"; THREAD="${2:-}"
[ -n "$VERB" ] && [ -n "$THREAD" ] || usage
[ "${#THREAD}" -le 80 ] || die 2 "thread name exceeds 80 characters"
case "$THREAD" in
  [A-Za-z0-9]*) ;;
  *) die 2 "thread name must start with an ASCII letter or digit" ;;
esac
case "$THREAD" in *[!A-Za-z0-9._-]*) die 2 "invalid thread name" ;; esac

ROOT="${CODEX_CC_TRIAGE_PROJECT_DIR:-$PWD}"
cd "$ROOT" 2>/dev/null || die 7 "cannot enter repository"
if ! ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  [ "$#" -eq 2 ] || die 7 "required review needs a Git repository"
  case "$VERB" in
    mode) echo advisory; exit 0 ;;
    advisory-check) echo "ADVISORY_READY thread=$THREAD"; exit 0 ;;
    *) die 7 "required review needs a Git repository" ;;
  esac
fi
cd "$ROOT" || die 7 "cannot enter repository root"
ROOT="$(pwd -P)" || die 7 "cannot canonicalize repository root"
case "$VERB" in
  mode|header|advisory-check|preflight) STATE_DIR="$(bash "$STATE_HELPER" --read-only)" || exit $? ;;
  *) STATE_DIR="$(bash "$STATE_HELPER")" || exit $? ;;
esac
STATE_REL=".agent-state/codex-cc-triage"
CANDIDATE="$STATE_DIR/$THREAD.candidate"
PREPARED="$STATE_DIR/$THREAD.claim-prep"
REVIEW_STATE="$STATE_DIR/$THREAD.review-state"
LOOP_STATE="$STATE_DIR/$THREAD.review-loop"
APPROVED="$STATE_DIR/$THREAD.approved"
ACTIVE_LEASE="$STATE_DIR/$THREAD.active"
REVIEW_LOCK="$STATE_DIR/$THREAD.review-lock"
RECLAIM_LOCK="$STATE_DIR/$THREAD.review-lock-reclaim"

field() { sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1; }
valid_decimal() {
  value="$1"; max_length="$2"
  case "$value" in ''|0[0-9]*|*[!0-9]*) return 1 ;; esac
  [ "${#value}" -le "$max_length" ]
}
timestamp() { date -u +%FT%TZ; }
atomic_write() {
  destination="$1"
  temporary="$(mktemp "$destination.tmp.XXXXXX")" || return 1
  if cat > "$temporary" && mv -f "$temporary" "$destination"; then return 0; fi
  rm -f "$temporary" 2>/dev/null
  return 1
}
assert_single_link() {
  codex_cc_lock_assert_single_link "$1" \
    || die 7 "refusing unsafe or multiply-linked required-review state: $1"
}
assert_regular_or_missing() {
  inspected="$1"; label="$2"
  [ ! -L "$inspected" ] || die 7 "$label is unsafe: $inspected"
  [ ! -e "$inspected" ] && return 0
  if [ ! -f "$inspected" ]; then
    [ ! -e "$inspected" ] && return 0
    die 7 "$label is unsafe: $inspected"
  fi
  assert_single_link "$inspected"
}
assert_directory_or_missing() {
  inspected="$1"; label="$2"
  [ ! -L "$inspected" ] || die 7 "$label is unsafe: $inspected"
  [ ! -e "$inspected" ] && return 0
  [ -d "$inspected" ] || {
    [ ! -e "$inspected" ] && return 0
    die 7 "$label is not a directory: $inspected"
  }
}
assert_state_files_safe() {
  for suffix in claim-prep candidate review-state review-loop approved worktree log last-prompt last-result last-fingerprint last-base; do
    path="$STATE_DIR/$THREAD.$suffix"
    [ ! -L "$path" ] || die 7 "refusing symlinked required-review state: $path"
    [ ! -e "$path" ] || [ -f "$path" ] \
      || die 7 "required-review state is not a regular file: $path"
    [ ! -e "$path" ] || assert_single_link "$path"
  done
  assert_directory_or_missing "$ACTIVE_LEASE" "dispatch lease"
  assert_regular_or_missing "$ACTIVE_LEASE/pid" "dispatch lease owner"
}
assert_review_lock_safe() {
  assert_directory_or_missing "$REVIEW_LOCK" "required-review lock"
  assert_regular_or_missing "$REVIEW_LOCK/owner" "required-review lock owner"
}
assert_reclaim_lock_safe() {
  assert_directory_or_missing "$RECLAIM_LOCK" "review reclaim lock"
  assert_regular_or_missing "$RECLAIM_LOCK/owner" "review reclaim lock owner"
}
remove_owned_review_lock() {
  codex_cc_lock_release_owned "$REVIEW_LOCK" owner "$$"
}
remove_owned_reclaim_lock() {
  codex_cc_lock_release_owned "$RECLAIM_LOCK" owner "$$"
}
lock_is_stale() {
  codex_cc_lock_is_stale "$1" owner
}
acquire_reclaim_lock() {
  local rc
  codex_cc_lock_acquire_reclaim "$RECLAIM_LOCK" owner "$$" 100
  rc=$?
  [ "$rc" -ne 7 ] || die 7 "unsafe review reclaim lock"
  return "$rc"
}
cleanup_review_locks() {
  remove_owned_reclaim_lock
  remove_owned_review_lock
}
try_reclaim_review_lock() {
  acquire_reclaim_lock || return 1

  # Re-read the current generation only after holding the reclamation guard.
  # No contender may act on an owner sampled before another process acquired
  # a fresh main lock.
  assert_review_lock_safe
  if [ ! -d "$REVIEW_LOCK" ]; then
    remove_owned_reclaim_lock
    return 0
  fi
  reclaim=false
  lock_is_stale "$REVIEW_LOCK" && reclaim=true
  if $reclaim; then
    owner="$(cat "$REVIEW_LOCK/owner" 2>/dev/null)"
    [ "$(cat "$RECLAIM_LOCK/owner" 2>/dev/null)" = "$$" ] \
      || die 7 "lost review reclaim lock"
    stale_lock="$REVIEW_LOCK.stale.$$"
    [ ! -e "$stale_lock" ] && [ ! -L "$stale_lock" ] \
      || die 7 "stale review-state lock path already exists"
    if mv "$REVIEW_LOCK" "$stale_lock" 2>/dev/null; then
      [ ! -L "$stale_lock" ] \
        || { rm -f "$stale_lock"; die 7 "refused symlinked stale review lock"; }
      [ ! -L "$stale_lock/owner" ] \
        || die 7 "refused symlinked stale review lock owner"
      [ "$(cat "$stale_lock/owner" 2>/dev/null)" = "$owner" ] \
        || die 7 "review lock generation changed during reclaim"
      rm -f "$stale_lock/owner" 2>/dev/null
      rmdir "$stale_lock" 2>/dev/null || true
    fi
  fi
  remove_owned_reclaim_lock
  $reclaim
}
acquire_review_lock() {
  trap cleanup_review_locks EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  waits=0
  while :; do
    assert_review_lock_safe
    assert_reclaim_lock_safe
    if mkdir "$REVIEW_LOCK" 2>/dev/null; then
      if ! (set -C; printf '%s\n' "$$" > "$REVIEW_LOCK/owner") 2>/dev/null \
          || [ "$(cat "$REVIEW_LOCK/owner" 2>/dev/null)" != "$$" ]; then
        die 7 "cannot own review-state lock"
      fi
      return 0
    fi
    try_reclaim_review_lock && continue
    waits=$((waits + 1))
    [ "$waits" -lt 100 ] || die 10 "review-state lock is busy"
    sleep 0.05 2>/dev/null || sleep 1
  done
}
assert_no_live_dispatch() {
  allowed_pid="${1:-}"
  [ -d "$ACTIVE_LEASE" ] || return 0
  active="$(cat "$ACTIVE_LEASE/pid" 2>/dev/null)"
  case "$active" in
    ''|0|0[0-9]*|*[!0-9]*)
      die 10 "INVALID_DISPATCH_LEASE: verify process ownership and follow claude-thread Recovery; do not discard an active lease"
      ;;
  esac
  [ "${#active}" -le 12 ] \
    || die 10 "INVALID_DISPATCH_LEASE: verify process ownership and follow claude-thread Recovery; do not discard an active lease"
  [ "$active" = "$allowed_pid" ] && return 0
  kill -0 "$active" 2>/dev/null \
    && die 10 "thread dispatch is active: $THREAD"
  # Leave the dead lease for the driver's ownership-checked reclaim. Recovery
  # of an unfinished claim must preserve the session id and conversation log.
  return 0
}
head_sha() { git rev-parse --verify HEAD 2>/dev/null; }
tree_sha() { git rev-parse --verify 'HEAD^{tree}' 2>/dev/null; }
fingerprint() {
  "$PYTHON_BIN" "$SNAPSHOT" fingerprint --root "$ROOT" --state-rel "$STATE_REL" 2>/dev/null
}
clean_candidate() {
  tracked="$(git ls-files -- "$STATE_REL" 2>/dev/null || printf '__inspection_failed__\n')"
  [ -z "$tracked" ] || return 1
  status="$(git status --porcelain -uall --ignore-submodules=none 2>/dev/null)" \
    || return 1
  dirty="$(printf '%s\n' "$status" \
    | grep -vE '^.. \.agent-state/codex-cc-triage(/|$)' || true)"
  [ -z "$dirty" ]
}
review_round() {
  if [ -f "$STATE_DIR/$THREAD.log" ]; then
    count="$(grep -Ec '^## [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z mode=review$' \
      "$STATE_DIR/$THREAD.log" 2>/dev/null || true)"
    printf '%s\n' "${count:-0}"
  else
    printf '0\n'
  fi
}
result_verdict() {
  "$PYTHON_BIN" - "$STATE_DIR/$THREAD.last-result" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    lines = path.read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError):
    raise SystemExit(1)
verdicts = []
last_outside_fence = None
fence = None
for raw in lines:
    marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", raw)
    if marker:
        sequence, rest = marker.groups()
        current = (sequence[0], len(sequence))
        if fence is None:
            if current[0] == "`" and "`" in rest:
                continue
            fence = current
        elif current[0] == fence[0] and current[1] >= fence[1] and not rest.strip():
            fence = None
        continue
    if fence is not None:
      continue
    if not raw.strip():
      continue
    last_outside_fence = raw
    if raw in {"APPROVE", "REQUEST_CHANGES"}:
        verdicts.append(raw)
if fence is not None or len(verdicts) != 1 or last_outside_fence != verdicts[0]:
    raise SystemExit(10)
print(verdicts[0])
PY
}
prompt_scope_exact() { # file or - for stdin; 0 exact, 1 mismatch, 2 unreadable
  file="$1"; base="$2"; head="$3"; spec="$4"
  "$PYTHON_BIN" - "$file" "$base" "$head" "$spec" 3<&0 <<'PY'
import os
import sys
from pathlib import Path

path, base, head, spec = sys.argv[1:]
try:
    with (os.fdopen(3, encoding="utf-8") if path == "-" else Path(path).open(encoding="utf-8")) as prompt:
        lines = prompt.read().split("\n")
except (OSError, UnicodeError):
    raise SystemExit(2)
expected = [
    "REQUIRED_REVIEW",
    f"BASE_SHA: {base}",
    f"CANDIDATE_SHA: {head}",
    f"SPEC_PATH: {spec}",
]
if lines[:4] != expected or any(lines.count(line) != 1 for line in expected):
    raise SystemExit(1)
PY
}
write_state() { # status verdict eligible mode head tree fp round reason
  base="$(field "$CANDIDATE" base_sha)"; spec="$(field "$CANDIDATE" spec_path)"
  cap="$(field "$CANDIDATE" cap)"; start="$(field "$CANDIDATE" loop_start_round)"
  claim="$(field "$CANDIDATE" claim_token)"; expires="$(field "$CANDIDATE" claim_expires_at)"
  printf 'version=1\nstatus=%s\nverdict=%s\ngate_eligible=%s\nmode=%s\nhead=%s\ntree=%s\nfingerprint=%s\nbase_sha=%s\nspec_path=%s\ncap=%s\nloop_start_round=%s\nclaim_token=%s\nclaim_expires_at=%s\nround=%s\nreason=%s\ntimestamp=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$base" "$spec" "$cap" "$start" \
    "$claim" "$expires" "$8" "$9" "$(timestamp)" \
    | atomic_write "$REVIEW_STATE" || die 7 "cannot write review state"
}
write_loop_state() { # base spec cap start attempts [renewed_by]; renewed_by is carried over
  renewed_by="${6-$(field "$LOOP_STATE" renewed_by)}"
  {
    printf 'version=1\nbase_sha=%s\nspec_path=%s\ncap=%s\nstart_round=%s\nattempts=%s\n' "$1" "$2" "$3" "$4" "$5"
    [ -z "$renewed_by" ] || printf 'renewed_by=%s\n' "$renewed_by"
    printf 'timestamp=%s\n' "$(timestamp)"
  } | atomic_write "$LOOP_STATE" || die 7 "cannot write review loop"
}
invalid_claim() { die 10 "INVALID_CLAIM_STATE: inspect saved state; follow claude-thread Recovery before resetting"; }
is_required() { [ -f "$LOOP_STATE" ] || [ -f "$PREPARED" ] || [ -f "$CANDIDATE" ] || [ -f "$REVIEW_STATE" ] || [ -f "$APPROVED" ]; }
publish_claim() { # The journal is complete; publishing it again yields the same claim.
  local attempt token
  attempt="$(field "$PREPARED" attempt)"; token="$(field "$PREPARED" claim_token)"
  valid_decimal "$attempt" 7 && [ "$attempt" -le "$CAP" ] \
    && [ "$(field "$PREPARED" round_before)" = "$CURRENT_ROUND" ] || invalid_claim
  case "$token" in ''|*[!0-9a-f]*) invalid_claim ;; esac
  case "${#token}" in 40|64) ;; *) invalid_claim ;; esac
  write_loop_state "$BASE_SHA" "$SPEC_PATH" "$CAP" "$(field "$PREPARED" loop_start_round)" "$attempt"
  rm -f "$STATE_DIR/$THREAD.last-prompt" "$STATE_DIR/$THREAD.last-result" "$STATE_DIR/$THREAD.last-fingerprint" "$APPROVED" \
    || die 7 "cannot clear previous result"
  atomic_write "$CANDIDATE" < "$PREPARED" || die 7 "cannot publish candidate"
  printf '%s\n' "$ROOT" | atomic_write "$STATE_DIR/$THREAD.worktree" || die 7 "cannot publish worktree"
  write_state PENDING NONE false foreground "$HEAD_SHA" "$TREE_SHA" "$FP" "$CURRENT_ROUND" awaiting_verdict
  rm "$PREPARED" || die 7 "cannot finish claim publication"
  echo "PENDING head=$HEAD_SHA tree=$TREE_SHA fingerprint=$FP claim=$token attempt=$attempt/$CAP"
}
assert_claim() {
  provided="$1"; expected="$(field "$CANDIDATE" claim_token)"
  case "$expected" in ''|*[!0-9a-f]*) invalid_claim ;; esac
  case "${#expected}" in 40|64) ;; *) invalid_claim ;; esac
  [ "$provided" = "$expected" ] \
    || die 10 "CLAIM_MISMATCH: required-review round belongs to another invocation"
}

assert_state_files_safe
if [ "$VERB" = mode ]; then
  [ "$#" -eq 2 ] || usage
  if is_required; then echo required; else echo advisory; fi
  exit 0
fi
if [ ! -d "$STATE_DIR" ]; then
  case "$VERB" in
    advisory-check) [ "$#" -eq 2 ] || usage; echo "ADVISORY_READY thread=$THREAD"; exit 0 ;;
    header) die 10 "NO_PENDING_REVIEW" ;;
    preflight) [ "$#" -eq 5 ] || usage; exit 0 ;;
  esac
fi
acquire_review_lock
if [ -f "$PREPARED" ]; then
  case "$VERB" in begin|reset) ;; *) die 10 "CLAIM_INCOMPLETE: repeat begin for the same candidate" ;; esac
fi

case "$VERB" in
  advisory-check)
    [ "$#" -eq 2 ] || usage
    assert_no_live_dispatch
    ! is_required \
      || die 10 "REQUIRED_THREAD_RESERVED: use a different thread for advisory review; preserve this required lifecycle"
    echo "ADVISORY_READY thread=$THREAD"
    ;;

  header|preflight)
    if [ "$VERB" = header ]; then
      [ "$#" -eq 2 ] || usage
    else
      [ "$#" -eq 5 ] || usage
      is_required || exit 0
      [ "$3" = review ] || die 10 "REQUIRED_THREAD_RESERVED: use a review claim on this thread"
    fi
    [ "$(field "$REVIEW_STATE" status)" = PENDING ] && [ -f "$CANDIDATE" ] \
      || die 10 "REQUIRED_THREAD_RESERVED: begin a required round first"
    base="$(field "$CANDIDATE" base_sha)"; head="$(field "$CANDIDATE" head)"; spec="$(field "$CANDIDATE" spec_path)"
    [ -n "$base" ] && [ -n "$head" ] && [ -n "$spec" ] || invalid_claim
    if [ "$VERB" = header ]; then
      printf 'REQUIRED_REVIEW\nBASE_SHA: %s\nCANDIDATE_SHA: %s\nSPEC_PATH: %s\n' "$base" "$head" "$spec"
      exit 0
    fi
    [ "$4" = "$base" ] && [ "$(head_sha)" = "$head" ] && [ "$5" = "$(field "$CANDIDATE" fingerprint)" ] \
      || die 11 "STALE: the dispatch does not match the clean candidate"
    prompt_scope_exact - "$base" "$head" "$spec"
    case "$?" in
      0) ;;
      1) die 14 "PROMPT_SCOPE_MISMATCH: start with review-state.sh header $THREAD" ;;
      *) die 7 "Cannot read the required prompt; restore the runtime and retry" ;;
    esac
    ;;

  begin)
    assert_no_live_dispatch
    shift 2; BASE_REF=""; SPEC_PATH=""; CAP=""
    BASE_SEEN=false; SPEC_SEEN=false; CAP_SEEN=false
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --base)
          [ "$#" -ge 2 ] || usage
          ! $BASE_SEEN || die 2 "duplicate --base"
          BASE_SEEN=true; BASE_REF="$2"; shift 2
          ;;
        --spec)
          [ "$#" -ge 2 ] || usage
          ! $SPEC_SEEN || die 2 "duplicate --spec"
          SPEC_SEEN=true; SPEC_PATH="$2"; shift 2
          ;;
        --cap)
          [ "$#" -ge 2 ] || usage
          ! $CAP_SEEN || die 2 "duplicate --cap"
          CAP_SEEN=true; CAP="$2"; shift 2
          ;;
        *) usage ;;
      esac
    done
    [ -n "$BASE_REF" ] && [ -n "$SPEC_PATH" ] || usage
    if ! $CAP_SEEN; then
      CAP="$(field "$PREPARED" cap)"; [ -n "$CAP" ] || CAP="$(field "$LOOP_STATE" cap)"
      CAP="${CAP:-7}"
    fi
    case "$CAP" in [1-7]) ;; *) die 2 "required review cap must be 1..7" ;; esac
    while [ "${SPEC_PATH#./}" != "$SPEC_PATH" ]; do SPEC_PATH="${SPEC_PATH#./}"; done
    case "$SPEC_PATH" in
      /*|..|../*|*/..|*/../*|*[[:cntrl:]]*) die 2 "spec must be a stable, single-line repo-relative path" ;;
    esac
    [ ! -L "$SPEC_PATH" ] || die 13 "required review spec must not be a symlink"
    [ -f "$SPEC_PATH" ] || die 2 "spec file not found: $SPEC_PATH"
    git --literal-pathspecs ls-files --error-unmatch -- "$SPEC_PATH" >/dev/null 2>&1 \
      || die 13 "required review spec must be tracked"
    BASE_SHA="$(git rev-parse --verify --end-of-options "$BASE_REF^{commit}" 2>/dev/null)" \
      || die 2 "cannot resolve review base: $BASE_REF"
    HEAD_SHA="$(head_sha)" || die 13 "required review needs an existing HEAD"
    git merge-base --is-ancestor "$BASE_SHA" "$HEAD_SHA" 2>/dev/null \
      || die 2 "review base is not an ancestor of candidate"
    clean_candidate || die 13 "required review needs a clean candidate commit"
    TREE_SHA="$(tree_sha)" || die 13 "cannot resolve candidate tree"
    FP="$(fingerprint)"; [ -n "$FP" ] || die 13 "cannot fingerprint candidate"
    CURRENT_ROUND="$(review_round)"
    valid_decimal "$CURRENT_ROUND" 7 || die 7 "invalid required-review round counter"
    # Review state without its loop cannot start a fresh lifecycle.
    [ -f "$LOOP_STATE" ] || { [ ! -f "$CANDIDATE" ] && [ ! -f "$REVIEW_STATE" ] && [ ! -f "$APPROVED" ]; } \
      || invalid_claim
    if [ -f "$PREPARED" ]; then
      for item in "base_sha=$BASE_SHA" "head=$HEAD_SHA" "fingerprint=$FP" "spec_path=$SPEC_PATH" "cap=$CAP"; do
        grep -Fxq -- "$item" "$PREPARED" \
          || die 10 "REVIEW_CONTRACT_CHANGED: resume the interrupted begin on its original candidate"
      done
      publish_claim; exit 0
    fi
    STATUS="$(field "$REVIEW_STATE" status)"
    case "$STATUS" in
      PENDING)
        die 10 "PENDING: finish or abort the claimed review round before begin"
        ;;
      CAP_REACHED)
        die 10 "CAP_REACHED: report missing approval and continue safe work; more rounds need the owner's renew"
        ;;
      DIVERGED)
        die 10 "DIVERGED: return disagreements to the owner, continue safe repairs and follow claude-thread Recovery within the remaining authorization"
        ;;
    esac
    if [ -f "$LOOP_STATE" ]; then
      LOOP_BASE="$(field "$LOOP_STATE" base_sha)"
      LOOP_SPEC="$(field "$LOOP_STATE" spec_path)"
      LOOP_CAP="$(field "$LOOP_STATE" cap)"
      LOOP_START="$(field "$LOOP_STATE" start_round)"
      ATTEMPTS="$(field "$LOOP_STATE" attempts)"
      [ -n "$LOOP_BASE" ] && [ -n "$LOOP_SPEC" ] \
        || die 7 "invalid required review loop contract"
      case "$LOOP_CAP" in [1-7]) ;; *) die 7 "invalid required review loop cap" ;; esac
      valid_decimal "$LOOP_START" 7 || die 7 "invalid required review loop state"
      [ "$LOOP_BASE" = "$BASE_SHA" ] \
        && [ "$LOOP_SPEC" = "$SPEC_PATH" ] \
        && [ "$LOOP_CAP" = "$CAP" ] \
        || die 10 "REVIEW_CONTRACT_CHANGED: restore the original base/spec/cap, or start a new lifecycle for an authorized contract change"
    else
      LOOP_START="$CURRENT_ROUND"
      ATTEMPTS=0
    fi
    valid_decimal "$ATTEMPTS" 7 || die 7 "invalid required review attempt state"
    [ "$CURRENT_ROUND" -ge "$LOOP_START" ] \
      || die 7 "required review round counter moved backwards"
    if [ "$ATTEMPTS" -ge "$CAP" ]; then
      [ -f "$CANDIDATE" ] \
        && write_state CAP_REACHED NONE false foreground "$HEAD_SHA" "$TREE_SHA" "$FP" "$CURRENT_ROUND" cap
      die 10 "CAP_REACHED: required review already claimed $CAP attempt(s)"
    fi
    ATTEMPT=$((ATTEMPTS + 1)); ROUND_BEFORE="$CURRENT_ROUND"
    CLAIMED_AT="$(date +%s 2>/dev/null)"
    case "$CLAIMED_AT" in ''|*[!0-9]*) die 7 "cannot timestamp required-review claim" ;; esac
    CLAIM_EXPIRES_AT=$((CLAIMED_AT + 3600))
    CLAIM_TOKEN="$(printf '%s\n' "$ROOT" "$THREAD" "$HEAD_SHA" "$FP" "$ATTEMPT" "$$" "$CLAIMED_AT" \
      | git hash-object --stdin 2>/dev/null)"
    [ -n "$CLAIM_TOKEN" ] || die 7 "cannot create required-review claim token"
    LOG_BYTES="$(wc -c 2>/dev/null < "$STATE_DIR/$THREAD.log" | tr -d ' ')"; LOG_BYTES="${LOG_BYTES:-0}"
    case "$LOG_BYTES" in ''|*[!0-9]*) die 7 "cannot measure review log" ;; esac
    printf 'version=1\nhead=%s\ntree=%s\nfingerprint=%s\nbase_sha=%s\nspec_path=%s\ncap=%s\nloop_start_round=%s\nattempt=%s\nclaim_token=%s\nclaim_expires_at=%s\nround_before=%s\nlog_bytes=%s\ntimestamp=%s\n' \
      "$HEAD_SHA" "$TREE_SHA" "$FP" "$BASE_SHA" "$SPEC_PATH" "$CAP" "$LOOP_START" \
      "$ATTEMPT" "$CLAIM_TOKEN" "$CLAIM_EXPIRES_AT" "$ROUND_BEFORE" "$LOG_BYTES" \
      "$(timestamp)" | atomic_write "$PREPARED" \
      || die 7 "cannot prepare claim"
    publish_claim
    ;;

  record)
    { [ "$#" -eq 3 ] || [ "$#" -eq 4 ]; } || usage
    assert_no_live_dispatch
    MODE="$3"; case "$MODE" in foreground|background) ;; *) usage ;; esac
    [ -f "$CANDIDATE" ] || die 10 "NO_REQUIRED_CANDIDATE"
    [ "$(field "$REVIEW_STATE" status)" = PENDING ] \
      || die 10 "NO_PENDING_REVIEW: begin a required-review round first"
    [ "$#" -eq 4 ] || die 10 "CLAIM_REQUIRED: pass the token returned by begin"
    assert_claim "$4"
    ROUND_BEFORE="$(field "$CANDIDATE" round_before)"; ROUND_BEFORE="${ROUND_BEFORE:-0}"
    ROUND_NOW="$(review_round)"; ROUND_NOW="${ROUND_NOW:-0}"
    PROMPT="$STATE_DIR/$THREAD.last-prompt"; RESULT="$STATE_DIR/$THREAD.last-result"
    DISPATCH_FP="$(cat "$STATE_DIR/$THREAD.last-fingerprint" 2>/dev/null || true)"
    C_HEAD="$(field "$CANDIDATE" head)"; C_TREE="$(field "$CANDIDATE" tree)"
    C_FP="$(field "$CANDIDATE" fingerprint)"; C_BASE="$(field "$CANDIDATE" base_sha)"
    C_SPEC="$(field "$CANDIDATE" spec_path)"; C_CAP="$(field "$CANDIDATE" cap)"
    ATTEMPT="$(field "$CANDIDATE" attempt)"
    LOOP_START="$(field "$CANDIDATE" loop_start_round)"
    HEAD_SHA="$(head_sha 2>/dev/null || true)"; TREE_SHA="$(tree_sha 2>/dev/null || true)"
    # A runtime failure keeps the claim PENDING so the finished result can still be recorded.
    FP="$(fingerprint)" && [ -n "$FP" ] || die 7 "fingerprint_unavailable: restore the runtime and retry record on this claim"
    VERDICT=""
    if [ -f "$RESULT" ]; then
      VERDICT="$(result_verdict)"; verdict_rc=$?
      case "$verdict_rc:$VERDICT" in
        0:APPROVE|0:REQUEST_CHANGES|10:) ;;
        *) die 7 "Cannot read the saved verdict; restore the runtime and retry record on this claim" ;;
      esac
    fi
    if [ "$MODE" = background ]; then
      write_state BACKGROUND_SINGLE_PASS "${VERDICT:-NONE}" false background "$HEAD_SHA" "$TREE_SHA" "${DISPATCH_FP:-unknown}" "$ROUND_NOW" background_never_satisfies_gate
      echo "BACKGROUND_SINGLE_PASS verdict=${VERDICT:-NONE} gate_eligible=false"
      exit 0
    fi
    case "$C_CAP" in [1-7]) CAP_VALID=true ;; *) CAP_VALID=false ;; esac
    ROUND_VALID=false
    valid_decimal "$LOOP_START" 7 && valid_decimal "$ATTEMPT" 7 \
      && valid_decimal "$ROUND_BEFORE" 7 && valid_decimal "$ROUND_NOW" 7 \
      && ROUND_VALID=true
    STALE_REASON=""
    if ! $CAP_VALID; then STALE_REASON=malformed_cap
    elif ! $ROUND_VALID; then STALE_REASON=malformed_round_state
    elif [ -z "$C_BASE" ] || [ -z "$C_SPEC" ]; then STALE_REASON=malformed_candidate_scope
    elif ! clean_candidate; then STALE_REASON=dirty_worktree
    elif [ "$HEAD_SHA" != "$C_HEAD" ]; then STALE_REASON=head_moved
    elif [ "$TREE_SHA" != "$C_TREE" ]; then STALE_REASON=tree_moved
    elif [ "$FP" != "$C_FP" ]; then STALE_REASON=content_fingerprint_changed
    elif [ ! -f "$PROMPT" ] || [ ! -f "$RESULT" ] || [ "$DISPATCH_FP" != "$C_FP" ]; then
      STALE_REASON=verdict_not_attributable_to_this_candidate
    elif [ "$ROUND_NOW" -ne $((ROUND_BEFORE + 1)) ]; then STALE_REASON=round_counter_mismatch
    elif [ "$(cat "$STATE_DIR/$THREAD.last-base" 2>/dev/null)" != "$C_BASE" ]; then
      STALE_REASON=dispatch_base_mismatch
    else
      prompt_scope_exact "$PROMPT" "$C_BASE" "$C_HEAD" "$C_SPEC"
      case "$?" in
        0) ;;
        1) STALE_REASON=prompt_scope_mismatch ;;
        *) die 7 "Cannot read the saved prompt; retry record on this claim" ;;
      esac
    fi
    if [ -n "$STALE_REASON" ]; then
      write_state STALE "${VERDICT:-NONE}" false foreground "$HEAD_SHA" "$TREE_SHA" "${DISPATCH_FP:-unknown}" "$ROUND_NOW" "$STALE_REASON"
      die 11 "STALE ($STALE_REASON): verdict does not cover the current clean candidate"
    fi
    case "$VERDICT" in
      APPROVE)
        write_state APPROVED APPROVE true foreground "$C_HEAD" "$C_TREE" "$C_FP" "$ROUND_NOW" exact_candidate_approved
        atomic_write "$APPROVED" < "$REVIEW_STATE" \
          || die 7 "cannot persist approval"
        cleanup_review_locks
        trap - EXIT HUP INT TERM
        bash "$SELF_DIR/review-state.sh" check "$THREAD"
        ;;
      REQUEST_CHANGES)
        if [ "$ATTEMPT" -ge "$C_CAP" ]; then
          write_state CAP_REACHED REQUEST_CHANGES false foreground "$C_HEAD" "$C_TREE" "$C_FP" "$ROUND_NOW" cap
          die 10 "CAP_REACHED: blocking findings remain after $C_CAP attempt(s)"
        fi
        write_state REQUEST_CHANGES REQUEST_CHANGES false foreground "$C_HEAD" "$C_TREE" "$C_FP" "$ROUND_NOW" blocking_findings_open
        die 10 "REQUEST_CHANGES: commit valid fixes as a new candidate, or keep the same candidate for refuted/deferred findings; then begin and review again"
        ;;
      *)
        if [ "$ATTEMPT" -ge "$C_CAP" ]; then
          write_state CAP_REACHED NONE false foreground "$C_HEAD" "$C_TREE" "$C_FP" "$ROUND_NOW" cap
          die 10 "CAP_REACHED: no approval after $C_CAP attempt(s)"
        fi
        write_state NO_DECISION NONE false foreground "$C_HEAD" "$C_TREE" "$C_FP" "$ROUND_NOW" no_approve_verdict
        die 10 "NO_DECISION: required review did not return APPROVE"
        ;;
    esac
    ;;

  abort)
    [ "$#" -eq 4 ] || usage
    assert_no_live_dispatch
    case "$3" in dispatch-failure|timeout|tool-failure) ;; *) usage ;; esac
    [ -f "$CANDIDATE" ] || die 10 "NO_REQUIRED_CANDIDATE"
    [ "$(field "$REVIEW_STATE" status)" = PENDING ] || die 10 "NO_PENDING_REVIEW"
    assert_claim "$4"
    ROUND_BEFORE="$(field "$CANDIDATE" round_before)"; ROUND_NOW="$(review_round)"
    OLD_BYTES="$(field "$CANDIDATE" log_bytes)"
    NOW_BYTES="$(wc -c 2>/dev/null < "$STATE_DIR/$THREAD.log" | tr -d ' ')"; NOW_BYTES="${NOW_BYTES:-0}"
    valid_decimal "$ROUND_BEFORE" 7 && valid_decimal "$ROUND_NOW" 7 \
      && case "$OLD_BYTES:$NOW_BYTES" in *[!0-9:]*) false ;; *) true ;; esac \
      || invalid_claim
    [ "$ROUND_NOW" = "$ROUND_BEFORE" ] && [ "$NOW_BYTES" = "$OLD_BYTES" ] \
      || die 10 "ROUND_COMPLETED: record the finished dispatch instead of aborting its claim"
    for artifact in last-prompt last-result last-fingerprint; do
      [ ! -e "$STATE_DIR/$THREAD.$artifact" ] \
        || die 10 "ROUND_COMPLETED: record the published dispatch result instead of aborting its claim"
    done
    ATTEMPT="$(field "$CANDIDATE" attempt)"
    LOOP_BASE="$(field "$LOOP_STATE" base_sha)"; LOOP_SPEC="$(field "$LOOP_STATE" spec_path)"
    LOOP_CAP="$(field "$LOOP_STATE" cap)"; LOOP_START="$(field "$LOOP_STATE" start_round)"
    LOOP_ATTEMPTS="$(field "$LOOP_STATE" attempts)"
    valid_decimal "$ATTEMPT" 7 && valid_decimal "$LOOP_ATTEMPTS" 7 \
      && [ "$ATTEMPT" -gt 0 ] && [ "$LOOP_ATTEMPTS" = "$ATTEMPT" ] \
      || invalid_claim
    write_loop_state "$LOOP_BASE" "$LOOP_SPEC" "$LOOP_CAP" "$LOOP_START" "$((ATTEMPT - 1))"
    HEAD_SHA="$(head_sha 2>/dev/null || true)"; TREE_SHA="$(tree_sha 2>/dev/null || true)"; FP="$(fingerprint)"
    write_state ABORTED NONE false foreground "$HEAD_SHA" "$TREE_SHA" "$FP" "$ROUND_NOW" "$3"
    die 10 "ABORTED: required-review round released after $3"
    ;;

  stop)
    { [ "$#" -eq 3 ] || [ "$#" -eq 4 ]; } || usage
    assert_no_live_dispatch
    case "$3" in cap) STATUS=CAP_REACHED ;; divergence) STATUS=DIVERGED ;; *) usage ;; esac
    if [ -f "$CANDIDATE" ]; then
      [ "$(field "$REVIEW_STATE" status)" = PENDING ] \
        || die 10 "NO_PENDING_REVIEW: a hard stop cannot overwrite a completed round"
      [ "$#" -eq 4 ] || die 10 "CLAIM_REQUIRED: pass the token returned by begin"
      assert_claim "$4"
    else
      [ "$#" -eq 3 ] || usage
      die 10 "ADVISORY_${STATUS}: hard stop; no required-review state was written"
    fi
    HEAD_SHA="$(head_sha 2>/dev/null || true)"; TREE_SHA="$(tree_sha 2>/dev/null || true)"; FP="$(fingerprint)"
    write_state "$STATUS" NONE false foreground "$HEAD_SHA" "$TREE_SHA" "$FP" "$(review_round)" "$3"
    die 10 "$STATUS: hard stop; no gate approval was produced"
    ;;

  check)
    [ "$#" -eq 2 ] || usage
    assert_no_live_dispatch
    [ -f "$CANDIDATE" ] && [ -f "$REVIEW_STATE" ] && [ -f "$APPROVED" ] \
      || die 10 "NO_APPROVAL"
    cmp -s "$REVIEW_STATE" "$APPROVED" \
      || die 10 "NO_APPROVAL: incomplete approval publication"
    [ "$(field "$REVIEW_STATE" status)" = APPROVED ] \
      && [ "$(field "$APPROVED" verdict)" = APPROVE ] \
      && [ "$(field "$APPROVED" gate_eligible)" = true ] \
      && [ "$(field "$APPROVED" mode)" = foreground ] \
      && [ -n "$(field "$APPROVED" base_sha)" ] \
      && [ -n "$(field "$APPROVED" spec_path)" ] \
      && [ -n "$(field "$APPROVED" claim_token)" ] \
      && [ "$(field "$APPROVED" claim_token)" = "$(field "$CANDIDATE" claim_token)" ] \
      && [ "$(field "$APPROVED" head)" = "$(field "$CANDIDATE" head)" ] \
      && [ "$(field "$APPROVED" tree)" = "$(field "$CANDIDATE" tree)" ] \
      && [ "$(field "$APPROVED" fingerprint)" = "$(field "$CANDIDATE" fingerprint)" ] \
      && [ "$(field "$APPROVED" base_sha)" = "$(field "$CANDIDATE" base_sha)" ] \
      && [ "$(field "$APPROVED" spec_path)" = "$(field "$CANDIDATE" spec_path)" ] \
      || die 10 "NO_APPROVAL"
    [ "$(review_round)" = "$(field "$APPROVED" round)" ] \
      && [ "$(cat "$STATE_DIR/$THREAD.last-base" 2>/dev/null)" = "$(field "$APPROVED" base_sha)" ] \
      || die 10 "NO_APPROVAL: newer dispatch or missing actual base"
    clean_candidate || die 11 "STALE: candidate is dirty"
    HEAD_SHA="$(head_sha 2>/dev/null || true)"; TREE_SHA="$(tree_sha 2>/dev/null || true)"
    FP="$(fingerprint)"
    [ "$HEAD_SHA" = "$(field "$APPROVED" head)" ] \
      && [ "$TREE_SHA" = "$(field "$APPROVED" tree)" ] \
      && [ "$FP" = "$(field "$APPROVED" fingerprint)" ] \
      || die 11 "STALE: approval belongs to another candidate"
    echo "CODEX_CC_REQUIRED_REVIEW APPROVE thread=$THREAD head=$HEAD_SHA tree=$TREE_SHA fingerprint=$FP base_sha=$(field "$APPROVED" base_sha) spec_path=$(field "$APPROVED" spec_path)"
    ;;
  renew)
    # The owner authorized more rounds: base, spec, cap and the Claude session stay.
    [ "$#" -eq 4 ] && [ "$3" = --by ] || usage
    case "$4" in ''|*[[:cntrl:]]*) die 2 "--by needs a single-line owner" ;; esac
    assert_no_live_dispatch
    [ -f "$LOOP_STATE" ] || die 10 "INVALID_CLAIM_STATE: no review loop to renew"
    STATUS="$(field "$REVIEW_STATE" status)"
    [ "$STATUS" = CAP_REACHED ] \
      || die 10 "RENEW_REFUSED: renew follows CAP_REACHED; the thread is ${STATUS:-without a status}"
    LOOP_BASE="$(field "$LOOP_STATE" base_sha)"; LOOP_SPEC="$(field "$LOOP_STATE" spec_path)"
    LOOP_CAP="$(field "$LOOP_STATE" cap)"; ROUND_NOW="$(review_round)"
    [ -n "$LOOP_BASE" ] && [ -n "$LOOP_SPEC" ] && case "$LOOP_CAP" in [1-7]) true ;; *) false ;; esac \
      || die 7 "invalid required review loop contract"
    write_loop_state "$LOOP_BASE" "$LOOP_SPEC" "$LOOP_CAP" "$ROUND_NOW" 0 "$4"
    write_state RENEWED NONE false foreground "$(head_sha 2>/dev/null || true)" "$(tree_sha 2>/dev/null || true)" "" "$ROUND_NOW" renewed
    echo "RENEWED thread=$THREAD attempts=0/$LOOP_CAP authorized_by=$4"
    ;;
  reset)
    [ "$#" -eq 2 ] || usage
    assert_no_live_dispatch "${CODEX_CC_TRIAGE_REVIEW_RESET_LEASE_PID:-}"
    rm -f "$PREPARED" "$CANDIDATE" "$REVIEW_STATE" "$LOOP_STATE" "$APPROVED" \
      || die 7 "cannot reset required-review state"
    echo "RESET required-review state for $THREAD"
    ;;
  *) usage ;;
esac
