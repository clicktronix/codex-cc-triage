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

SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lock-lib.sh
. "$SELF_DIR/lock-lib.sh"

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

assert_single_link() {
  codex_cc_lock_assert_single_link "$1" \
    || { echo "refusing unsafe or multiply-linked state: $1" >&2; exit 7; }
}
assert_regular_or_missing() {
  inspected="$1"; label="$2"
  [ ! -L "$inspected" ] || { echo "$label is unsafe" >&2; exit 7; }
  [ ! -e "$inspected" ] && return 0
  if [ ! -f "$inspected" ]; then
    [ ! -e "$inspected" ] && return 0
    echo "$label is unsafe" >&2
    exit 7
  fi
  assert_single_link "$inspected"
}
assert_directory_or_missing() {
  inspected="$1"; label="$2"
  [ ! -L "$inspected" ] || { echo "$label is unsafe" >&2; exit 7; }
  [ ! -e "$inspected" ] && return 0
  [ -d "$inspected" ] || {
    [ ! -e "$inspected" ] && return 0
    echo "$label is not a directory" >&2
    exit 7
  }
}

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
    [ ! -e "$IGNORE_FILE" ] || assert_single_link "$IGNORE_FILE"
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
PARENT="$COMMON_DIR/codex-cc-triage"
MIGRATION_DIR="$PARENT/migrations"
MIGRATION_KEY="$(printf '%s\n' "$ROOT" | git hash-object --stdin 2>/dev/null)" || exit 7
[ -n "$MIGRATION_KEY" ] || { echo "cannot identify legacy state source" >&2; exit 7; }
MIGRATION_MARKER="$MIGRATION_DIR/$MIGRATION_KEY.state-v1"
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
assert_migration_marker_safe() {
  [ ! -L "$PARENT" ] || { echo "refusing symlinked state parent" >&2; exit 7; }
  [ ! -e "$PARENT" ] || [ -d "$PARENT" ] \
    || { echo "state parent is not a directory" >&2; exit 7; }
  [ ! -L "$MIGRATION_DIR" ] || { echo "refusing symlinked migration marker directory" >&2; exit 7; }
  [ ! -e "$MIGRATION_DIR" ] || [ -d "$MIGRATION_DIR" ] \
    || { echo "migration marker path is not a directory" >&2; exit 7; }
  [ ! -L "$MIGRATION_MARKER" ] || { echo "refusing symlinked state migration marker" >&2; exit 7; }
  [ ! -e "$MIGRATION_MARKER" ] || [ -f "$MIGRATION_MARKER" ] \
    || { echo "state migration marker is not a regular file" >&2; exit 7; }
  [ ! -e "$MIGRATION_MARKER" ] || assert_single_link "$MIGRATION_MARKER"
}
migration_complete() {
  assert_migration_marker_safe
  [ -f "$MIGRATION_MARKER" ] || return 1
  [ "$(cat "$MIGRATION_MARKER" 2>/dev/null)" = "legacy_dir=$LEGACY_DIR" ] \
    || { echo "state migration marker does not match its legacy source" >&2; exit 7; }
}
preflight_legacy_state() {
  migration_complete && return 0
  [ -d "$LEGACY_DIR" ] && [ "$LEGACY_DIR" != "$STATE_DIR" ] || return 0
  for src in "$LEGACY_DIR"/* "$LEGACY_DIR"/.[!.]* "$LEGACY_DIR"/..?*; do
    [ -e "$src" ] || [ -L "$src" ] || continue
    name="${src##*/}"
    case "$name" in
      .gitignore|*.context.md|*.active|*.active-reclaim|*.review-lock|*.review-lock-reclaim|*.tmp.*) continue ;;
    esac
    if [ -L "$src" ]; then
      echo "state-dir.sh: refused symlinked legacy state at $src" >&2
      return 7
    fi
    [ -f "$src" ] \
      || { echo "state-dir.sh: legacy state is not a regular file: $src" >&2; return 7; }
    assert_single_link "$src"
    dest="$STATE_DIR/$name"
    [ ! -L "$dest" ] \
      || { echo "state-dir.sh: refused symlinked shared state at $dest" >&2; return 7; }
    if [ -e "$dest" ]; then
      [ -f "$dest" ] || { echo "state-dir.sh: shared state is not a regular file: $dest" >&2; return 7; }
      assert_single_link "$dest"
      if [ -f "$src" ] && [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        continue
      fi
      echo "state-dir.sh: conflicting legacy state at $src" >&2
      return 7
    fi
  done
}

if $READ_ONLY; then
  if migration_complete; then
    [ -d "$STATE_DIR" ] || { echo "migrated state directory is missing" >&2; exit 7; }
    printf '%s\n' "$STATE_DIR"
    exit 0
  fi
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

assert_migration_marker_safe
mkdir -p "$PARENT" || exit 1
[ ! -L "$STATE_DIR" ] || { echo "refusing symlinked thread directory" >&2; exit 7; }
LOCK="$PARENT/migration.lock"
RECLAIM_LOCK="$PARENT/migration-reclaim.lock"
assert_lock_safe() {
  lock_path="$1"
  assert_directory_or_missing "$lock_path" "state-dir.sh: lock"
  assert_regular_or_missing "$lock_path/owner" "state-dir.sh: lock owner"
}
remove_owned_lock() {
  codex_cc_lock_release_owned "$1" owner "$$"
}
cleanup_migration_locks() {
  remove_owned_lock "$RECLAIM_LOCK"
  remove_owned_lock "$LOCK"
}
lock_is_stale() {
  codex_cc_lock_is_stale "$1" owner
}
acquire_reclaim_lock() {
  local rc
  codex_cc_lock_acquire_reclaim "$RECLAIM_LOCK" owner "$$" 100
  rc=$?
  if [ "$rc" -eq 7 ]; then
    echo "state-dir.sh: unsafe migration reclaim lock" >&2
    exit 7
  fi
  return "$rc"
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
    if ! (set -C; printf '%s\n' "$$" > "$LOCK/owner") 2>/dev/null \
        || [ "$(cat "$LOCK/owner" 2>/dev/null)" != "$$" ]; then
      echo "state-dir.sh: cannot own migration lock" >&2
      exit 7
    fi
    break
  fi
  if acquire_reclaim_lock; then
    # Re-sample only while holding the separate reclamation guard. This keeps
    # a contender from acting on the generation another process replaced.
    assert_lock_safe "$LOCK"
    reclaim=false
    if [ -d "$LOCK" ]; then
      owner="$(cat "$LOCK/owner" 2>/dev/null)"
      lock_is_stale "$LOCK" && reclaim=true
      if $reclaim; then
        [ "$(cat "$RECLAIM_LOCK/owner" 2>/dev/null)" = "$$" ] \
          || { echo "state-dir.sh: lost migration reclaim lock" >&2; exit 7; }
        stale_lock="$LOCK.stale.$$"
        [ ! -e "$stale_lock" ] && [ ! -L "$stale_lock" ] \
          || { echo "state-dir.sh: stale lock path exists" >&2; exit 7; }
        if mv "$LOCK" "$stale_lock" 2>/dev/null; then
          [ ! -L "$stale_lock" ] \
            || { rm -f "$stale_lock"; echo "state-dir.sh: refused symlinked stale lock" >&2; exit 7; }
          [ ! -L "$stale_lock/owner" ] \
            || { echo "state-dir.sh: refused unsafe stale lock owner" >&2; exit 7; }
          [ "$(cat "$stale_lock/owner" 2>/dev/null)" = "$owner" ] \
            || { echo "state-dir.sh: migration lock generation changed during reclaim" >&2; exit 7; }
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

if migration_complete; then
  [ -d "$STATE_DIR" ] || { echo "migrated state directory is missing" >&2; exit 7; }
  printf '%s\n' "$STATE_DIR"
  exit 0
fi

# Copy under a common-Git mutex. The legacy directory is deliberately retained
# so an older installed plugin can still read it and collisions stay recoverable.
mkdir -p "$STATE_DIR" || exit 1

if [ -d "$LEGACY_DIR" ] && [ "$LEGACY_DIR" != "$STATE_DIR" ]; then
  preflight_legacy_state || exit $?
  for src in "$LEGACY_DIR"/* "$LEGACY_DIR"/.[!.]* "$LEGACY_DIR"/..?*; do
    [ -e "$src" ] || [ -L "$src" ] || continue
    name="${src##*/}"
    case "$name" in
      .gitignore|*.context.md|*.active|*.active-reclaim|*.review-lock|*.review-lock-reclaim|*.tmp.*) continue ;;
    esac
    dest="$STATE_DIR/$name"
    if [ ! -e "$dest" ]; then
      cp -p "$src" "$dest" 2>/dev/null || {
        echo "state-dir.sh: could not migrate $src" >&2
        exit 1
      }
    fi
  done
  mkdir -p "$MIGRATION_DIR" || exit 1
  marker_tmp="$(mktemp "$MIGRATION_MARKER.tmp.XXXXXX")" || exit 1
  if printf 'legacy_dir=%s\n' "$LEGACY_DIR" > "$marker_tmp" \
      && mv -f "$marker_tmp" "$MIGRATION_MARKER"; then
    :
  else
    rm -f "$marker_tmp" 2>/dev/null
    echo "state-dir.sh: could not publish migration marker" >&2
    exit 1
  fi
fi

printf '%s\n' "$STATE_DIR"
