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

# Acquire a reclaim mutex and recover a stale generation of that mutex itself.
# Return 0 when owned, 1 when busy, and 7 for an unsafe filesystem shape.
codex_cc_lock_acquire_reclaim() {
  local reclaim_dir="$1" owner_name="$2" process_id="$3" max_tries="${4:-100}"
  local tries=0 sampled moved stale_dir
  while [ "$tries" -lt "$max_tries" ]; do
    codex_cc_lock_assert_safe "$reclaim_dir" "$owner_name" || return 7
    if mkdir "$reclaim_dir" 2>/dev/null; then
      if (set -C; printf '%s\n' "$process_id" > "$reclaim_dir/$owner_name") 2>/dev/null \
          && [ "$(cat "$reclaim_dir/$owner_name" 2>/dev/null)" = "$process_id" ]; then
        return 0
      fi
      return 7
    fi
    if ! codex_cc_lock_is_stale "$reclaim_dir" "$owner_name"; then
      tries=$((tries + 1))
      sleep 0.01
      continue
    fi
    sampled="$(cat "$reclaim_dir/$owner_name" 2>/dev/null)"
    stale_dir="$reclaim_dir.stale.$process_id.$tries"
    [ ! -e "$stale_dir" ] && [ ! -L "$stale_dir" ] || return 7
    if mv "$reclaim_dir" "$stale_dir" 2>/dev/null; then
      moved="$(cat "$stale_dir/$owner_name" 2>/dev/null)"
      if [ "$moved" != "$sampled" ]; then
        # A different contender may be between mkdir and owner publication.
        # Such an empty moved generation can no longer publish at its original
        # path, so retire it instead of restoring a fresh ownerless lock.
        if [ -z "$moved" ]; then
          rmdir "$stale_dir" 2>/dev/null || return 7
        elif [ ! -e "$reclaim_dir" ] && [ ! -L "$reclaim_dir" ]; then
          mv "$stale_dir" "$reclaim_dir" 2>/dev/null || true
        else
          rm -f "$stale_dir/$owner_name" 2>/dev/null
          rmdir "$stale_dir" 2>/dev/null || true
        fi
        tries=$((tries + 1))
        sleep 0.01
        continue
      fi
      rm -f "$stale_dir/$owner_name" 2>/dev/null
      if ! rmdir "$stale_dir" 2>/dev/null; then
        return 7
      fi
      tries=$((tries + 1))
      continue
    fi
    tries=$((tries + 1))
    sleep 0.01
  done
  return 1
}
