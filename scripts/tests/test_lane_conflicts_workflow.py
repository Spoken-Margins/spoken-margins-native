"""The lane-conflicts workflow takes its script from the base branch's live tip, and a missing script doesn't fail (#2043).

The job used to check out `pull_request.base.sha`, the commit GitHub recorded for the PR. For a PR older than #1964 that
tree has no scripts/lane_conflicts.py, so `check` failed with exit 2 on an armed PR for a fault that was the job's own.
"""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

WORKFLOW = (Path(__file__).resolve().parents[2] / '.github/workflows/lane-conflicts.yml').read_text()


def checkout_ref():
    match = re.search(r'uses: actions/checkout@v4\s+with:(?:\s+#[^\n]*)*\s+ref: ([^\n]+)', WORKFLOW)
    assert match, 'checkout ref not found'
    return match.group(1).strip()


def sweep_script():
    """The shell text of the sweep step's `run: |` block."""
    match = re.search(r'\n( +)run: \|\n((?:\1 +[^\n]*\n|\n)+)', WORKFLOW)
    assert match, 'sweep step not found'
    indent = len(match.group(1)) + 2
    return '\n'.join(line[indent:] for line in match.group(2).split('\n'))


class LaneConflictsWorkflowTests(unittest.TestCase):
    def test_the_checkout_follows_the_base_branch_not_the_recorded_base_commit(self):
        ref = checkout_ref()
        self.assertNotIn('base.sha', ref)
        self.assertNotIn('github.sha', ref)
        self.assertIn('github.event.pull_request.base.ref', ref)
        # Push and dispatch events have no pull_request, so they use the trunk, as BASE_REF does (#1492).
        self.assertIn("vars.SM_TRUNK || 'main'", ref)

    def run_sweep(self, scripts):
        with tempfile.TemporaryDirectory() as root:
            (Path(root) / 'scripts').mkdir()
            for name, text in scripts.items():
                (Path(root) / 'scripts' / name).write_text(text)
            return subprocess.run(['bash', '-c', sweep_script()], cwd=root, capture_output=True, text=True,
                                  env={'PATH': '/usr/bin:/bin:/usr/local/bin', 'BASE_REF': 'next', 'ONLY_PR': '42'})

    def test_a_missing_script_passes_with_a_notice(self):
        result = self.run_sweep({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('::notice::', result.stdout)

    def test_a_present_script_runs_with_the_base_and_pr_arguments(self):
        result = self.run_sweep({'lane_conflicts.py': 'import sys\nprint("ran", *sys.argv[1:])\nsys.exit(3)\n'})
        self.assertEqual(result.returncode, 3, 'a real result from the script must still decide the check')
        self.assertIn('ran --base next --pr 42', result.stdout)


if __name__ == '__main__':
    unittest.main()
