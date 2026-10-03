#!/usr/bin/env python3
"""Decide whether a push to main publishes a GhosttyNextKit release.

Rules (coordinator decision 2026-10-03):
1. Skip when no build input changed since the newest release tag that is an
   ancestor of HEAD. Documentation files (NON_BUILD_INPUTS) are not build
   inputs; every other path is.
2. A release label is never reused. The label is `<flavor>+<12-char sha>`
   and the tag is `xcframework-<sha>-<flavor>`; both name exactly one
   commit. If the tag already exists, publishing is refused (exit 3).

Usage: release_plan.py --repo DIR --head SHA --flavor FLAVOR [--github-output FILE]
Prints `publish=true|false`, `label=...`, `tag=...`, `reason=...`.
Exit codes: 0 decided, 3 refused (tag exists), 2 usage error.
"""
from __future__ import annotations

import argparse
import fnmatch
import subprocess
import sys

TAG_PREFIX = "xcframework-"
NON_BUILD_INPUTS = (
    "*.md",
    "docs/*",
    ".github/ISSUE_TEMPLATE/*",
    ".github/DISCUSSION_TEMPLATE/*",
    "LICENSE",
    "CODEOWNERS",
    ".github/VOUCHED.td",
)


def git(repo: str, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", repo, *args], check=check, capture_output=True, text=True)


def is_build_input(path: str) -> bool:
    return not any(fnmatch.fnmatch(path, pattern) for pattern in NON_BUILD_INPUTS)


def release_tags(repo: str) -> list[str]:
    out = git(repo, "tag", "--list", TAG_PREFIX + "*").stdout.split()
    return out


def newest_ancestor_release(repo: str, head: str) -> str | None:
    """The release tag on the nearest ancestor commit of head (not head itself)."""
    best: tuple[int, str] | None = None
    for tag in release_tags(repo):
        commit = git(repo, "rev-list", "-n", "1", tag).stdout.strip()
        if commit == head:
            continue
        if git(repo, "merge-base", "--is-ancestor", commit, head, check=False).returncode != 0:
            continue
        distance = int(git(repo, "rev-list", "--count", f"{commit}..{head}").stdout.strip())
        if best is None or distance < best[0]:
            best = (distance, tag)
    return best[1] if best else None


def plan(repo: str, head: str, flavor: str) -> tuple[int, dict[str, str]]:
    head = git(repo, "rev-parse", head).stdout.strip()
    tag = f"{TAG_PREFIX}{head}-{flavor}"
    label = f"{flavor}+{head[:12]}"
    result = {"publish": "false", "label": label, "tag": tag, "reason": ""}
    if tag in release_tags(repo):
        result["reason"] = f"tag {tag} already exists; a label is never reused"
        return 3, result
    base = newest_ancestor_release(repo, head)
    if base is None:
        result.update(publish="true", reason="no earlier release")
        return 0, result
    changed = [p for p in git(repo, "diff", "--name-only", f"{base}..{head}").stdout.splitlines() if p]
    inputs = [p for p in changed if is_build_input(p)]
    if not inputs:
        result["reason"] = f"no build input changed since {base} ({len(changed)} non-build files)"
        return 0, result
    result.update(publish="true", reason=f"{len(inputs)} build inputs changed since {base}, e.g. {inputs[0]}")
    return 0, result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--flavor", required=True)
    parser.add_argument("--github-output")
    args = parser.parse_args()
    code, result = plan(args.repo, args.head, args.flavor)
    lines = [f"{k}={v}" for k, v in result.items()]
    print("\n".join(lines))
    if args.github_output:
        with open(args.github_output, "a") as handle:
            handle.write("\n".join(lines) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
