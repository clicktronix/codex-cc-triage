#!/usr/bin/env python3
"""Validate the repository's marketplace, plugin, and skill structure."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"FAIL {message}", file=sys.stderr)


def parse_frontmatter(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    match = re.match(r"^---\n(.*?)\n---\n", text, re.DOTALL)
    if not match:
        raise ValueError("missing YAML frontmatter")
    values: dict[str, str] = {}
    for line in match.group(1).splitlines():
        if ":" not in line:
            raise ValueError(f"unsupported frontmatter line: {line}")
        key, value = line.split(":", 1)
        values[key.strip()] = value.strip()
    return values


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    plugin = root / "plugins" / "codex-cc-tuner"
    failures = 0

    manifest = json.loads((plugin / ".codex-plugin" / "plugin.json").read_text())
    marketplace = json.loads(
        (root / ".agents" / "plugins" / "marketplace.json").read_text()
    )
    entry = marketplace["plugins"][0]
    if manifest.get("name") != "codex-cc-tuner":
        fail("plugin name mismatch")
        failures += 1
    if entry.get("name") != manifest.get("name"):
        fail("marketplace/plugin name mismatch")
        failures += 1
    if entry.get("source", {}).get("path") != "./plugins/codex-cc-tuner":
        fail("marketplace source path mismatch")
        failures += 1

    expected = {"claude-plan", "claude-review", "claude-reply", "claude-thread"}
    discovered: set[str] = set()
    for skill_file in sorted((plugin / "skills").glob("*/SKILL.md")):
        try:
            frontmatter = parse_frontmatter(skill_file)
        except (OSError, ValueError) as error:
            fail(f"{skill_file}: {error}")
            failures += 1
            continue
        if set(frontmatter) != {"name", "description"}:
            fail(f"{skill_file}: frontmatter must contain name and description only")
            failures += 1
        name = frontmatter.get("name", "")
        discovered.add(name)
        if name != skill_file.parent.name:
            fail(f"{skill_file}: name does not match directory")
            failures += 1
        if not frontmatter.get("description"):
            fail(f"{skill_file}: empty description")
            failures += 1
        if not (skill_file.parent / "agents" / "openai.yaml").is_file():
            fail(f"{skill_file}: missing agents/openai.yaml")
            failures += 1

    if discovered != expected:
        fail(f"skills mismatch: expected {sorted(expected)}, got {sorted(discovered)}")
        failures += 1
    if failures:
        return 1
    print("PASS structure")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
