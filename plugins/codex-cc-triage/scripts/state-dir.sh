#!/usr/bin/env bash
# Resolve persistent plugin state to the repository's common Git directory.
#
# Unlike a worktree-local .claude directory, the common Git directory survives
# removal of a disposable worktree and is shared by every worktree of the same
# repository. CODEX_CC_TRIAGE_STATE_DIR is an explicit test/compatibility override.
#
# usage: state-dir.sh [--read-only]
set -u
umask 077

READ_ONLY=false
case "${1:-}" in
  "") ;;
  --read-only) READ_ONLY=true ;;
  *) echo "usage: state-dir.sh [--read-only]" >&2; exit 1 ;;
esac

if ! ROOT="$(git -C "${CODEX_CC_TRIAGE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$ROOT" ]; then
  echo "not inside a git repository" >&2
  exit 7
fi
cd "$ROOT" || exit 7

if [ -n "${CODEX_CC_TRIAGE_STATE_DIR:-}" ]; then
  case "$CODEX_CC_TRIAGE_STATE_DIR" in
    /*) STATE_DIR="$CODEX_CC_TRIAGE_STATE_DIR" ;;
    *)  STATE_DIR="$ROOT/$CODEX_CC_TRIAGE_STATE_DIR" ;;
  esac
  STATE_PARENT="$(dirname -- "$STATE_DIR")"
  [ ! -L "$STATE_PARENT" ] || { echo "refusing symlinked state parent" >&2; exit 7; }
  [ ! -L "$STATE_DIR" ] || { echo "refusing symlinked state directory" >&2; exit 7; }
  [ ! -e "$STATE_DIR" ] || [ -d "$STATE_DIR" ] \
    || { echo "state path is not a directory" >&2; exit 7; }
  if ! $READ_ONLY; then
    mkdir -p "$STATE_DIR" || exit 7
    IGNORE_FILE="$STATE_DIR/.gitignore"
    [ ! -L "$IGNORE_FILE" ] || { echo "refusing symlinked state ignore file" >&2; exit 7; }
    [ ! -e "$IGNORE_FILE" ] || [ -f "$IGNORE_FILE" ] \
      || { echo "state ignore path is not a regular file" >&2; exit 7; }
    if ! grep -qxF '*' "$IGNORE_FILE" 2>/dev/null; then
      IGNORE_TMP="$(mktemp "$IGNORE_FILE.tmp.XXXXXX")" || exit 7
      printf '*\n' > "$IGNORE_TMP" && mv -f "$IGNORE_TMP" "$IGNORE_FILE" \
        || { rm -f "$IGNORE_TMP" 2>/dev/null; exit 7; }
    fi
  fi
  printf '%s\n' "$STATE_DIR"
  exit 0
fi

COMMON_RAW="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 7
case "$COMMON_RAW" in
  /*) COMMON_DIR="$COMMON_RAW" ;;
  *)  COMMON_DIR="$ROOT/$COMMON_RAW" ;;
esac
if ! COMMON_DIR="$(cd "$COMMON_DIR" 2>/dev/null && pwd -P)" || [ -z "$COMMON_DIR" ]; then
  echo "cannot resolve the common Git directory" >&2
  exit 7
fi
STATE_DIR="$COMMON_DIR/codex-cc-triage/threads"
LEGACY_PARENT="$ROOT/.agent-state"
LEGACY_DIR="$LEGACY_PARENT/codex-cc-triage"
[ ! -L "$LEGACY_PARENT" ] || {
  echo "refusing symlinked legacy state parent" >&2
  exit 7
}
[ ! -e "$LEGACY_PARENT" ] || [ -d "$LEGACY_PARENT" ] || {
  echo "legacy state parent is not a directory" >&2
  exit 7
}
[ ! -L "$LEGACY_DIR" ] || {
  echo "refusing symlinked legacy state directory" >&2
  exit 7
}
if [ -d "$LEGACY_DIR" ]; then
  LEGACY_PHYSICAL="$(cd "$LEGACY_DIR" 2>/dev/null && pwd -P)" || exit 7
  [ "$LEGACY_PHYSICAL" = "$LEGACY_DIR" ] || {
    echo "legacy state resolves outside its repository path" >&2
    exit 7
  }
fi
preflight_legacy_state() {
  [ -d "$LEGACY_DIR" ] && [ "$LEGACY_DIR" != "$STATE_DIR" ] || return 0
  for src in "$LEGACY_DIR"/* "$LEGACY_DIR"/.[!.]* "$LEGACY_DIR"/..?*; do
    [ -e "$src" ] || continue
    name="${src##*/}"
    case "$name" in
      .gitignore|*.context.md|*.active|*.review-lock|*.review-lock-reclaim|*.tmp.*) continue ;;
    esac
    if [ -L "$src" ]; then
      echo "state-dir.sh: refused symlinked legacy state at $src" >&2
      continue
    fi
    dest="$STATE_DIR/$name"
    if [ -e "$dest" ]; then
      if [ -f "$src" ] && [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        continue
      fi
      echo "state-dir.sh: conflicting legacy state at $src" >&2
      return 7
    fi
  done
}

if $READ_ONLY; then
  preflight_legacy_state || exit $?
  if [ -d "$STATE_DIR" ]; then
    printf '%s\n' "$STATE_DIR"
  elif [ -d "$LEGACY_DIR" ]; then
    # Read compatibility before the first mutating command performs migration.
    printf '%s\n' "$LEGACY_DIR"
  else
    printf '%s\n' "$STATE_DIR"
  fi
  exit 0
fi

PARENT="$COMMON_DIR/codex-cc-triage"
[ ! -L "$PARENT" ] || { echo "refusing symlinked state parent" >&2; exit 7; }
[ ! -e "$PARENT" ] || [ -d "$PARENT" ] \
  || { echo "state parent is not a directory" >&2; exit 7; }
mkdir -p "$PARENT" || exit 1
[ ! -L "$STATE_DIR" ] || { echo "refusing symlinked thread directory" >&2; exit 7; }
LOCK="$PARENT/migration.lock"
RECLAIM_LOCK="$PARENT/migration-reclaim.lock"
mtime_epoch() {
  v="$(stat -c '%Y' "$1" 2>/dev/null)" && [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  stat -f '%m' "$1" 2>/dev/null
}
assert_lock_safe() {
  lock_path="$1"
  [ ! -L "$lock_path" ] || { echo "state-dir.sh: refusing symlinked lock" >&2; exit 7; }
  [ ! -e "$lock_path" ] || [ -d "$lock_path" ] \
    || { echo "state-dir.sh: lock is not a directory" >&2; exit 7; }
  [ ! -e "$lock_path/owner" ] \
    || { [ ! -L "$lock_path/owner" ] && [ -f "$lock_path/owner" ]; } \
    || { echo "state-dir.sh: lock owner is unsafe" >&2; exit 7; }
}
remove_owned_lock() {
  lock_path="$1"
  [ ! -L "$lock_path" ] || return 0
  [ -d "$lock_path" ] || return 0
  [ ! -L "$lock_path/owner" ] || return 0
  [ "$(cat "$lock_path/owner" 2>/dev/null)" = "$$" ] || return 0
  rm -f "$lock_path/owner" 2>/dev/null
  rmdir "$lock_path" 2>/dev/null || true
}
cleanup_migration_locks() {
  remove_owned_lock "$RECLAIM_LOCK"
  remove_owned_lock "$LOCK"
}
trap cleanup_migration_locks EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
i=0
while :; do
  assert_lock_safe "$LOCK"
  assert_lock_safe "$RECLAIM_LOCK"
  if mkdir "$LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK/owner" || { rmdir "$LOCK" 2>/dev/null; exit 1; }
    break
  fi
  if mkdir "$RECLAIM_LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$RECLAIM_LOCK/owner" \
      || { rmdir "$RECLAIM_LOCK" 2>/dev/null; exit 1; }
    # Re-sample only while holding the separate reclamation guard. This keeps
    # a contender from acting on the generation another process replaced.
    assert_lock_safe "$LOCK"
    reclaim=false
    if [ -d "$LOCK" ]; then
      owner="$(cat "$LOCK/owner" 2>/dev/null)"
      case "$owner" in
        ''|*[!0-9]*)
          now="$(date +%s 2>/dev/null)"; mt="$(mtime_epoch "$LOCK")"
          case "$now:$mt" in :*|*:|*[!0-9:]*) ;; *)
            [ $((now - mt)) -gt 60 ] && reclaim=true
            ;;
          esac
          ;;
        *) kill -0 "$owner" 2>/dev/null || reclaim=true ;;
      esac
      if $reclaim; then
        stale_lock="$LOCK.stale.$$"
        [ ! -e "$stale_lock" ] && [ ! -L "$stale_lock" ] \
          || { echo "state-dir.sh: stale lock path exists" >&2; exit 7; }
        if mv "$LOCK" "$stale_lock" 2>/dev/null; then
          [ ! -L "$stale_lock" ] \
            || { rm -f "$stale_lock"; echo "state-dir.sh: refused symlinked stale lock" >&2; exit 7; }
          [ ! -L "$stale_lock/owner" ] \
            || { echo "state-dir.sh: refused unsafe stale lock owner" >&2; exit 7; }
          rm -f "$stale_lock/owner" 2>/dev/null
          rmdir "$stale_lock" 2>/dev/null || true
        fi
      fi
    fi
    remove_owned_lock "$RECLAIM_LOCK"
    $reclaim && continue
  fi
  i=$((i+1))
  [ "$i" -lt 100 ] || { echo "state-dir.sh: migration lock is busy" >&2; exit 1; }
  sleep 0.05 2>/dev/null || sleep 1
done

# Copy under a common-Git mutex. The legacy directory is deliberately retained
# so an older installed plugin can still read it. Preflight the complete source
# first so a conflict cannot produce a partially migrated shared state.
mkdir -p "$STATE_DIR" || exit 1

if [ -d "$LEGACY_DIR" ] && [ "$LEGACY_DIR" != "$STATE_DIR" ]; then
  preflight_legacy_state || exit $?
  for src in "$LEGACY_DIR"/* "$LEGACY_DIR"/.[!.]* "$LEGACY_DIR"/..?*; do
    [ -e "$src" ] || continue
    name="${src##*/}"
    case "$name" in
      .gitignore|*.context.md|*.active|*.review-lock|*.review-lock-reclaim|*.tmp.*) continue ;;
    esac
    if [ -L "$src" ]; then
      echo "state-dir.sh: refused symlinked legacy state at $src" >&2
      continue
    fi
    dest="$STATE_DIR/$name"
    if [ ! -e "$dest" ]; then
      cp -pR "$src" "$dest" 2>/dev/null || {
        echo "state-dir.sh: could not migrate $src" >&2
        exit 1
      }
    fi
  done
fi

printf '%s\n' "$STATE_DIR"
