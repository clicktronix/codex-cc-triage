#!/usr/bin/env bash
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/plugins/codex-cc-triage/scripts/lock-lib.sh"
TEMP_ROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEMP_ROOT"' EXIT

trial=1
while [ "$trial" -le 5 ]; do
  reclaim="$TEMP_ROOT/reclaim-$trial"
  critical="$TEMP_ROOT/critical-$trial"
  results="$TEMP_ROOT/results-$trial"
  mkdir "$reclaim" "$results" || exit 1
  printf '999999999999\n' > "$reclaim/owner"

  for contender in 1 2 3 4 5 6 7 8; do
    bash -c '
      . "$1"
      if codex_cc_lock_acquire_reclaim "$2" owner "$$" 100; then
        if mkdir "$3" 2>/dev/null; then
          sleep 0.02
          rmdir "$3"
          codex_cc_lock_release_owned "$2" owner "$$"
          printf "ok\n" > "$4"
        else
          printf "overlap\n" > "$4"
        fi
      else
        printf "failed\n" > "$4"
      fi
    ' bash "$LIB" "$reclaim" "$critical" "$results/$contender" &
  done
  wait

  successes="$(grep -l '^ok$' "$results"/* | wc -l | tr -d ' ')"
  if [ "$successes" -lt 1 ] || grep -Eq '^overlap$' "$results"/* \
      || [ -e "$reclaim" ] || [ -L "$reclaim" ] || [ -e "$critical" ]; then
    echo "FAIL shared reclaim lock contention (trial=$trial successes=$successes)" >&2
    exit 1
  fi
  trial=$((trial + 1))
done

echo "PASS shared reclaim lock contention"
