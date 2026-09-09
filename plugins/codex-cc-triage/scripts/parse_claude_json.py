#!/usr/bin/env python3
"""Validate Claude print-mode JSON and extract the session and result."""

from __future__ import annotations

import argparse
import json
import os
import sys
import uuid
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--id-output", type=Path, required=True)
    parser.add_argument("--result-output", type=Path, required=True)
    parser.add_argument("--meta-output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        payload = json.loads(args.input.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"codex-cc-triage: invalid Claude JSON: {error}", file=sys.stderr)
        return 1

    if not isinstance(payload, dict):
        print("codex-cc-triage: Claude JSON root must be an object", file=sys.stderr)
        return 1
    if payload.get("is_error") is True:
        print(
            f"codex-cc-triage: Claude reported an error: {payload.get('result', '')}",
            file=sys.stderr,
        )
        return 2

    session_id = payload.get("session_id")
    result = payload.get("result")
    if not isinstance(session_id, str) or not isinstance(result, str):
        print(
            "codex-cc-triage: Claude JSON needs string session_id and result",
            file=sys.stderr,
        )
        return 1
    try:
        parsed_id = uuid.UUID(session_id)
    except ValueError:
        print(
            f"codex-cc-triage: invalid Claude session_id: {session_id}", file=sys.stderr
        )
        return 1
    if str(parsed_id) != session_id.lower():
        print(
            f"codex-cc-triage: non-canonical Claude session_id: {session_id}",
            file=sys.stderr,
        )
        return 1

    args.id_output.write_text(f"{session_id}\n", encoding="utf-8")
    args.result_output.write_text(result, encoding="utf-8")
    cost = payload.get("total_cost_usd")
    turns = payload.get("num_turns")
    duration_ms = payload.get("duration_ms")
    metadata = {
        "model_requested": os.environ.get("CODEX_CC_TRIAGE_MODEL", "sonnet"),
        "effort_requested": os.environ.get("CODEX_CC_TRIAGE_EFFORT") or "provider-default",
        "cost_usd": cost
        if isinstance(cost, (int, float)) and not isinstance(cost, bool)
        else None,
        "duration_ms": duration_ms
        if isinstance(duration_ms, int) and not isinstance(duration_ms, bool)
        else None,
        "num_turns": turns
        if isinstance(turns, int) and not isinstance(turns, bool)
        else None,
    }
    args.meta_output.write_text(
        json.dumps(metadata, separators=(",", ":")) + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
