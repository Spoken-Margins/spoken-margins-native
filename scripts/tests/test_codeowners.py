"""`.github/CODEOWNERS` keeps the owner on every path the merge rules hold for him, and nothing in it is stale (#4915).

The file asks for the owner's review; it blocks nothing today. A test stands behind it so a new owner-held path, or a
renamed script, cannot quietly leave the owner out of the review request. Parsed by hand: no YAML or glob package.
"""
import fnmatch
import importlib.util
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CODEOWNERS = ROOT / '.github' / 'CODEOWNERS'
OWNER = '@uncomposed'


def load_rules():
    spec = importlib.util.spec_from_file_location('lane_merge_rules_for_codeowners', ROOT / 'scripts' / 'lane_merge_rules.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def entries():
    """(pattern, owners) for each rule line, in file order."""
    found = []
    for number, line in enumerate(CODEOWNERS.read_text().splitlines(), 1):
        text = line.split('#', 1)[0].strip()
        if not text:
            continue
        parts = text.split()
        assert len(parts) >= 2, f'CODEOWNERS line {number} has a path and no owner: {line!r}'
        found.append((parts[0], parts[1:]))
    return found


def owners_of(path, rules):
    """The owners of a repo path: the last rule that matches it, as GitHub reads the anchored forms used here."""
    matched = None
    for pattern, owners in rules:
        anchored = pattern.lstrip('/')
        if pattern.endswith('/'):
            hit = path.startswith(anchored)
        else:
            hit = fnmatch.fnmatchcase(path, anchored)
        if hit:
            matched = owners
    return matched


class CodeownersTests(unittest.TestCase):
    def test_every_rule_names_only_the_owner(self):
        for pattern, owners in entries():
            self.assertEqual(owners, [OWNER], f'{pattern} must name only {OWNER}')

    def test_every_rule_is_anchored_and_matches_something(self):
        tracked = [p for p in ROOT.rglob('*') if p.is_file() and '.git' not in p.relative_to(ROOT).parts
                   and 'node_modules' not in p.relative_to(ROOT).parts and '.venv' not in p.relative_to(ROOT).parts]
        relative = [p.relative_to(ROOT).as_posix() for p in tracked]
        for pattern, _ in entries():
            self.assertTrue(pattern.startswith('/'), f'{pattern} must start with / so it cannot match a deeper folder')
            self.assertFalse(re.search(r'[!\[\]]', pattern), f'{pattern} uses syntax CODEOWNERS does not support')
            self.assertTrue(owners_of_any(pattern, relative), f'{pattern} matches no file: renamed or removed?')

    def test_owner_held_paths_are_covered(self):
        rules = entries()
        merge_rules = load_rules()
        held = sorted(merge_rules.OWNER_TAP_FILES)
        for prefix in merge_rules.OWNER_TAP_PREFIXES:
            held.append(prefix + 'workflows/merge-policy.yml')
        for path in held:
            self.assertEqual(owners_of(path, rules), [OWNER], f'{path} is held for the owner but CODEOWNERS misses it')

    def test_trust_and_gate_scripts_are_covered(self):
        rules = entries()
        for path in ('scripts/comment_trust.py', 'scripts/lane_sender.py', 'scripts/merge_policy.py',
                     'scripts/signoff_check.py', 'AGENTS.md', 'CLAUDE.md', '.claude/skills/lane-request/SKILL.md',
                     '.github/CODEOWNERS', 'ops/runner-guard/refuse-fork-jobs.sh', 'SECURITY.md'):
            self.assertEqual(owners_of(path, rules), [OWNER], f'{path} must stay covered')

    def test_ordinary_code_is_not_held(self):
        # The file must not turn every PR into a review request: that would hide the paths that matter.
        rules = entries()
        for path in ('App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift', 'docs/areas.md',
                     'Packages/SessionKit/Package.swift'):
            self.assertIsNone(owners_of(path, rules), f'{path} should not need the owner')


def owners_of_any(pattern, paths):
    return any(owners_of(path, [(pattern, [OWNER])]) for path in paths)


if __name__ == '__main__':
    unittest.main()
