"""docs/open-source/baseline-build-34.md must name only things that exist (#1852).

The page is the reference for "behaviour preserved" when the code is extracted or made public. A path, script or
command that has since been renamed would send a reader to nothing, and a pin or SHA copied wrongly would make the
reference false. This reads the page the way a contributor would: every repo path it names must exist, every script it
tells you to run must exist, and the SHA and SwiftPM pins it states must be the ones the tag holds.
"""
import json
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PAGE = ROOT / 'docs' / 'open-source' / 'baseline-build-34.md'
INDEX = ROOT / 'docs' / 'open-source' / 'README.md'
TAG = 'testflight/0.1-build-34'

SPAN = re.compile(r'`([^`\n]+)`')
LINK = re.compile(r'\]\(([^)\s]+)\)')
TOP_LEVEL = ('App/', 'Packages/', 'Contracts/', 'docs/', 'scripts/', 'TestPlans/', 'ops/', '.github/')
FULL_SHA = re.compile(r'\b[0-9a-f]{40}\b')


def page_text():
    return PAGE.read_text()


def git(*args):
    return subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, text=True)


def tag_commit():
    result = git('rev-parse', '--verify', '--quiet', f'{TAG}^{{commit}}')
    return result.stdout.strip() if result.returncode == 0 else None


def repo_paths(text):
    """Backticked tokens that name a file or folder in this repo, wildcards excluded."""
    paths = set()
    for span in SPAN.findall(text):
        for token in span.split():
            token = token.rstrip('.,;:')
            if token.startswith(TOP_LEVEL) and '*' not in token and '<' not in token:
                paths.add(token)
    return paths


class BaselinePageTests(unittest.TestCase):
    def test_the_page_exists_and_is_linked_from_the_index(self):
        self.assertTrue(PAGE.is_file(), 'docs/open-source/baseline-build-34.md is missing')
        self.assertTrue(INDEX.is_file(), 'docs/open-source/README.md is missing')
        self.assertIn('baseline-build-34.md', INDEX.read_text())

    def test_every_path_the_page_names_exists(self):
        text = page_text()
        paths = repo_paths(text)
        self.assertGreater(len(paths), 10, 'the page names too few paths for this test to mean anything')
        missing = sorted(path for path in paths if not (ROOT / path).exists())
        self.assertEqual([], missing, f'baseline-build-34.md names paths that do not exist: {missing}')

    def test_every_relative_link_resolves(self):
        broken = []
        for target in LINK.findall(page_text()):
            if target.startswith(('http://', 'https://', '#')):
                continue
            if not (PAGE.parent / target.split('#')[0]).exists():
                broken.append(target)
        self.assertEqual([], broken)

    def test_every_command_the_page_tells_you_to_run_names_a_real_script(self):
        text = page_text()
        commands = [span for span in SPAN.findall(text) if re.match(r'(\.venv/bin/python |\./|scripts/)', span)]
        self.assertGreater(len(commands), 3, 'the page lists too few commands for this test to mean anything')
        for command in commands:
            script = next((word for word in command.split() if word.startswith('scripts/')), None)
            if script is None and command.startswith('./'):
                script = command.split()[0][2:]
            self.assertIsNotNone(script, f'cannot find the script in `{command}`')
            self.assertTrue((ROOT / script).exists(), f'`{command}` names {script}, which does not exist')

    def test_the_owner_acceptance_line_is_never_written_for_him(self):
        lines = [line for line in page_text().splitlines() if line.startswith('Owner acceptance:')]
        self.assertEqual(1, len(lines), 'the page needs exactly one "Owner acceptance:" line')
        self.assertTrue(
            lines[0] == 'Owner acceptance: not recorded' or lines[0].startswith('Owner acceptance: "'),
            'an acceptance must quote the owner; until he accepts it reads "Owner acceptance: not recorded"')

    def test_the_sha_and_pins_are_the_ones_the_tag_holds(self):
        commit = tag_commit()
        if commit is None:
            self.skipTest(f'{TAG} is not fetched in this checkout')
        text = page_text()
        self.assertIn(commit, text, f'the page does not state the tag commit {commit}')
        parent = git('rev-parse', f'{commit}^1').stdout.strip()
        tag_object = git('rev-parse', TAG).stdout.strip()
        for role, sha in (('first parent', parent), ('tag object', tag_object)):
            self.assertIn(sha, text, f'the page does not state the tag\'s {role} {sha}')
        resolved = json.loads(git('show', f'{commit}:Packages/SessionKit/Package.resolved').stdout)
        revisions = {pin['state']['revision'] for pin in resolved['pins']}
        for sha in set(FULL_SHA.findall(text)):
            # A full SHA on the page is a git object here (the tag commit, its parent, the tag object) or a SwiftPM pin.
            self.assertTrue(
                sha in revisions or git('cat-file', '-e', sha).returncode == 0,
                f'{sha} on the page is neither an object in this repo nor a SwiftPM revision')
        for pin in resolved['pins']:
            self.assertIn(pin['identity'], text.lower(), f'the page does not name {pin["identity"]}')
            self.assertIn(pin['state']['version'], text, f'the page does not state {pin["identity"]} {pin["state"]["version"]}')
            self.assertIn(pin['state']['revision'], text, f'the page does not state the revision of {pin["identity"]}')


if __name__ == '__main__':
    unittest.main()
