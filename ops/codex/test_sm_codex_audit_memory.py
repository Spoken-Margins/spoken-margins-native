"""Review memory regressions from #580's recorded audit/decision comments."""
import importlib.util
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sm_codex_audit as audit
import sm_codex_worker as worker

FILE = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/PlaybackStartCue.swift'
TITLE = 'Slow synchronous startup still misses the one-second feedback requirement'
OLD = 'ff249c5' + '0' * 33
HEAD = 'abcdef0' + '0' * 33
# Exact relevant recorded #580 comments, 2026-10-05.
OWNER = {'created_at': '2026-10-05T07:47:38Z', 'body':
         '**Owner decision (2026-10-05 07:47Z):** Cole chose to merge #580 with the late-chime '
         'finding (slow synchronous setup blocking the main thread) accepted and tracked in #842. '
         'Once T3 passes on the current head, he\'ll merge by hand. Any other new audit finding is still fixed here.'}
PRIOR = {'created_at': '2026-10-05T16:58:21Z', 'body':
         '**Codex audit (Astra) on `ff249c5`**\n\n'
         f'- **[P2] {TITLE}** — `{FILE}:90–95`. '
         'The cue is scheduled only after the model publishes the engine’s returned snapshot.'}
# The documented format for migrating that recorded owner decision. This is
# test input, not a newly attributed owner decision on GitHub.
ACCEPTED = {'created_at': '2026-10-05T17:00:00Z', 'body':
            '**Accepted audit finding:**\n'
            '- Audited sha7: `ff249c5`\n'
            f'- File: `{FILE}`\n- Title: {TITLE}\n'
            '- Follow-up issue: #842\n- Accepted by: owner'}


def load_script(name, filename):
    root = Path(__file__).resolve().parents[2]
    sys.path.insert(0, str(root / 'scripts'))
    spec = importlib.util.spec_from_file_location(name, root / 'scripts' / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class MemoryTests(unittest.TestCase):
    def test_prompt_carries_recorded_decision_earlier_findings_and_delta(self):
        pr = {'number': 580, 'title': 'Startup cue', 'headRefOid': HEAD, 'lines': 1,
              'body': '', 'issues': [], 'comments': [OWNER, PRIOR, ACCEPTED]}
        block = audit.pr_context_block(pr, {}, '.sm-audit/pr-580.diff', HEAD, OLD,
                                       delta_context='Diff since last audited head ff249c5: delta.diff')
        prompt = audit.build_prompt([pr], [block], HEAD)
        for value in (OWNER['body'], PRIOR['body'], ACCEPTED['body'], 'delta.diff', '#842',
                      'Previously accepted', 'No blocking findings', 'judge it again'):
            self.assertIn(value, prompt)
        self.assertIn('privacy', prompt)
        self.assertIn('security', prompt)
        self.assertIn('owner data loss', prompt)
        self.assertIn('packet or database compatibility', prompt)

    def test_acceptance_identity_requires_every_documented_field(self):
        parsed = audit.accepted_finding(ACCEPTED)
        self.assertEqual(parsed['sha'], 'ff249c5')
        self.assertEqual(parsed['file'], FILE)
        self.assertEqual(parsed['title'], TITLE)
        self.assertEqual(parsed['issue'], 842)
        for field in ('Audited sha7', 'File', 'Title', 'Follow-up issue', 'Accepted by'):
            incomplete = dict(ACCEPTED, body='\n'.join(
                line for line in ACCEPTED['body'].splitlines() if field not in line))
            self.assertIsNone(audit.accepted_finding(incomplete))
        self.assertIsNone(audit.accepted_finding(OWNER))

    def test_thread_acceptance_requires_default_taken(self):
        for who, valid in (('owner', True), ('C4 (Default taken)', True), ('C4', False), ('', False)):
            with self.subTest(who=who):
                comment = dict(ACCEPTED, body=ACCEPTED['body'].replace('Accepted by: owner', 'Accepted by: ' + who))
                self.assertEqual(audit.accepted_finding(comment) is not None, valid)

    def test_neighboring_record_inputs_keep_identity_and_field_boundaries(self):
        body = ACCEPTED['body']
        cases = [(field + ' empty', '\n'.join(line.split(':', 1)[0] + ':' if
                  line.startswith('- ' + field + ':') else line for line in body.splitlines()), False)
                 for field in ('Audited sha7', 'File', 'Title', 'Follow-up issue', 'Accepted by')]
        cases += [
            ('duplicate owner', body + '\n- Accepted by: C4 (Default taken)', False),
            ('horizontal whitespace', body.replace('- File: ', '\t- File:\t'), True),
            ('Unicode title', body.replace(TITLE, 'Café — pause “here”'), True),
            ('lookalike owner', body.replace('Accepted by: owner', 'Accepted by: оwner'), False),
            ('lookalike issue', body.replace('#842', '＃842'), False),
            ('very long', body + '\n' + 'x' * audit.BODY_CHARS, False),
            ('parent file path', body.replace(FILE, '../Cue.swift'), False),
        ]
        for case, value, valid in cases:
            with self.subTest(case=case):
                self.assertEqual(audit.accepted_finding(dict(ACCEPTED, body=value)) is not None, valid)

    def test_finding_titles_preserve_code_and_punctuation_exactly(self):
        for title in ('`resumePlayback()` starts late', 'Keep the existing `cue`',
                      '`cue`', '“Pause” means pause', 'Café / café', TITLE):
            with self.subTest(title=title):
                comment = dict(ACCEPTED, body=ACCEPTED['body'].replace(TITLE, title))
                self.assertEqual(audit.accepted_finding(comment)['title'], title)

    def test_last_audited_head_uses_real_heading_not_finisher_reply(self):
        reply = {'created_at': '2026-10-05T18:00:00Z', 'body': '**Codex audit on `abcdef0`: fixed.**'}
        self.assertEqual(audit.last_audited_head([PRIOR, reply]), 'ff249c5')

    def test_incremental_diff_files_compare_real_git_heads_and_accepted_code(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, text=True).strip()
            git('init', '--quiet')
            git('config', 'user.name', 'test')
            git('config', 'user.email', 'test@example.com')
            (root / 'Cue.swift').write_text('let cue = 1\n')
            git('add', '.')
            git('commit', '--quiet', '-m', 'accepted code')
            accepted_sha = git('rev-parse', 'HEAD')
            (root / 'Other.swift').write_text('let value = 1\n')
            git('add', '.')
            git('commit', '--quiet', '-m', 'last audit')
            last_sha = git('rev-parse', 'HEAD')
            (root / 'Other.swift').write_text('let value = 2\n')
            git('add', '.')
            git('commit', '--quiet', '-m', 'current head')
            head = git('rev-parse', 'HEAD')
            (root / '.sm-audit').mkdir()
            decision = dict(ACCEPTED, body=ACCEPTED['body'].replace('ff249c5', accepted_sha[:7]).replace(FILE, 'Cue.swift'))
            previous = dict(PRIOR, body=PRIOR['body'].replace('ff249c5', last_sha[:7]))
            with patch.object(audit, 'REPO_ROOT', root):
                context = audit.incremental_diffs(root, 580, head, [decision, previous])
            paths = sorted((root / '.sm-audit').glob('*.diff'))
            self.assertEqual(len(paths), 2)
            texts = [path.read_text() for path in paths]
            self.assertIn('', texts)  # Accepted code really is unchanged.
            self.assertTrue(any('+let value = 2' in text for text in texts))
            self.assertIn('last audited head', context)
            self.assertIn('accepted finding code', context)
            with patch.object(audit, 'REPO_ROOT', root), patch.object(audit, 'log'):
                missing = dict(previous, body=previous['body'].replace(last_sha[:7], '0000000'))
                self.assertIn('Do not infer', audit.incremental_diffs(root, 580, head, [missing]))


class ConsumerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runner = load_script('audit_memory_runner', 'lane-runner.py')
        cls.merge = load_script('audit_memory_merge', 'merge_audit.py')

    def test_previously_accepted_only_is_clean_for_all_four_consumers(self):
        section = f'No blocking findings.\n\nPreviously accepted\n- {FILE}: {TITLE}; follow-up #842.'
        comment = {'body': audit.build_comment(580, HEAD, section, [580]),
                   'created_at': '2026-10-06T01:00:00Z'}
        pr = {'number': 580, 'headRefOid': HEAD, 'labels': [{'name': 'automerge'}], 'comments': [comment]}
        lane = {'created_at': '2026-10-06T00:00:00Z', 'body':
                'Lane report pr580-r1 — PASS | commit abcdef0 · tier T1\n'
                '<!-- lane-request: {"commit":"abcdef0","tier":"T1"} -->',
                'user': {'login': 'github-actions[bot]'}}
        self.assertIsNone(worker.audit_findings_on_head(pr))
        self.assertIsNone(self.runner.audit_blocker([comment], HEAD))
        self.assertIsNone(self.merge.hand_merge_gap([lane, comment], HEAD, '2026-10-06T02:00:00Z'))
        self.assertTrue(audit.rearm_decision(pr, [lane, comment], [
            {'event': 'labeled', 'label': {'name': 'automerge'}, 'created_at': '2026-10-05T23:00:00Z'}])[0])

    def test_new_finding_next_to_accepted_one_still_blocks(self):
        section = f'[P1] New wrong-item playback in Other.swift:10.\n\nPreviously accepted\n- {TITLE}; #842.'
        comment = {'body': audit.build_comment(580, HEAD, section, [580]),
                   'created_at': '2026-10-06T01:00:00Z'}
        pr = {'number': 580, 'headRefOid': HEAD, 'labels': [{'name': 'automerge'}], 'comments': [comment]}
        self.assertIsNotNone(worker.audit_findings_on_head(pr))
        self.assertIsNotNone(self.runner.audit_blocker([comment], HEAD))
        self.assertIn('blocking findings', self.merge.hand_merge_gap([comment], HEAD, '2026-10-06T02:00:00Z'))
        self.assertFalse(audit.rearm_decision(pr, [comment], None)[0])


if __name__ == '__main__':
    unittest.main()
