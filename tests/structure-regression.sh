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
sed 's/allow_implicit_invocation: false/allow_implicit_invocation: true/' \
  "$agent_file" > "$agent_file.tmp" || exit 1
mv "$agent_file.tmp" "$agent_file" || exit 1

if CODEX_CC_TRIAGE_REPO_ROOT="$MUTANT" \
  python3 "$ROOT/tests/validate_structure.py" >/dev/null 2>&1; then
  echo "FAIL explicit-invocation mutation survived structure validation" >&2
  exit 1
fi

echo "PASS explicit-invocation mutation is rejected"

sed 's/allow_implicit_invocation: true/allow_implicit_invocation: false/' \
  "$agent_file" > "$agent_file.tmp" || exit 1
mv "$agent_file.tmp" "$agent_file" || exit 1

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
