#!/usr/bin/env python3
"""Fingerprint a Git worktree and build a bounded review context."""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import subprocess
import sys
from pathlib import Path

DEFAULT_CONTEXT_LIMIT = 5 * 1024 * 1024
DEFAULT_FILE_LIMIT = 1024 * 1024


class GitError(RuntimeError):
    """A Git subprocess failed."""


def git(root: Path, *args: str, check: bool = True) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise GitError(
            detail or f"git {' '.join(args)} failed with exit {result.returncode}"
        )
    return result.stdout


def has_head(root: Path) -> bool:
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--verify", "HEAD^{commit}"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def pathspecs(state_rel: str) -> tuple[str, ...]:
    return (".", f":(exclude){state_rel}", f":(exclude){state_rel}/**")


def worktree_diff(root: Path, state_rel: str, *, binary: bool) -> bytes:
    options = ["--no-ext-diff"]
    if binary:
        options.append("--binary")
    else:
        options.append("--find-renames")

    if has_head(root):
        return git(root, "diff", *options, "HEAD", "--", *pathspecs(state_rel))

    staged = git(root, "diff", *options, "--cached", "--", *pathspecs(state_rel))
    unstaged = git(root, "diff", *options, "--", *pathspecs(state_rel))
    return staged + unstaged


def staged_and_unstaged_diffs(root: Path, state_rel: str) -> tuple[bytes, bytes]:
    specs = pathspecs(state_rel)
    if has_head(root):
        staged = git(
            root, "diff", "--no-ext-diff", "--binary", "--cached", "HEAD", "--", *specs
        )
    else:
        staged = git(
            root, "diff", "--no-ext-diff", "--binary", "--cached", "--", *specs
        )
    unstaged = git(root, "diff", "--no-ext-diff", "--binary", "--", *specs)
    return staged, unstaged


def review_diff(
    root: Path, state_rel: str, base_ref: str | None
) -> tuple[str, bytes, bytes]:
    if not has_head(root):
        inventory = git(root, "status", "--short", "-uall", "--", *pathspecs(state_rel))
        return "(unborn)", inventory, worktree_diff(root, state_rel, binary=False)

    if not base_ref:
        inventory = git(
            root,
            "diff",
            "--no-ext-diff",
            "--name-status",
            "--find-renames",
            "HEAD",
            "--",
            *pathspecs(state_rel),
        )
        diff = git(
            root,
            "diff",
            "--no-ext-diff",
            "--find-renames",
            "HEAD",
            "--",
            *pathspecs(state_rel),
        )
        return "HEAD", inventory, diff

    if base_ref.startswith("-"):
        raise ValueError("base ref must not start with '-'")
    git(root, "rev-parse", "--verify", f"{base_ref}^{{commit}}")
    merge_base = git(root, "merge-base", base_ref, "HEAD").decode().strip()
    inventory = git(
        root,
        "diff",
        "--no-ext-diff",
        "--name-status",
        "--find-renames",
        merge_base,
        "--",
        *pathspecs(state_rel),
    )
    diff = git(
        root,
        "diff",
        "--no-ext-diff",
        "--find-renames",
        merge_base,
        "--",
        *pathspecs(state_rel),
    )
    return f"{base_ref} (merge-base {merge_base})", inventory, diff


def untracked_paths(root: Path, state_rel: str) -> list[Path]:
    raw = git(root, "ls-files", "--others", "--exclude-standard", "-z", "--", ".")
    state_prefix = f"{state_rel.rstrip('/')}/"
    paths: list[Path] = []
    for item in raw.split(b"\0"):
        if not item:
            continue
        relative = item.decode("utf-8", errors="surrogateescape")
        if relative == state_rel or relative.startswith(state_prefix):
            continue
        paths.append(Path(relative))
    return sorted(paths, key=lambda path: os.fsencode(path.as_posix()))


def hash_path(digest: hashlib._Hash, root: Path, relative: Path) -> None:
    encoded = os.fsencode(relative.as_posix())
    digest.update(b"path\0" + encoded + b"\0")
    absolute = root / relative
    info = absolute.lstat()
    digest.update(f"{stat.S_IFMT(info.st_mode)}:{info.st_mode & 0o7777}\0".encode())

    if absolute.is_symlink():
        digest.update(b"symlink\0" + os.fsencode(os.readlink(absolute)))
        return
    if not absolute.is_file():
        digest.update(b"non-file\0")
        return

    with absolute.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)


def fingerprint(root: Path, state_rel: str) -> str:
    digest = hashlib.sha256()
    head = (
        git(root, "rev-parse", "--verify", "HEAD^{commit}", check=False).strip()
        or b"(unborn)"
    )
    branch = (
        git(root, "symbolic-ref", "-q", "HEAD", check=False).strip() or b"(detached)"
    )
    staged, unstaged = staged_and_unstaged_diffs(root, state_rel)
    digest.update(b"head\0" + head + b"\0branch\0" + branch + b"\0")
    digest.update(b"staged\0" + staged + b"\0unstaged\0" + unstaged + b"\0")
    for relative in untracked_paths(root, state_rel):
        hash_path(digest, root, relative)
    return digest.hexdigest()


class BoundedWriter:
    def __init__(self, path: Path, limit: int) -> None:
        self.path = path
        self.limit = limit
        self.written = 0
        self.truncated = False
        self._handle = path.open("wb")

    def write(self, content: bytes) -> None:
        if self.truncated or not content:
            return
        remaining = self.limit - self.written
        if remaining <= 0:
            self.truncated = True
            return
        chunk = content[:remaining]
        self._handle.write(chunk)
        self.written += len(chunk)
        if len(chunk) != len(content):
            self.truncated = True

    def close(self) -> None:
        if self.truncated:
            self._handle.write(b"\n\n[context truncated by codex-cc-tuner]\n")
        self._handle.close()


def build_context(
    root: Path,
    state_rel: str,
    output: Path,
    base_ref: str | None,
    context_limit: int,
    file_limit: int,
) -> str:
    resolved_base, inventory, diff = review_diff(root, state_rel, base_ref)
    status_output = git(root, "status", "--short", "-uall", "--", *pathspecs(state_rel))
    writer = BoundedWriter(output, context_limit)
    try:
        writer.write(b"# codex-cc-tuner review context\n\n")
        writer.write(
            f"- repository: {root}\n- comparison: {resolved_base}\n\n".encode()
        )
        writer.write(b"## changed files against base\n\n```text\n")
        writer.write(inventory or b"(no committed or tracked changes)\n")
        writer.write(b"```\n\n")
        writer.write(b"## git status\n\n```text\n")
        writer.write(status_output or b"(clean)\n")
        writer.write(b"```\n\n## diff\n\n```diff\n")
        writer.write(diff or b"(no tracked diff)\n")
        writer.write(b"```\n")

        untracked = untracked_paths(root, state_rel)
        if untracked:
            writer.write(b"\n## untracked files\n")
        for relative in untracked:
            absolute = root / relative
            writer.write(
                f"\n### {relative.as_posix()}\n\n".encode("utf-8", errors="replace")
            )
            if absolute.is_symlink():
                target = os.readlink(absolute)
                writer.write(f"symlink -> {target}\n".encode("utf-8", errors="replace"))
                continue
            if not absolute.is_file():
                writer.write(b"(not a regular file)\n")
                continue
            size = absolute.stat().st_size
            with absolute.open("rb") as handle:
                sample = handle.read(file_limit + 1 if size <= file_limit else 8192)
            if b"\0" in sample:
                writer.write(f"(binary file, {size} bytes)\n".encode())
                continue
            if size > file_limit:
                writer.write(
                    (
                        f"(text file omitted, {size} bytes exceeds per-file limit; "
                        "inspect this path with Read)\n"
                    ).encode()
                )
                continue
            writer.write(b"```text\n")
            writer.write(sample)
            if sample and not sample.endswith(b"\n"):
                writer.write(b"\n")
            writer.write(b"```\n")
    finally:
        writer.close()
    if writer.truncated:
        raise ValueError(
            f"review context exceeds {context_limit} bytes; split the change or raise "
            "CODEX_CC_TUNER_CONTEXT_LIMIT"
        )
    return resolved_base


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("fingerprint", "context"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--state-rel", required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--base-ref")
    parser.add_argument(
        "--context-limit",
        type=int,
        default=int(
            os.environ.get("CODEX_CC_TUNER_CONTEXT_LIMIT", DEFAULT_CONTEXT_LIMIT)
        ),
    )
    parser.add_argument(
        "--file-limit",
        type=int,
        default=int(os.environ.get("CODEX_CC_TUNER_FILE_LIMIT", DEFAULT_FILE_LIMIT)),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    try:
        if args.action == "fingerprint":
            print(fingerprint(root, args.state_rel))
            return 0
        if args.output is None:
            raise ValueError("--output is required for context")
        if args.context_limit <= 0 or args.file_limit <= 0:
            raise ValueError("context and file limits must be positive")
        comparison = build_context(
            root,
            args.state_rel,
            args.output,
            args.base_ref,
            args.context_limit,
            args.file_limit,
        )
        print(comparison)
        return 0
    except (GitError, OSError, ValueError) as error:
        print(f"codex-cc-tuner: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
