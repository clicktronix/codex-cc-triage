#!/usr/bin/env bash
# Machine-readable required Claude review bound to one clean candidate.
#
# begin <thread> --base <ref> --spec <path> --cap 1..5
# record <thread>
# stop <thread> <cap|divergence>
# check <thread>
set -u
umask 077

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
STATE_HELPER="$SELF_DIR/state-dir.sh"
SNAPSHOT="$SELF_DIR/repo_snapshot.py"
PYTHON_BIN="${CODEX_CC_TRIAGE_PYTHON_BIN:-python3}"

die() { code="$1"; shift; echo "codex-cc-triage: $*" >&2; exit "$code"; }
usage() {
  die 2 "usage: review-state.sh begin <thread> --base <ref> --spec <path> --cap 1..5 | record <thread> | stop <thread> <cap|divergence> | check <thread>"
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
REVIEW_LOCK="$STATE_DIR/$THREAD.review-lock"
RECLAIM_LOCK="$STATE_DIR/$THREAD.review-lock-reclaim"

field() { sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1; }
timestamp() { date -u +%FT%TZ; }
atomic_write() {
  destination="$1"
  temporary="$(mktemp "$destination.tmp.XXXXXX")" || return 1
  if cat > "$temporary" && mv -f "$temporary" "$destination"; then return 0; fi
  rm -f "$temporary" 2>/dev/null
  return 1
}
assert_state_files_safe() {
  for suffix in candidate review-state review-loop approved log last-prompt last-result last-fingerprint; do
    path="$STATE_DIR/$THREAD.$suffix"
    [ ! -L "$path" ] || die 7 "refusing symlinked required-review state: $path"
    [ ! -e "$path" ] || [ -f "$path" ] \
      || die 7 "required-review state is not a regular file: $path"
  done
}
assert_review_lock_safe() {
  [ ! -L "$REVIEW_LOCK" ] || die 7 "refusing symlinked required-review lock: $REVIEW_LOCK"
  [ ! -e "$REVIEW_LOCK" ] || [ -d "$REVIEW_LOCK" ] \
    || die 7 "required-review lock is not a directory: $REVIEW_LOCK"
  [ ! -e "$REVIEW_LOCK/owner" ] \
    || { [ ! -L "$REVIEW_LOCK/owner" ] && [ -f "$REVIEW_LOCK/owner" ]; } \
    || die 7 "required-review lock owner is unsafe: $REVIEW_LOCK/owner"
}
assert_reclaim_lock_safe() {
  [ ! -L "$RECLAIM_LOCK" ] || die 7 "refusing symlinked review reclaim lock"
  [ ! -e "$RECLAIM_LOCK" ] || [ -d "$RECLAIM_LOCK" ] \
    || die 7 "review reclaim lock is not a directory"
  [ ! -e "$RECLAIM_LOCK/owner" ] \
    || { [ ! -L "$RECLAIM_LOCK/owner" ] && [ -f "$RECLAIM_LOCK/owner" ]; } \
    || die 7 "review reclaim lock owner is unsafe"
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
cleanup_review_locks() {
  remove_owned_reclaim_lock
  remove_owned_review_lock
}
try_reclaim_review_lock() {
  assert_reclaim_lock_safe
  mkdir "$RECLAIM_LOCK" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$RECLAIM_LOCK/owner" \
    || { rmdir "$RECLAIM_LOCK" 2>/dev/null; die 7 "cannot own review reclaim lock"; }

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
  case "$owner" in
    ''|*[!0-9]*)
      now="$(date +%s 2>/dev/null)"; modified="$(lock_mtime_epoch "$REVIEW_LOCK")"
      case "$now:$modified" in :*|*:|*[!0-9:]*) ;; *)
        [ $((now - modified)) -gt 60 ] && reclaim=true
        ;;
      esac
      ;;
    *) kill -0 "$owner" 2>/dev/null || reclaim=true ;;
  esac
  if $reclaim; then
    stale_lock="$REVIEW_LOCK.stale.$$"
    [ ! -e "$stale_lock" ] && [ ! -L "$stale_lock" ] \
      || die 7 "stale review-state lock path already exists"
    if mv "$REVIEW_LOCK" "$stale_lock" 2>/dev/null; then
      [ ! -L "$stale_lock" ] \
        || { rm -f "$stale_lock"; die 7 "refused symlinked stale review lock"; }
      [ ! -L "$stale_lock/owner" ] \
        || die 7 "refused symlinked stale review lock owner"
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
    if mkdir "$REVIEW_LOCK" 2>/dev/null; then
      printf '%s\n' "$$" > "$REVIEW_LOCK/owner" \
        || { rmdir "$REVIEW_LOCK" 2>/dev/null; die 7 "cannot own review-state lock"; }
      return 0
    fi
    try_reclaim_review_lock && continue
    waits=$((waits + 1))
    [ "$waits" -lt 100 ] || die 7 "review-state lock is busy"
    sleep 0.05 2>/dev/null || sleep 1
  done
}
head_sha() { git rev-parse --verify HEAD 2>/dev/null; }
tree_sha() { git rev-parse --verify 'HEAD^{tree}' 2>/dev/null; }
fingerprint() {
  "$PYTHON_BIN" "$SNAPSHOT" fingerprint --root "$ROOT" --state-rel "$STATE_REL" 2>/dev/null
}
clean_candidate() {
  tracked="$(git ls-files -- "$STATE_REL" 2>/dev/null || printf '__inspection_failed__\n')"
  [ -z "$tracked" ] || return 1
  dirty="$(git status --porcelain -uall --ignore-submodules=none 2>/dev/null \
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
write_state() {
  status="$1"; verdict="$2"; eligible="$3"; reason="$4"
  printf 'version=1\nstatus=%s\nverdict=%s\ngate_eligible=%s\nhead=%s\ntree=%s\nfingerprint=%s\nbase_sha=%s\nspec_path=%s\ncap=%s\nattempt=%s\nround=%s\nreason=%s\ntimestamp=%s\n' \
    "$status" "$verdict" "$eligible" "$(field "$CANDIDATE" head)" \
    "$(field "$CANDIDATE" tree)" "$(field "$CANDIDATE" fingerprint)" \
    "$(field "$CANDIDATE" base_sha)" "$(field "$CANDIDATE" spec_path)" \
    "$(field "$CANDIDATE" cap)" "$(field "$CANDIDATE" attempt)" "$(review_round)" \
    "$reason" "$(timestamp)" | atomic_write "$REVIEW_STATE" || die 7 "cannot write review state"
}

assert_state_files_safe
acquire_review_lock

case "$VERB" in
  begin)
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
    STATUS="$(field "$REVIEW_STATE" status)"
    case "$STATUS" in
      CAP_REACHED|DIVERGED)
        die 10 "$STATUS: reset the thread before starting another required review"
        ;;
    esac
    if [ -f "$LOOP_STATE" ] \
      && { [ "$STATUS" = PENDING ] || [ "$STATUS" = REQUEST_CHANGES ] \
        || [ "$STATUS" = NO_DECISION ] || [ "$STATUS" = STALE ]; } \
      && [ "$(field "$LOOP_STATE" base_sha)" = "$BASE_SHA" ] \
      && [ "$(field "$LOOP_STATE" spec_path)" = "$SPEC_PATH" ] \
      && [ "$(field "$LOOP_STATE" cap)" = "$CAP" ]; then
      ATTEMPTS="$(field "$LOOP_STATE" attempts)"
    else
      ATTEMPTS=0
    fi
    case "$ATTEMPTS" in ''|*[!0-9]*) die 7 "invalid required review loop state" ;; esac
    [ "$ATTEMPTS" -lt "$CAP" ] || die 10 "CAP_REACHED: required review spent $CAP round(s)"
    ATTEMPT=$((ATTEMPTS + 1)); ROUND_BEFORE="$(review_round)"
    printf 'version=1\nbase_sha=%s\nspec_path=%s\ncap=%s\nattempts=%s\ntimestamp=%s\n' \
      "$BASE_SHA" "$SPEC_PATH" "$CAP" "$ATTEMPT" "$(timestamp)" \
      | atomic_write "$LOOP_STATE" || die 7 "cannot write review loop"
    printf 'version=1\nhead=%s\ntree=%s\nfingerprint=%s\nbase_sha=%s\nspec_path=%s\ncap=%s\nattempt=%s\nround_before=%s\ntimestamp=%s\n' \
      "$HEAD_SHA" "$TREE_SHA" "$FP" "$BASE_SHA" "$SPEC_PATH" "$CAP" "$ATTEMPT" \
      "$ROUND_BEFORE" "$(timestamp)" | atomic_write "$CANDIDATE" \
      || die 7 "cannot write candidate state"
    write_state PENDING NONE false awaiting_dispatch
    echo "PENDING head=$HEAD_SHA tree=$TREE_SHA fingerprint=$FP attempt=$ATTEMPT/$CAP"
    ;;

  record)
    [ "$#" -eq 2 ] || usage
    [ -f "$CANDIDATE" ] || die 10 "NO_REQUIRED_CANDIDATE"
    [ "$(field "$REVIEW_STATE" status)" = PENDING ] \
      || die 10 "NO_PENDING_REVIEW: begin a required-review round first"
    ROUND_BEFORE="$(field "$CANDIDATE" round_before)"; ROUND_BEFORE="${ROUND_BEFORE:-0}"
    ROUND_NOW="$(review_round)"; ROUND_NOW="${ROUND_NOW:-0}"
    case "$ROUND_BEFORE:$ROUND_NOW" in *[!0-9:]*) die 11 "STALE: invalid dispatch round" ;; esac
    [ "$ROUND_NOW" -gt "$ROUND_BEFORE" ] || die 11 "STALE: no completed review dispatch after begin"
    PROMPT="$STATE_DIR/$THREAD.last-prompt"; RESULT="$STATE_DIR/$THREAD.last-result"
    DISPATCH_FP="$(cat "$STATE_DIR/$THREAD.last-fingerprint" 2>/dev/null || true)"
    [ -f "$PROMPT" ] && [ -f "$RESULT" ] || die 11 "STALE: missing dispatch evidence"
    C_HEAD="$(field "$CANDIDATE" head)"; C_TREE="$(field "$CANDIDATE" tree)"
    C_FP="$(field "$CANDIDATE" fingerprint)"; C_BASE="$(field "$CANDIDATE" base_sha)"
    C_SPEC="$(field "$CANDIDATE" spec_path)"; CAP="$(field "$CANDIDATE" cap)"
    ATTEMPT="$(field "$CANDIDATE" attempt)"
    HEAD_SHA="$(head_sha 2>/dev/null || true)"; TREE_SHA="$(tree_sha 2>/dev/null || true)"
    FP="$(fingerprint)"
    if ! clean_candidate || [ -z "$FP" ] || [ "$HEAD_SHA" != "$C_HEAD" ] \
      || [ "$TREE_SHA" != "$C_TREE" ] || [ "$FP" != "$C_FP" ] || [ "$DISPATCH_FP" != "$C_FP" ] \
      || ! prompt_scope_exact "$PROMPT" "$C_BASE" "$C_HEAD" "$C_SPEC"; then
      write_state STALE NONE false candidate_moved_or_unattributable
      die 11 "STALE: result does not cover the current clean candidate"
    fi
    VERDICT="$(result_verdict 2>/dev/null || true)"
    case "$VERDICT" in
      APPROVE)
        write_state APPROVED APPROVE true exact_candidate_approved
        atomic_write "$APPROVED" < "$REVIEW_STATE" \
          || die 7 "cannot persist approval"
        cleanup_review_locks
        trap - EXIT HUP INT TERM
        bash "$0" check "$THREAD"
        ;;
      REQUEST_CHANGES)
        if [ "$ATTEMPT" -ge "$CAP" ]; then
          write_state CAP_REACHED REQUEST_CHANGES false cap
          die 10 "CAP_REACHED: blocking findings remain after $CAP round(s)"
        fi
        write_state REQUEST_CHANGES REQUEST_CHANGES false blocking_findings_open
        die 10 "REQUEST_CHANGES: fix, test, commit, then begin the next round"
        ;;
      *)
        if [ "$ATTEMPT" -ge "$CAP" ]; then
          write_state CAP_REACHED NONE false cap
          die 10 "CAP_REACHED: no approval after $CAP round(s)"
        fi
        write_state NO_DECISION NONE false no_approve_verdict
        die 10 "NO_DECISION: required review did not return APPROVE"
        ;;
    esac
    ;;

  stop)
    [ "$#" -eq 3 ] || usage
    case "$3" in cap) STATUS=CAP_REACHED ;; divergence) STATUS=DIVERGED ;; *) usage ;; esac
    [ -f "$CANDIDATE" ] || die 10 "NO_REQUIRED_CANDIDATE"
    write_state "$STATUS" NONE false "$3"
    die 10 "$STATUS: hard stop; no approval produced"
    ;;

  check)
    [ "$#" -eq 2 ] || usage
    [ -f "$REVIEW_STATE" ] && [ -f "$APPROVED" ] || die 10 "NO_APPROVAL"
    [ "$(field "$REVIEW_STATE" status)" = APPROVED ] \
      && [ "$(field "$APPROVED" verdict)" = APPROVE ] \
      && [ "$(field "$APPROVED" gate_eligible)" = true ] \
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
  *) usage ;;
esac
