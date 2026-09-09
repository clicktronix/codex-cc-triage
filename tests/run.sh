#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

for script in \
  "$ROOT/plugins/codex-cc-triage/scripts/lock-lib.sh" \
  "$ROOT/plugins/codex-cc-triage/scripts/claude-thread.sh" \
  "$ROOT/plugins/codex-cc-triage/scripts/review-state.sh" \
  "$ROOT/plugins/codex-cc-triage/scripts/state-dir.sh" \
  "$ROOT/tests/driver-regression.sh" \
  "$ROOT/tests/lock-lib-regression.sh" \
  "$ROOT/tests/review-contract-regression.sh" \
  "$ROOT/tests/structure-regression.sh" \
  "$ROOT/tests/timeout-runner-regression.sh" \
  "$ROOT/tests/fixtures/fake-claude.sh"; do
  bash -n "$script"
done

python3 -m py_compile \
  "$ROOT/plugins/codex-cc-triage/scripts/repo_snapshot.py" \
  "$ROOT/plugins/codex-cc-triage/scripts/parse_claude_json.py" \
  "$ROOT/plugins/codex-cc-triage/scripts/run_with_timeout.py" \
  "$ROOT/tests/validate_structure.py" \
  "$ROOT/tests/test_timeout_runner.py"

bash "$ROOT/tests/driver-regression.sh"
bash "$ROOT/tests/lock-lib-regression.sh"
bash "$ROOT/tests/review-contract-regression.sh"
python3 "$ROOT/tests/product-integrity.py"
python3 "$ROOT/tests/validate_structure.py"
bash "$ROOT/tests/structure-regression.sh"
bash "$ROOT/tests/timeout-runner-regression.sh"
python3 "$ROOT/tests/test_timeout_runner.py"
python3 -m json.tool "$ROOT/.agents/plugins/marketplace.json" >/dev/null
python3 -m json.tool "$ROOT/plugins/codex-cc-triage/.codex-plugin/plugin.json" >/dev/null

for consumer in claude-thread.sh review-state.sh state-dir.sh; do
  grep -qF 'lock-lib.sh' "$ROOT/plugins/codex-cc-triage/scripts/$consumer"
  grep -qF 'codex_cc_lock_acquire_reclaim' "$ROOT/plugins/codex-cc-triage/scripts/$consumer"
done
if rg -n "stat -[cf].*'%[Ym]'" \
    "$ROOT/plugins/codex-cc-triage/scripts/claude-thread.sh" \
    "$ROOT/plugins/codex-cc-triage/scripts/review-state.sh" \
    "$ROOT/plugins/codex-cc-triage/scripts/state-dir.sh"; then
  echo "FAIL duplicated lock timestamp logic" >&2
  exit 1
fi
echo "PASS shared lock primitives"

if rg -n '\[TODO:' "$ROOT/plugins"; then
  echo "FAIL TODO placeholder found" >&2
  exit 1
fi

echo "PASS all"
