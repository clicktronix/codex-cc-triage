#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

for script in \
  "$ROOT/plugins/codex-cc-tuner/scripts/claude-thread.sh" \
  "$ROOT/tests/driver-regression.sh" \
  "$ROOT/tests/fixtures/fake-claude.sh"; do
  bash -n "$script"
done

python3 -m py_compile \
  "$ROOT/plugins/codex-cc-tuner/scripts/repo_snapshot.py" \
  "$ROOT/plugins/codex-cc-tuner/scripts/parse_claude_json.py" \
  "$ROOT/tests/validate_structure.py"

bash "$ROOT/tests/driver-regression.sh"
python3 "$ROOT/tests/validate_structure.py"
python3 -m json.tool "$ROOT/.agents/plugins/marketplace.json" >/dev/null
python3 -m json.tool "$ROOT/plugins/codex-cc-tuner/.codex-plugin/plugin.json" >/dev/null

if rg -n '\[TODO:' "$ROOT/plugins"; then
  echo "FAIL TODO placeholder found" >&2
  exit 1
fi

echo "PASS all"
