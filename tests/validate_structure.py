#!/usr/bin/env python3
"""Validate the repository's marketplace, plugin, and skill structure."""

from __future__ import annotations

import json
import os
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


def parse_agent_metadata(path: Path) -> dict[str, dict[str, object]]:
    """Parse the deliberately small mapping-only agents/openai.yaml contract."""
    result: dict[str, dict[str, object]] = {}
    section = ""
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line:
            continue
        top = re.fullmatch(r"([a-z_]+):", line)
        if top:
            section = top.group(1)
            if section in result:
                raise ValueError(f"duplicate section on line {number}: {section}")
            result[section] = {}
            continue
        nested = re.fullmatch(r"  ([a-z_]+): (.+)", line)
        if not nested or not section:
            raise ValueError(f"unsupported YAML line {number}: {line}")
        key, raw = nested.groups()
        if key in result[section]:
            raise ValueError(f"duplicate key on line {number}: {section}.{key}")
        if raw in {"true", "false"}:
            value: object = raw == "true"
        else:
            try:
                value = json.loads(raw)
            except json.JSONDecodeError as error:
                raise ValueError(
                    f"strings must be JSON-quoted on line {number}"
                ) from error
        result[section][key] = value
    return result


def main() -> int:
    root = Path(
        os.environ.get(
            "CODEX_CC_TRIAGE_REPO_ROOT", Path(__file__).resolve().parent.parent
        )
    ).resolve()
    plugin = root / "plugins" / "codex-cc-triage"
    failures = 0

    manifest = json.loads((plugin / ".codex-plugin" / "plugin.json").read_text())
    marketplace = json.loads(
        (root / ".agents" / "plugins" / "marketplace.json").read_text()
    )
    entry = marketplace["plugins"][0]
    if manifest.get("name") != "codex-cc-triage":
        fail("plugin name mismatch")
        failures += 1
    if manifest.get("version") != "0.6.0":
        fail("plugin version must be 0.6.0")
        failures += 1
    if manifest.get("skills") != "./skills/":
        fail("plugin skills path must be ./skills/")
        failures += 1
    plugin_interface = manifest.get("interface", {})
    short_description = plugin_interface.get("shortDescription")
    if not isinstance(short_description, str) or len(short_description) > 30:
        fail("plugin shortDescription must be a string of at most 30 characters")
        failures += 1
    prompts = plugin_interface.get("defaultPrompt")
    if (
        not isinstance(prompts, list)
        or len(prompts) > 3
        or any(not isinstance(prompt, str) or len(prompt) > 128 for prompt in prompts)
    ):
        fail(
            "plugin defaultPrompt must contain at most three prompts of 128 characters"
        )
        failures += 1
    if entry.get("name") != manifest.get("name"):
        fail("marketplace/plugin name mismatch")
        failures += 1
    if entry.get("source", {}).get("path") != "./plugins/codex-cc-triage":
        fail("marketplace source path mismatch")
        failures += 1

    workflow = (root / ".github" / "workflows" / "validate.yml").read_text()
    workflow_contract = re.compile(
        r"^  validate:\n"
        r"    strategy:\n"
        r"      fail-fast: false\n"
        r"      matrix:\n"
        r"        os: \[ubuntu-latest, macos-latest\]\n"
        r"    runs-on: \$\{\{ matrix\.os \}\}\n"
        r"    steps:\n"
        r"      - uses: actions/checkout@v7\n"
        r"      - run: bash tests/run\.sh\n?(?=  [A-Za-z0-9_-]+:\n|\Z)",
        re.MULTILINE,
    )
    if not workflow_contract.search(workflow):
        fail("validation workflow must run checkout v7 tests on Linux and macOS")
        failures += 1

    expected = {
        "claude-plan",
        "claude-reply",
        "claude-review",
        "claude-second-opinion",
        "claude-thread",
    }
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
        elif len(frontmatter["description"]) > 1024:
            fail(f"{skill_file}: description exceeds 1024 characters")
            failures += 1
        if len(f"codex-cc-triage:{name}") > 64:
            fail(f"{skill_file}: qualified skill identity exceeds 64 characters")
            failures += 1
        agent_file = skill_file.parent / "agents" / "openai.yaml"
        if not agent_file.is_file():
            fail(f"{skill_file}: missing agents/openai.yaml")
            failures += 1
        else:
            try:
                metadata = parse_agent_metadata(agent_file)
            except (OSError, ValueError) as error:
                fail(f"{agent_file}: {error}")
                failures += 1
                continue
            if set(metadata) != {"interface", "policy"}:
                fail(f"{agent_file}: expected interface and policy only")
                failures += 1
            interface = metadata.get("interface", {})
            if set(interface) != {
                "default_prompt",
                "display_name",
                "short_description",
            }:
                fail(f"{agent_file}: incomplete or unsupported interface fields")
                failures += 1
            display_name = interface.get("display_name")
            short_description = interface.get("short_description")
            if not isinstance(display_name, str) or not display_name:
                fail(f"{agent_file}: display_name must be non-empty")
                failures += 1
            if (
                not isinstance(short_description, str)
                or not 25 <= len(short_description) <= 64
            ):
                fail(f"{agent_file}: short_description must be 25-64 characters")
                failures += 1
            default_prompt = interface.get("default_prompt")
            if (
                not isinstance(default_prompt, str)
                or f"$codex-cc-triage:{name}" not in default_prompt
            ):
                fail(f"{agent_file}: default prompt must use the plugin namespace")
                failures += 1
            policy = metadata.get("policy", {})
            if policy != {"allow_implicit_invocation": False}:
                fail(f"{agent_file}: skill must require explicit invocation")
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
