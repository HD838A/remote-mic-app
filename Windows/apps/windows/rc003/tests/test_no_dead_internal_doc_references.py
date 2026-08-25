"""Regression test (XRBM-022 In-scope item 9): no publicly shipped/tracked
file may reference a path inside docs/tasks/, docs/reports/, docs/reviews/,
or docs/releases/ - the repository root .gitignore intentionally excludes
those directories (they hold internal task books, implementation reports,
and independent-review verdicts), so they never exist in a real public
clone/checkout. A path pointing into one of them is a dead link for every
GitHub user who is not this project's internal contributors.

"Publicly shipped/tracked" is defined the same way git itself defines it:
tracked files plus untracked-but-not-ignored files
(``git ls-files --cached --others --exclude-standard``), which automatically
respects the real .gitignore - including the gitignored directories
themselves - so this test does not hand-maintain a second exclusion list
that could silently drift out of sync with the actual .gitignore.
"""

import re
import subprocess
import unittest
from pathlib import Path

_RC003_ROOT = Path(__file__).resolve().parents[1]
_REPO_ROOT = _RC003_ROOT.parents[2]

# Requires a real filename character right after the trailing slash, so a
# bare, legitimate directory mention (e.g. ".gitignore"'s own "docs/tasks/"
# line, or prose that just names the directory) never matches - only an
# actual dead reference to a specific file inside one of these directories
# does.
_DEAD_DOC_REFERENCE_RE = re.compile(r"docs/(?:tasks|reports|reviews|releases)/[A-Za-z0-9]")

_GITIGNORED_DOC_PREFIXES = ("docs/tasks/", "docs/reports/", "docs/reviews/", "docs/releases/")


def _public_tree_files():
    try:
        result = subprocess.run(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
            cwd=_REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
    except FileNotFoundError:
        return None  # git itself is not available on this machine
    return [_REPO_ROOT / line for line in result.stdout.splitlines() if line]


class NoDeadInternalDocReferencesTests(unittest.TestCase):
    def test_public_tree_has_zero_dead_gitignored_doc_references(self):
        files = _public_tree_files()
        if files is None:
            self.skipTest("git executable not available to enumerate the public tree")

        violations = []
        for path in files:
            if not path.is_file():
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            for match in _DEAD_DOC_REFERENCE_RE.finditer(text):
                line_no = text.count("\n", 0, match.start()) + 1
                relative = path.relative_to(_REPO_ROOT)
                violations.append(f"{relative}:{line_no}: {match.group(0)}")

        self.assertEqual(
            violations,
            [],
            "public/tracked tree references gitignored "
            "docs/(tasks|reports|reviews|releases)/ paths that do not exist "
            f"in a real clone: {violations}",
        )

    def test_git_ls_files_actually_excludes_the_gitignored_doc_directories(self):
        # Regression guard for the scan's own premise above: if
        # `git ls-files` ever stopped honoring .gitignore here (e.g. run
        # outside a git repository, or .gitignore no longer covers these
        # paths), the scan would silently pass over real dead references
        # instead of ever seeing them. Fail loudly instead of trusting that
        # silently.
        files = _public_tree_files()
        if files is None:
            self.skipTest("git executable not available to enumerate the public tree")

        self.assertGreater(len(files), 0)
        relative_files = {path.relative_to(_REPO_ROOT).as_posix() for path in files}
        for path in files:
            relative_str = path.relative_to(_REPO_ROOT).as_posix()
            self.assertFalse(
                relative_str.startswith(_GITIGNORED_DOC_PREFIXES),
                f"git ls-files unexpectedly returned a gitignored doc path: {relative_str}",
            )
        self.assertIn(
            "AGENTS.md",
            relative_files,
            "the active repository must track its model-handover entry point",
        )


if __name__ == "__main__":
    unittest.main()
