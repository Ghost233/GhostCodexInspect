"""Exercise release versioning through --dry-run with a local Git remote."""

import subprocess
import tempfile
import unittest
from pathlib import Path


RELEASE_SCRIPT = Path(__file__).resolve().with_name("release.sh")


class ReleaseVersionTest(unittest.TestCase):
    def test_version_increment(self):
        cases = [
            ("1.0.6+1", "1.0.7"),
            ("1.0.6", "1.0.7"),
            ("1.0.8", "1.0.9"),
            ("1.0.9", "1.1.0"),
            ("1.0.9+2", "1.1.0"),
            ("1.1.9", "1.2.0"),
            ("2.3.9", "2.4.0"),
        ]
        with tempfile.TemporaryDirectory(prefix="release-version-test-") as temp:
            root = Path(temp)
            remote = root / "origin.git"
            repo = root / "workspace"
            repo.mkdir()

            def git(*args):
                return subprocess.run(
                    ["git", *args],
                    cwd=repo,
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip()

            git("init", "--bare", str(remote))
            git("init", "-b", "main")
            git("config", "user.name", "Release Test")
            git("config", "user.email", "release-test@example.invalid")
            git("config", "commit.gpgsign", "false")
            git("remote", "add", "origin", str(remote))
            pubspec = repo / "pubspec.yaml"

            for current, expected in cases:
                with self.subTest(current=current):
                    original = f"version: {current}\n"
                    pubspec.write_text(original)
                    git("add", "pubspec.yaml")
                    git("commit", "-m", f"fixture {current}")
                    git("push", "origin", "main")
                    before = git("rev-parse", "HEAD")

                    result = subprocess.run(
                        ["bash", str(RELEASE_SCRIPT), "--dry-run"],
                        cwd=repo,
                        capture_output=True,
                        text=True,
                        timeout=15,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(pubspec.read_text(), original)
                    self.assertEqual(git("rev-parse", "HEAD"), before)
                    self.assertEqual(git("rev-parse", "origin/main"), before)
                    self.assertEqual(git("status", "--porcelain"), "")
                    self.assertEqual(git("tag", "--list"), "")
                    lines = result.stdout.splitlines()
                    self.assertIn(f"release: 下一版本: {expected}", lines)
                    self.assertIn(f"release: 发布 tag: v{expected}", lines)


if __name__ == "__main__":
    unittest.main()
