#!/usr/bin/env bash
# Machine-readable required Claude review bound to one clean candidate.
#
# begin <thread> --base <ref> --spec <path> --cap 1..5
# advisory-check <thread>
# record <thread> <foreground|background> [claim-token]
# abort <thread> <dispatch-failure|timeout|tool-failure> <claim-token>
# stop <thread> <cap|divergence> [claim-token]
# check <thread>
# reset <thread>
set -u
umask 077

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
STATE_HELPER="$SELF_DIR/state-dir.sh"
SNAPSHOT="$SELF_DIR/repo_snapshot.py"
PYTHON_BIN="${CODEX_CC_TRIAGE_PYTHON_BIN:-python3}"

die() { code="$1"; shift; echo "codex-cc-triage: $*" >&2; exit "$code"; }
usage() {
  die 2 "usage: review-state.sh begin <thread> --base <ref> --spec <path> --cap 1..5 | advisory-check <thread> | record <thread> <foreground|background> [claim-token] | abort <thread> <dispatch-failure|timeout|tool-failure> <claim-token> | stop <thread> <cap|divergence> [claim-token] | check <thread> | reset <thread>"
}

VERB="${1:-}"; THREAD="${2:-}"
[ -n "$VERB" ] && [ -n "$THREAD" ] || usage
case "$THREAD" in
  [A-Za-z0-9]*) ;;
  *) die 2 "thread name must start with an ASCII letter or digit" ;;
esac
case "$THREAD" in *[!A-Za-z0-9._-]*) die 2 "invalid thread name" ;; esac

ROOT="${CODEX_CC_TRIAGE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[ -n "$ROOT" ] || die 7 "run inside a Git repository"
cd "$ROOT" 2>/dev/null || die 7 "cannot enter repository"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die 7 "not a Git repository"
cd "$ROOT" || die 7 "cannot enter repository root"
ROOT="$(pwd -P)" || die 7 "cannot canonicalize repository root"
STATE_DIR="$(bash "$STATE_HELPER")" || exit $?
STATE_REL=".agent-state/codex-cc-triage"
CANDIDATE="$STATE_DIR/$THREAD.candidate"
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
link_count() {
  count="$(stat -c '%h' "$1" 2>/dev/null)" && [ -n "$count" ] \
    && { printf '%s' "$count"; return 0; }
  stat -f '%l' "$1" 2>/dev/null
}
assert_single_link() {
  attempts=0
  while [ "$attempts" -lt 3 ]; do
    if links="$(link_count "$1")"; then
      [ "$links" = 1 ] || die 7 "refusing multiply-linked required-review state: $1"
      return 0
    fi
    [ ! -e "$1" ] && [ ! -L "$1" ] && return 0
    attempts=$((attempts + 1))
    sleep 0.01 2>/dev/null || sleep 1
  done
  die 7 "cannot inspect state link count: $1"
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
  for suffix in candidate review-state review-loop approved log last-prompt last-result last-fingerprint; do
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
lock_mtime_epoch() {
  value="$(stat -c '%Y' "$1" 2>/dev/null)" && [ -n "$value" ] \
    && { printf '%s' "$value"; return 0; }
  stat -f '%m' "$1" 2>/dev/null
}
remove_owned_review_lock() {
  [ ! -L "$REVIEW_LOCK" ] || return 0
  [ -d "$REVIEW_LOCK" ] || return 0
  [ ! -L "$REVIEW_LOCK/owner" ] || return 0
  [ "$(cat "$REVIEW_LOCK/owner" 2>/dev/null)" = "$$" ] || return 0
  rm -f "$REVIEW_LOCK/owner" 2>/dev/null
  rmdir "$REVIEW_LOCK" 2>/dev/null || true
}
remove_owned_reclaim_lock() {
  [ ! -L "$RECLAIM_LOCK" ] || return 0
  [ -d "$RECLAIM_LOCK" ] || return 0
  [ ! -L "$RECLAIM_LOCK/owner" ] || return 0
  [ "$(cat "$RECLAIM_LOCK/owner" 2>/dev/null)" = "$$" ] || return 0
  rm -f "$RECLAIM_LOCK/owner" 2>/dev/null
  rmdir "$RECLAIM_LOCK" 2>/dev/null || true
}
lock_is_stale() {
  candidate_lock="$1"; candidate_owner="$(cat "$candidate_lock/owner" 2>/dev/null)"
  case "$candidate_owner" in
    '')
      now="$(date +%s 2>/dev/null)"; modified="$(lock_mtime_epoch "$candidate_lock")"
      case "$now:$modified" in :*|*:|*[!0-9:]*) return 1 ;; esac
      [ $((now - modified)) -gt 60 ]
      ;;
    0|0[0-9]*|*[!0-9]*) return 0 ;;
    *)
      [ "${#candidate_owner}" -le 12 ] || return 0
      kill -0 "$candidate_owner" 2>/dev/null && return 1
      return 0
      ;;
  esac
}
acquire_reclaim_lock() {
  tries=0
  while [ "$tries" -lt 100 ]; do
    assert_reclaim_lock_safe
    if mkdir "$RECLAIM_LOCK" 2>/dev/null; then
      if (set -C; printf '%s\n' "$$" > "$RECLAIM_LOCK/owner") 2>/dev/null \
          && [ "$(cat "$RECLAIM_LOCK/owner" 2>/dev/null)" = "$$" ]; then
        return 0
      fi
      return 1
    fi
    if lock_is_stale "$RECLAIM_LOCK"; then
      sampled="$(cat "$RECLAIM_LOCK/owner" 2>/dev/null)"
      stale_reclaim="$RECLAIM_LOCK.stale.$$.$tries"
      [ ! -e "$stale_reclaim" ] && [ ! -L "$stale_reclaim" ] || return 1
      if mv "$RECLAIM_LOCK" "$stale_reclaim" 2>/dev/null; then
        moved="$(cat "$stale_reclaim/owner" 2>/dev/null)"
        if [ "$moved" != "$sampled" ]; then
          if [ ! -e "$RECLAIM_LOCK" ] && [ ! -L "$RECLAIM_LOCK" ]; then
            mv "$stale_reclaim" "$RECLAIM_LOCK" 2>/dev/null || true
          else
            rm -f "$stale_reclaim/owner" 2>/dev/null
            rmdir "$stale_reclaim" 2>/dev/null || true
          fi
          return 1
        fi
        rm -f "$stale_reclaim/owner" 2>/dev/null
        rmdir "$stale_reclaim" 2>/dev/null || true
        tries=$((tries + 1))
        continue
      fi
    fi
    return 1
  done
  return 1
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
  owner="$(cat "$REVIEW_LOCK/owner" 2>/dev/null)"
  reclaim=false
  lock_is_stale "$REVIEW_LOCK" && reclaim=true
  if $reclaim; then
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
      die 10 "INVALID_DISPATCH_LEASE: reset the thread through claude-thread.sh new"
      ;;
  esac
  [ "${#active}" -le 12 ] \
    || die 10 "INVALID_DISPATCH_LEASE: reset the thread through claude-thread.sh new"
  [ "$active" = "$allowed_pid" ] && return 0
  kill -0 "$active" 2>/dev/null \
    && die 10 "thread dispatch is active: $THREAD"
  die 10 "STALE_DISPATCH_LEASE: reset the thread through claude-thread.sh new"
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
    raise SystemExit(1)
print(verdicts[0])
PY
}
prompt_scope_exact() {
  file="$1"; base="$2"; head="$3"; spec="$4"
  "$PYTHON_BIN" - "$file" "$base" "$head" "$spec" <<'PY'
import sys
from pathlib import Path

path, base, head, spec = sys.argv[1:]
try:
    lines = Path(path).read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError):
    raise SystemExit(1)
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
write_loop_state() {
  printf 'version=1\nbase_sha=%s\nspec_path=%s\ncap=%s\nstart_round=%s\nattempts=%s\ntimestamp=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$(timestamp)" \
    | atomic_write "$LOOP_STATE" || die 7 "cannot write review loop"
}
assert_claim() {
  provided="$1"; expected="$(field "$CANDIDATE" claim_token)"
  case "$expected" in ''|*[!0-9a-f]*) die 10 "INVALID_CLAIM_STATE: reset the required-review thread" ;; esac
  case "${#expected}" in 40|64) ;; *) die 10 "INVALID_CLAIM_STATE: reset the required-review thread" ;; esac
  [ "$provided" = "$expected" ] \
    || die 10 "CLAIM_MISMATCH: required-review round belongs to another invocation"
}

assert_state_files_safe
acquire_review_lock

case "$VERB" in
  advisory-check)
    [ "$#" -eq 2 ] || usage
    assert_no_live_dispatch
    [ ! -f "$CANDIDATE" ] \
      || die 10 "REQUIRED_THREAD_RESERVED: use a different thread for advisory review, or reset this required-review lifecycle"
    echo "ADVISORY_READY thread=$THREAD"
    ;;

  begin)
    assert_no_live_dispatch
    shift 2; BASE_REF=""; SPEC_PATH=""; CAP=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --base) [ "$#" -ge 2 ] || usage; BASE_REF="$2"; shift 2 ;;
        --spec) [ "$#" -ge 2 ] || usage; SPEC_PATH="$2"; shift 2 ;;
        --cap) [ "$#" -ge 2 ] || usage; CAP="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$BASE_REF" ] && [ -n "$SPEC_PATH" ] && [ -n "$CAP" ] || usage
    case "$CAP" in 1|2|3|4|5) ;; *) die 2 "required review cap must be 1..5" ;; esac
    while [ "${SPEC_PATH#./}" != "$SPEC_PATH" ]; do SPEC_PATH="${SPEC_PATH#./}"; done
    case "$SPEC_PATH" in
      /*|..|../*|*/../*|*[!A-Za-z0-9_./-]*) die 2 "spec must be a stable repo-relative path" ;;
    esac
    [ ! -L "$SPEC_PATH" ] || die 13 "required review spec must not be a symlink"
    [ -f "$SPEC_PATH" ] || die 2 "spec file not found: $SPEC_PATH"
    git ls-files --error-unmatch -- "$SPEC_PATH" >/dev/null 2>&1 \
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
    STATUS="$(field "$REVIEW_STATE" status)"
    case "$STATUS" in
      PENDING)
        die 10 "PENDING: finish or abort the claimed review round before begin"
        ;;
      CAP_REACHED|DIVERGED)
        die 10 "$STATUS: reset the thread before starting another required review"
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
      case "$LOOP_CAP" in 1|2|3|4|5) ;; *) die 7 "invalid required review loop cap" ;; esac
      valid_decimal "$LOOP_START" 7 || die 7 "invalid required review loop state"
      [ "$LOOP_BASE" = "$BASE_SHA" ] \
        && [ "$LOOP_SPEC" = "$SPEC_PATH" ] \
        && [ "$LOOP_CAP" = "$CAP" ] \
        || die 10 "REVIEW_CONTRACT_CHANGED: reset the thread before changing required-review base, spec, or cap"
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
    write_loop_state "$BASE_SHA" "$SPEC_PATH" "$CAP" "$LOOP_START" "$ATTEMPT"
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
      "$(timestamp)" | atomic_write "$CANDIDATE" \
      || die 7 "cannot write candidate state"
    write_state PENDING NONE false foreground "$HEAD_SHA" "$TREE_SHA" "$FP" "$CURRENT_ROUND" awaiting_verdict
    echo "PENDING head=$HEAD_SHA tree=$TREE_SHA fingerprint=$FP claim=$CLAIM_TOKEN attempt=$ATTEMPT/$CAP"
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
    FP="$(fingerprint)"
    VERDICT="$(result_verdict 2>/dev/null || true)"
    if [ "$MODE" = background ]; then
      write_state BACKGROUND_SINGLE_PASS "${VERDICT:-NONE}" false background "$HEAD_SHA" "$TREE_SHA" "${DISPATCH_FP:-unknown}" "$ROUND_NOW" background_never_satisfies_gate
      echo "BACKGROUND_SINGLE_PASS verdict=${VERDICT:-NONE} gate_eligible=false"
      exit 0
    fi
    case "$C_CAP" in 1|2|3|4|5) CAP_VALID=true ;; *) CAP_VALID=false ;; esac
    ROUND_VALID=false
    valid_decimal "$LOOP_START" 7 && valid_decimal "$ATTEMPT" 7 \
      && valid_decimal "$ROUND_BEFORE" 7 && valid_decimal "$ROUND_NOW" 7 \
      && ROUND_VALID=true
    STALE_REASON=""
    if ! $CAP_VALID; then STALE_REASON=malformed_cap
    elif ! $ROUND_VALID; then STALE_REASON=malformed_round_state
    elif [ -z "$C_BASE" ] || [ -z "$C_SPEC" ]; then STALE_REASON=malformed_candidate_scope
    elif ! clean_candidate; then STALE_REASON=dirty_worktree
    elif [ -z "$FP" ]; then STALE_REASON=fingerprint_unavailable
    elif [ "$HEAD_SHA" != "$C_HEAD" ]; then STALE_REASON=head_moved
    elif [ "$TREE_SHA" != "$C_TREE" ]; then STALE_REASON=tree_moved
    elif [ "$FP" != "$C_FP" ]; then STALE_REASON=content_fingerprint_changed
    elif [ ! -f "$PROMPT" ] || [ ! -f "$RESULT" ] || [ "$DISPATCH_FP" != "$C_FP" ]; then
      STALE_REASON=verdict_not_attributable_to_this_candidate
    elif [ "$ROUND_NOW" -ne $((ROUND_BEFORE + 1)) ]; then STALE_REASON=round_counter_mismatch
    elif ! prompt_scope_exact "$PROMPT" "$C_BASE" "$C_HEAD" "$C_SPEC"; then
      STALE_REASON=prompt_scope_mismatch
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
      || die 10 "INVALID_CLAIM_STATE: reset the required-review thread"
    [ "$ROUND_NOW" = "$ROUND_BEFORE" ] && [ "$NOW_BYTES" = "$OLD_BYTES" ] \
      || die 10 "ROUND_COMPLETED: record the finished dispatch instead of aborting its claim"
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
    clean_candidate || die 11 "STALE: candidate is dirty"
    HEAD_SHA="$(head_sha 2>/dev/null || true)"; TREE_SHA="$(tree_sha 2>/dev/null || true)"
    FP="$(fingerprint)"
    [ "$HEAD_SHA" = "$(field "$APPROVED" head)" ] \
      && [ "$TREE_SHA" = "$(field "$APPROVED" tree)" ] \
      && [ "$FP" = "$(field "$APPROVED" fingerprint)" ] \
      || die 11 "STALE: approval belongs to another candidate"
    echo "CODEX_CC_REQUIRED_REVIEW APPROVE thread=$THREAD head=$HEAD_SHA tree=$TREE_SHA fingerprint=$FP base_sha=$(field "$APPROVED" base_sha) spec_path=$(field "$APPROVED" spec_path)"
    ;;
  reset)
    [ "$#" -eq 2 ] || usage
    assert_no_live_dispatch "${CODEX_CC_TRIAGE_REVIEW_RESET_LEASE_PID:-}"
    rm -f "$CANDIDATE" "$REVIEW_STATE" "$LOOP_STATE" "$APPROVED" \
      || die 7 "cannot reset required-review state"
    echo "RESET required-review state for $THREAD"
    ;;
  *) usage ;;
esac
