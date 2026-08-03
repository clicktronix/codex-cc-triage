#!/usr/bin/env bash
set -u

if [ "${1:-}" = "--help" ]; then
  for flag in \
    --safe-mode \
    --permission-mode \
    --tools \
    --strict-mcp-config \
    --disable-slash-commands \
    --no-chrome \
    --model \
    --max-budget-usd \
    --output-format \
    --resume \
    --name; do
    [ "$flag" = "${FAKE_CLAUDE_MISSING_FLAG:-}" ] || printf '%s\n' "$flag"
  done
  printf '%s\n' '--remote-control-session-name-prefix'
  printf '%s\n' '--name-prefix'
  printf '%s\n' 'description mentions --name but does not declare it'
  exit 0
fi

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  if [ "${FAKE_CLAUDE_AUTHENTICATED:-1}" = "1" ]; then
    printf '{"loggedIn":true,"authMethod":"test"}\n'
    exit 0
  fi
  printf '{"loggedIn":false}\n'
  exit 1
fi

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

if [ -n "${FAKE_CLAUDE_SLEEP_SECONDS:-}" ]; then
  sleep "$FAKE_CLAUDE_SLEEP_SECONDS"
fi

if [ "${FAKE_CLAUDE_EXIT_124:-0}" = "1" ]; then
  echo "fake Claude exit 124" >&2
  exit 124
fi

if [ "${FAKE_CLAUDE_SILENT_FAIL:-0}" = "1" ]; then
  exit 9
fi

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
