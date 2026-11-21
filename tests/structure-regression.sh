#!/usr/bin/env bash
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)" || exit 1
MUTANT="$TMP/repo"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$MUTANT"
cp -R \
  "$ROOT/.agents" \
  "$ROOT/.github" \
  "$ROOT/plugins" \
  "$MUTANT/" || exit 1

agent_file="$MUTANT/plugins/codex-cc-triage/skills/claude-plan/agents/openai.yaml"
sed 's/allow_implicit_invocation: true/allow_implicit_invocation: false/' \
  "$agent_file" > "$agent_file.tmp" || exit 1
mv "$agent_file.tmp" "$agent_file" || exit 1

if CODEX_CC_TRIAGE_REPO_ROOT="$MUTANT" \
  python3 "$ROOT/tests/validate_structure.py" >/dev/null 2>&1; then
  echo "FAIL hidden plan skill survived structure validation" >&2
  exit 1
fi

echo "PASS hidden plan skill is rejected"

cp "$ROOT/plugins/codex-cc-triage/skills/claude-plan/agents/openai.yaml" "$agent_file" || exit 1

maintenance="$MUTANT/plugins/codex-cc-triage/skills/claude-thread/agents/openai.yaml"
sed 's/allow_implicit_invocation: true/allow_implicit_invocation: false/' \
  "$maintenance" > "$maintenance.tmp" || exit 1
mv "$maintenance.tmp" "$maintenance" || exit 1
if CODEX_CC_TRIAGE_REPO_ROOT="$MUTANT" \
  python3 "$ROOT/tests/validate_structure.py" >/dev/null 2>&1; then
  echo "FAIL disabled autonomous maintenance survived structure validation" >&2
  exit 1
fi
echo "PASS disabled autonomous maintenance mutation is rejected"
cp "$ROOT/plugins/codex-cc-triage/skills/claude-thread/agents/openai.yaml" "$maintenance" || exit 1

workflow="$MUTANT/.github/workflows/validate.yml"
sed 's#actions/checkout@v7#actions/checkout@v4#' "$workflow" > "$workflow.tmp" || exit 1
printf '\n# actions/checkout@v7\n' >> "$workflow.tmp" || exit 1
mv "$workflow.tmp" "$workflow" || exit 1
if CODEX_CC_TRIAGE_REPO_ROOT="$MUTANT" \
  python3 "$ROOT/tests/validate_structure.py" >/dev/null 2>&1; then
  echo "FAIL commented checkout contract survived structure validation" >&2
  exit 1
fi
echo "PASS commented checkout contract mutation is rejected"

cp "$ROOT/.github/workflows/validate.yml" "$workflow" || exit 1
sed 's/os: \[ubuntu-latest, macos-latest\]/os: [ubuntu-latest] # macos-latest/' \
  "$workflow" > "$workflow.tmp" || exit 1
mv "$workflow.tmp" "$workflow" || exit 1
if CODEX_CC_TRIAGE_REPO_ROOT="$MUTANT" \
  python3 "$ROOT/tests/validate_structure.py" >/dev/null 2>&1; then
  echo "FAIL commented macOS contract survived structure validation" >&2
  exit 1
fi
echo "PASS commented macOS contract mutation is rejected"

cp "$ROOT/.github/workflows/validate.yml" "$workflow" || exit 1
sed '/      - run: bash tests\/run.sh/a\
        continue-on-error: true' \
  "$workflow" > "$workflow.tmp" || exit 1
mv "$workflow.tmp" "$workflow" || exit 1
if CODEX_CC_TRIAGE_REPO_ROOT="$MUTANT" \
  python3 "$ROOT/tests/validate_structure.py" >/dev/null 2>&1; then
  echo "FAIL continue-on-error contract survived structure validation" >&2
  exit 1
fi
echo "PASS continue-on-error mutation is rejected"

cp "$ROOT/.github/workflows/validate.yml" "$workflow" || exit 1
sed '/      - run: bash tests\/run.sh/a\
    if: false' \
  "$workflow" > "$workflow.tmp" || exit 1
mv "$workflow.tmp" "$workflow" || exit 1
if CODEX_CC_TRIAGE_REPO_ROOT="$MUTANT" \
  python3 "$ROOT/tests/validate_structure.py" >/dev/null 2>&1; then
  echo "FAIL disabled validation job survived structure validation" >&2
  exit 1
fi
echo "PASS disabled validation job mutation is rejected"

ownership="$ROOT/plugins/codex-cc-triage/skills/references/ownership.md"
for obligation in \
  'The Claude subprocess requires outbound network access.' \
  'never recommend disabling the sandbox globally' \
  'do not seed the findings you suspect and do not cap how many Claude may report' \
  'Do not paste secrets or unrelated proprietary context.' \
  "starts on the user's request or when the owning workflow's review step requires it, because it sends repository content to another provider"; do
  grep -qF -- "$obligation" "$ownership" \
    || { echo "FAIL ownership.md lost an obligation: $obligation" >&2; exit 1; }
done
echo "PASS ownership keeps the network, unbiased-request, secrets and provider rules"

forbid() { # description, then grep arguments; any match or a grep error fails
  local description="$1" rc
  shift
  grep "$@"
  rc=$?
  [ "$rc" -eq 1 ] && return 0
  [ "$rc" -eq 0 ] && echo "FAIL $description" >&2
  exit 1
}
shipped=("$ROOT/README.md" "$ROOT/plugins/codex-cc-triage/skills" "$ROOT/plugins/codex-cc-triage/.codex-plugin")
forbid "payment wording in shipped text" -rnwi -e paid -e budget -e grant -e grants -e granted "${shipped[@]}"
forbid "removed accounting flags or undefined recipe variables in shipped text" -rnF \
  -e 'State the ceiling' -e '--grant' -e '--rounds' -e '--integration' -e NO_FINDINGS \
  -e '$plugin_root' -e '$prompt_file' "${shipped[@]}"
echo "PASS shipped text counts rounds and uses runnable recipes"
