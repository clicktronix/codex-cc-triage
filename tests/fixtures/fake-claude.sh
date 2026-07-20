#!/usr/bin/env bash
set -u

args_log="${FAKE_CLAUDE_ARGS_LOG:?FAKE_CLAUDE_ARGS_LOG is required}"
prompt_log="${FAKE_CLAUDE_PROMPT_LOG:?FAKE_CLAUDE_PROMPT_LOG is required}"
session_id="11111111-1111-4111-8111-111111111111"
resumed=0
expect_resume_id=0

: > "$prompt_log"
for arg in "$@"; do
  printf '%s\n' "$arg" >> "$args_log"
  if [ "$expect_resume_id" -eq 1 ]; then
    session_id="$arg"
    resumed=1
    expect_resume_id=0
  elif [ "$arg" = "--resume" ]; then
    expect_resume_id=1
  fi
done
cat > "$prompt_log"

if [ "${FAKE_CLAUDE_MUTATE:-0}" = "1" ]; then
  printf 'mutated by fake Claude\n' >> "${FAKE_CLAUDE_PROJECT_DIR:?}/mutable.txt"
fi
if [ "${FAKE_CLAUDE_STAGE:-0}" = "1" ]; then
  git -C "${FAKE_CLAUDE_PROJECT_DIR:?}" add tracked.txt
fi

if [ "${FAKE_CLAUDE_FAIL:-0}" = "1" ]; then
  echo "fake Claude stderr" >&2
  printf '{"is_error":true,"session_id":"%s","result":"FAKE_FAILURE"}\n' "$session_id"
  exit 9
fi

if [ "$resumed" -eq 1 ]; then
  result="FAKE_RESUME"
else
  result="FAKE_INITIAL"
fi
printf '{"is_error":false,"session_id":"%s","result":"%s","total_cost_usd":0.0123,"duration_ms":450,"num_turns":1}\n' \
  "$session_id" "$result"
