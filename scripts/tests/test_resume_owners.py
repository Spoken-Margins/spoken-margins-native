"""scripts/resume_owners.py: a new copy of the "should the source resume" decision fails the guard (#3032).

The table below is the scanner's neighbouring cases: each says whether a line is a row, so a case that starts
failing means the heuristic moved and the script's docstring needs to follow. The last class runs the scan over the
app and SessionKit against the baseline, which is the guard itself.
"""
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import resume_owners as ro  # noqa: E402


def names(source):
    return [row['name'] for row in ro.scan_source('P/X.swift', source)]


def writes(source, name):
    return {row['name']: row['writes'] for row in ro.scan_source('P/X.swift', source)}[name]


class WhatIsAResumeDeclaration(unittest.TestCase):
    def test_every_declaration_kind_is_a_row(self):
        for kind in ('var', 'let', 'func', 'struct', 'enum', 'class', 'actor', 'protocol', 'typealias', 'case'):
            with self.subTest(kind):
                self.assertEqual(names(f'{kind} shouldResumeNow'), ['shouldResumeNow'])

    def test_every_name_the_audit_lists_is_a_row(self):
        for name in ro.RESUME_NAMES:
            with self.subTest(name):
                self.assertEqual(names(f'var {name}: Bool'), [name])

    def test_a_prefix_or_suffix_around_the_name_is_still_a_row(self):
        self.assertEqual(names('var lastShouldResumeAfterInterruption = false'), ['lastShouldResumeAfterInterruption'])
        self.assertEqual(names('var PendingResumeState = 0'), ['PendingResumeState'])
        self.assertEqual(names('var priorPhaseForResume: Phase?'), ['priorPhaseForResume'])
        self.assertEqual(names('struct AudioPlaybackInterruptionResumePolicy {}'), ['AudioPlaybackInterruptionResumePolicy'])

    def test_a_backtick_name_is_a_row(self):
        self.assertEqual(names('var `shouldResume`: Bool'), ['shouldResume'])

    def test_a_function_parameter_label_or_internal_name_is_a_row(self):
        self.assertEqual(names('func interruptionEnded(shouldResume: Bool) {}'), ['shouldResume'])
        self.assertEqual(names('func ended(_ options: Int, shouldResume resume: Bool) {}'), ['shouldResume'])
        self.assertEqual(names('func ended(with flag: Bool, again shouldResume: Bool) {}'), ['shouldResume'])
        self.assertEqual(names('func ended(handler: (Bool) -> Void, shouldResume: Bool) {}'), ['shouldResume'])

    def test_a_call_or_a_read_is_not_a_row(self):
        self.assertEqual(names('interruptionEnded(shouldResume: true)'), [])
        self.assertEqual(names('if shouldResume { play() }'), [])
        self.assertEqual(names('let x = other.priorPhase'), [])

    def test_a_comment_or_a_string_is_not_a_row(self):
        self.assertEqual(names('// var shouldResume: Bool\n/* var pendingResume */ let ok = 1'), [])
        self.assertEqual(names('let text = "var shouldResume = false"'), [])
        self.assertEqual(names('let text = """\nvar shouldResume = false\n"""'), [])

    def test_an_unrelated_name_is_not_a_row(self):
        for name in ('resumeButton', 'playbackPhase', 'prior', 'systemVolume', 'pauseCount', 'resumed'):
            with self.subTest(name):
                self.assertEqual(names(f'var {name} = 0'), [])

    def test_an_unterminated_string_does_not_eat_the_rest_of_the_file(self):
        self.assertEqual(names('let a = "oops\nvar shouldResume = false'), ['shouldResume'])


class WhatIsAWrite(unittest.TestCase):
    SOURCE = '''
    var shouldResume = false
    func a() { shouldResume = true }
    func b() { self.shouldResume = false }
    func c() { state.shouldResume = true }
    func d() { if shouldResume == true { shouldResume = !shouldResume } }
    func e() { if shouldResume != false {} }
    func f() { shouldResume ||= true }
    '''

    def test_assignments_count_and_comparisons_and_the_initial_value_do_not(self):
        # a, b, c, and the assignment inside d. `==` and `!=` are reads. `||=` is not Swift, so it is not a write.
        self.assertEqual(writes(self.SOURCE, 'shouldResume'), 4)

    def test_a_declaration_with_an_initial_value_is_not_a_write(self):
        self.assertEqual(writes('var shouldResume: Bool = false', 'shouldResume'), 0)
        self.assertEqual(writes('var shouldResume = false', 'shouldResume'), 0)

    def test_a_compound_assignment_is_a_write(self):
        self.assertEqual(writes('var pendingPlaybackPosition = 0.0\nfunc a() { pendingPlaybackPosition += 1 }', 'pendingPlaybackPosition'), 1)

    def test_a_longer_name_that_contains_the_name_is_not_its_write(self):
        source = 'var shouldResume = false\nfunc a() { shouldResumeAfter = true }'
        self.assertEqual(writes(source, 'shouldResume'), 0)


class WhatFailsTheCheck(unittest.TestCase):
    def rows(self, source, file='P/X.swift'):
        return ro.scan_source(file, source)

    def baseline(self, rows):
        return {ro.key(row): {'writes': row['writes']} for row in rows}

    def test_a_new_declaration_fails_and_names_the_file_and_the_owner(self):
        old = self.rows('var shouldResume = false')
        new = self.rows('var shouldResume = false\nvar shouldResumeAgain = false')
        found = ro.problems(new, self.baseline(old))
        self.assertEqual(len(found), 1)
        self.assertIn('P/X.swift:2', found[0])
        self.assertIn('shouldResumeAgain', found[0])

    def test_the_same_name_in_another_file_fails(self):
        old = self.rows('var shouldResume = false', 'P/X.swift')
        new = self.rows('var shouldResume = false', 'P/Y.swift')
        self.assertEqual(len(ro.problems(new, self.baseline(old))), 1)

    def test_a_new_write_site_for_a_known_flag_fails(self):
        old = self.rows('var shouldResume = false\nfunc a() { shouldResume = true }')
        new = self.rows('var shouldResume = false\nfunc a() { shouldResume = true }\nfunc b() { shouldResume = false }')
        found = ro.problems(new, self.baseline(old))
        self.assertEqual(len(found), 1)
        self.assertIn('2 places', found[0])

    def test_fewer_writes_or_a_fixed_row_pass(self):
        old = self.rows('var shouldResume = false\nfunc a() { shouldResume = true }')
        self.assertEqual(ro.problems(self.rows('var shouldResume = false'), self.baseline(old)), [])
        self.assertEqual(ro.problems([], self.baseline(old)), [])

    def test_the_owning_file_is_not_scanned(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sources = root / 'Packages' / 'K' / 'Sources' / 'K'
            sources.mkdir(parents=True)
            (sources / 'Owner.swift').write_text('var shouldResume = false\n')
            (sources / 'Other.swift').write_text('var shouldResume = false\n')
            original = ro.OWNING_FILES
            ro.OWNING_FILES = ('Packages/K/Sources/K/Owner.swift',)
            try:
                self.assertEqual([r['file'] for r in ro.scan_tree(root)], ['Packages/K/Sources/K/Other.swift'])
            finally:
                ro.OWNING_FILES = original

    def test_test_targets_are_not_scanned(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tests = root / 'Packages' / 'K' / 'Tests' / 'KTests'
            tests.mkdir(parents=True)
            (tests / 'T.swift').write_text('var shouldResume = false\n')
            self.assertEqual(ro.scan_tree(root), [])


class TheGuardOnTheRealTree(unittest.TestCase):
    def test_no_new_copy_of_the_resume_decision_and_no_new_write_site(self):
        found = ro.problems(ro.scan_tree(), ro.load_baseline())
        self.assertEqual(found, [], '\n'.join(found))

    def test_the_baseline_names_the_flags_the_audit_listed(self):
        keys = set(ro.load_baseline())
        for needle in ('SessionEngine.swift::priorPhase', 'SessionEngine.swift::systemPause',
                       'SupertonicSpeechPlaybackClient.swift::shouldResumeAfterInterruption',
                       'MarginRecordingInterruption.swift::PendingResume',
                       'AudioAdapters.swift::AudioPlaybackInterruptionResumePolicy',
                       'HandsFreeMarginCoordinator.swift::shouldResume'):
            with self.subTest(needle):
                self.assertTrue(any(k.endswith(needle) for k in keys), needle)

    def test_every_baseline_row_still_exists_or_the_baseline_is_tightened(self):
        stale = sorted(set(ro.load_baseline()) - {ro.key(row) for row in ro.scan_tree()})
        self.assertEqual(stale, [], 'fixed rows: run scripts/resume_owners.py --update')


if __name__ == '__main__':
    unittest.main()
