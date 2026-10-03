"""Tests for next/release_plan.py: docs-only skip and never-reused labels."""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_plan  # noqa: E402


class ReleasePlanTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.invalid")
        self.git("config", "user.name", "t")
        self.git("config", "tag.gpgSign", "false")
        self.git("config", "commit.gpgSign", "false")
        self.commit("src/a.zig", "one")
        self.base = self.head()
        self.git("tag", f"xcframework-{self.base}-ios-v5")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", self.repo, *args], check=True, capture_output=True, text=True).stdout.strip()

    def head(self) -> str:
        return self.git("rev-parse", "HEAD")

    def commit(self, path: str, text: str) -> None:
        file = Path(self.repo) / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
        self.git("add", path)
        self.git("commit", "-q", "-m", f"change {path}")

    def test_docs_only_change_skips(self) -> None:
        self.commit("NEXT.md", "notes")
        self.commit("docs/guide.md", "guide")
        code, result = release_plan.plan(self.repo, "HEAD", "ios-v5")
        self.assertEqual(code, 0)
        self.assertEqual(result["publish"], "false")

    def test_build_input_change_publishes_with_unique_label(self) -> None:
        self.commit("NEXT.md", "notes")
        self.commit("src/b.zig", "two")
        code, result = release_plan.plan(self.repo, "HEAD", "ios-v5")
        self.assertEqual(code, 0)
        self.assertEqual(result["publish"], "true")
        self.assertEqual(result["label"], f"ios-v5+{self.head()[:12]}")
        self.assertEqual(result["tag"], f"xcframework-{self.head()}-ios-v5")

    def test_workflow_change_is_a_build_input(self) -> None:
        self.commit(".github/workflows/next-xcframework.yml", "on: push")
        _, result = release_plan.plan(self.repo, "HEAD", "ios-v5")
        self.assertEqual(result["publish"], "true")

    def test_existing_tag_is_refused(self) -> None:
        self.commit("src/c.zig", "three")
        self.git("tag", f"xcframework-{self.head()}-ios-v5")
        code, result = release_plan.plan(self.repo, "HEAD", "ios-v5")
        self.assertEqual(code, 3)
        self.assertEqual(result["publish"], "false")

    def test_two_releases_never_share_a_label(self) -> None:
        self.commit("src/d.zig", "four")
        _, first = release_plan.plan(self.repo, "HEAD", "ios-v5")
        self.git("tag", first["tag"])
        self.commit("src/e.zig", "five")
        _, second = release_plan.plan(self.repo, "HEAD", "ios-v5")
        self.assertNotEqual(first["label"], second["label"])
        self.assertNotEqual(first["tag"], second["tag"])

    def test_no_earlier_release_publishes(self) -> None:
        self.git("tag", "-d", f"xcframework-{self.base}-ios-v5")
        _, result = release_plan.plan(self.repo, "HEAD", "ios-v5")
        self.assertEqual(result["publish"], "true")


if __name__ == "__main__":
    unittest.main()
