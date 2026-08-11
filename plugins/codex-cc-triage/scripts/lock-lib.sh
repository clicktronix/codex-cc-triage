#!/usr/bin/env bash
# Shared generation-safe directory-lock primitives for codex-cc-triage scripts.

codex_cc_lock_link_count() {
  local path="$1" count
  count="$(stat -c '%h' "$path" 2>/dev/null)" && [ -n "$count" ] \
    && { printf '%s' "$count"; return 0; }
  stat -f '%l' "$path" 2>/dev/null
}

codex_cc_lock_assert_single_link() {
  local path="$1" links attempts=0
  while [ "$attempts" -lt 3 ]; do
    if links="$(codex_cc_lock_link_count "$path")"; then
      [ "$links" = 1 ] || return 7
      return 0
    fi
    [ ! -e "$path" ] && [ ! -L "$path" ] && return 0
    attempts=$((attempts + 1))
    sleep 0.01 2>/dev/null || sleep 1
  done
  return 7
}

codex_cc_lock_assert_safe() {
  local lock_dir="$1" owner_name="$2" owner_path="$1/$2"
  [ ! -L "$lock_dir" ] || return 7
  [ ! -e "$lock_dir" ] || [ -d "$lock_dir" ] || return 7
  [ ! -L "$owner_path" ] || return 7
  [ ! -e "$owner_path" ] || [ -f "$owner_path" ] || return 7
  [ ! -e "$owner_path" ] || codex_cc_lock_assert_single_link "$owner_path"
}

codex_cc_lock_mtime_epoch() {
  local path="$1" value
  value="$(stat -c '%Y' "$path" 2>/dev/null)" && [ -n "$value" ] \
    && { printf '%s' "$value"; return 0; }
  stat -f '%m' "$path" 2>/dev/null
}

codex_cc_lock_is_stale() {
  local lock_dir="$1" owner_name="$2" owner now modified
  owner="$(cat "$lock_dir/$owner_name" 2>/dev/null)"
  case "$owner" in
    '')
      now="$(date +%s 2>/dev/null)"
      modified="$(codex_cc_lock_mtime_epoch "$lock_dir")"
      case "$now:$modified" in :*|*:|*[!0-9:]*) return 1 ;; esac
      [ $((now - modified)) -gt 60 ]
      ;;
    0|0[0-9]*|*[!0-9]*) return 0 ;;
    *)
      [ "${#owner}" -le 12 ] || return 0
      kill -0 "$owner" 2>/dev/null && return 1
      return 0
      ;;
  esac
}

codex_cc_lock_release_owned() {
  local lock_dir="$1" owner_name="$2" expected_owner="$3"
  [ ! -L "$lock_dir" ] || return 0
  [ -d "$lock_dir" ] || return 0
  [ ! -L "$lock_dir/$owner_name" ] || return 0
  [ -f "$lock_dir/$owner_name" ] || return 0
  codex_cc_lock_assert_single_link "$lock_dir/$owner_name" || return 0
  [ "$(cat "$lock_dir/$owner_name" 2>/dev/null)" = "$expected_owner" ] || return 0
  rm -f "$lock_dir/$owner_name" 2>/dev/null
  rmdir "$lock_dir" 2>/dev/null || true
}

codex_cc_lock_guard_acquire() {
  local guard="$1" rc
  [ ! -L "$guard" ] && { [ ! -e "$guard" ] || [ -f "$guard" ]; } || return 7
  [ ! -e "$guard" ] || codex_cc_lock_assert_single_link "$guard" || return 7
  exec 9>"$guard" || return 7
  if [ -L "$guard" ] || [ ! -f "$guard" ] \
      || ! codex_cc_lock_assert_single_link "$guard"; then
    exec 9>&-
    return 7
  fi
  if command -v flock >/dev/null 2>&1; then
    flock -w 1 9
    rc=$?
  elif command -v lockf >/dev/null 2>&1; then
    lockf -s -t 1 9
    rc=$?
  else
    rc=7
  fi
  if [ "$rc" -ne 0 ]; then
    exec 9>&-
    [ "$rc" -eq 7 ] && return 7
    return 1
  fi
  return 0
}

codex_cc_lock_guard_release() {
  exec 9>&-
}

# Use a process-scoped advisory guard while replacing a stale directory
# generation. The kernel releases the guard on crash, so an interrupted
# reclaimer cannot require a recursively reclaimable mutex of its own.
# Return 0 when owned, 1 when busy, and 7 for an unsafe filesystem shape.
codex_cc_lock_acquire_reclaim() {
  local reclaim_dir="$1" owner_name="$2" process_id="$3"
  local guard stale_dir owner moved
  guard="$(dirname -- "$reclaim_dir")/.reclaim.guard"
  stale_dir="$reclaim_dir.stale"
  codex_cc_lock_guard_acquire "$guard" || return $?

  codex_cc_lock_assert_safe "$reclaim_dir" "$owner_name" \
    || { codex_cc_lock_guard_release; return 7; }
  codex_cc_lock_assert_safe "$stale_dir" "$owner_name" \
    || { codex_cc_lock_guard_release; return 7; }
  if [ -d "$stale_dir" ]; then
    rm -f "$stale_dir/$owner_name" 2>/dev/null
    rmdir "$stale_dir" 2>/dev/null \
      || { codex_cc_lock_guard_release; return 7; }
  fi

  if [ -d "$reclaim_dir" ]; then
    owner="$(cat "$reclaim_dir/$owner_name" 2>/dev/null)"
    if [ -n "$owner" ] && ! codex_cc_lock_is_stale "$reclaim_dir" "$owner_name"; then
      codex_cc_lock_guard_release
      return 1
    fi
    mv "$reclaim_dir" "$stale_dir" 2>/dev/null \
      || { codex_cc_lock_guard_release; return 1; }
    moved="$(cat "$stale_dir/$owner_name" 2>/dev/null)"
    if [ "$moved" != "$owner" ]; then
      codex_cc_lock_guard_release
      return 7
    fi
    rm -f "$stale_dir/$owner_name" 2>/dev/null
    rmdir "$stale_dir" 2>/dev/null \
      || { codex_cc_lock_guard_release; return 7; }
  fi

  if ! mkdir "$reclaim_dir" 2>/dev/null \
      || ! (set -C; printf '%s\n' "$process_id" > "$reclaim_dir/$owner_name") 2>/dev/null \
      || [ "$(cat "$reclaim_dir/$owner_name" 2>/dev/null)" != "$process_id" ]; then
    codex_cc_lock_guard_release
    return 7
  fi
  codex_cc_lock_guard_release
  return 0
}
