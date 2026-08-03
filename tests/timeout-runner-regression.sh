#!/usr/bin/env bash
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
RUNNER="$ROOT/plugins/codex-cc-triage/scripts/run_with_timeout.py"
TMP="$(mktemp -d)" || exit 1
CHILD_PID="$TMP/child.pid"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

python3 "$RUNNER" \
  --timeout 30 \
  --stdout "$TMP/stdout" \
  --stderr "$TMP/stderr" \
  --status "$TMP/status" \
  -- sh -c '(trap "" TERM; sleep 30) & descendant=$!; printf "%s %s\n" "$$" "$descendant" > "$1"; wait "$descendant"' sh "$CHILD_PID" \
  </dev/null &
runner_pid=$!

attempt=0
while [ ! -s "$CHILD_PID" ] && [ "$attempt" -lt 50 ]; do
  sleep 0.1
  attempt=$((attempt + 1))
done

if [ ! -s "$CHILD_PID" ]; then
  echo "FAIL timeout runner child did not start" >&2
  kill -TERM "$runner_pid" 2>/dev/null || true
  wait "$runner_pid" 2>/dev/null || true
  exit 1
fi

read -r child_pid descendant_pid < "$CHILD_PID"
kill -TERM "$runner_pid" || exit 1
sleep 0.2
kill -TERM "$runner_pid" 2>/dev/null || true
wait "$runner_pid"
rc=$?

if [ "$rc" -ne 143 ]; then
  echo "FAIL timeout runner returned $rc after SIGTERM" >&2
  exit 1
fi
if kill -0 "$child_pid" 2>/dev/null; then
  echo "FAIL timeout runner left child $child_pid alive" >&2
  exit 1
fi
if kill -0 "$descendant_pid" 2>/dev/null; then
  echo "FAIL timeout runner left descendant $descendant_pid alive" >&2
  exit 1
fi

echo "PASS timeout runner forwards termination to Claude"
