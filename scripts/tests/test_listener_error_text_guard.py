"""No user-visible failure line carries the system's raw error text (#3317, the bug class behind #1965).

`ListenerErrorText` turns a code or a Foundation dump ("The operation couldn't be completed. (NSCocoaErrorDomain error
513.)") into one plain line. It only helps where it is called, and a prefix such as "Couldn't use that folder: " in front
of `error.localizedDescription` hid the dump from its check. This guard lists every `localizedDescription` in the app and
its extensions that is not a log reason. A line that reaches the listener goes through `ListenerErrorText.message(for:)`
or `.line(prefix:error:)`; a line that is read only by a program or by Diagnostics is listed in `ALLOWED` with why.
A new unlisted use fails this test.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'App'
ROOTS = [
    APP / 'SpokenMarginsApp' / 'Sources',
    APP / 'SpokenMarginsShareExtension' / 'Sources',
    APP / 'SpokenMarginsBrowserTextExtension' / 'Sources',
    APP / 'SpokenMarginsWatchApp' / 'Sources',
    APP / 'SpokenMarginsWatch' / 'Sources',
    APP / 'SharedSources',
]

# A log reason: written to Diagnostics or handed to a program, in machine words.
LOG_REASON = re.compile(
    r'diagnostics\[|recordDiagnostic|\bnote\w*\(|\breason:|"[a-z][a-z0-9_]*:\s*\\\(|"\\\([^)]*\): [a-z_]+:\\\('
)

# (file name, the line as written, stripped) -> why the raw text may stay.
ALLOWED = {
    ('Gate1AppModel+LibrarySeeding.swift', 'libraryAccessError = "This build could not open your existing library. This attempt did not reset it. Do not use Reset Library or delete the app; install a compatible build and try again. Details: \\(error.localizedDescription)"'):
        'deliberate: the Details are what a bug report needs when the library will not open (the line says do not reset); the owner has not been asked to drop them',
    ('SharedMarginsImportMessage.swift', 'let description = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)'): 'checked by ListenerErrorText.looksLikeCodeOrDump on the next line; its own generic sentence replaces a dump',
    ('ReadLaterModel.swift', 'let message = (error as? EditionError)?.localizedDescription'): 'our own EditionError text, read by the connection tracker',
    ('Gate1AppModel+RemoteProvider.swift', 'let presentation = LocalSummaryFailurePresentation(errorDescription: error.localizedDescription)'): 'the presentation type does its own plain-text step',
    ('PodcastDownloadCoordinator.swift', 'self.fail(updated, reason: error.localizedDescription)'): 'failureReason is read only by Diagnostics',
    ('PodcastDownloadCoordinator.swift', 'fail(recordsByItemId[attempt.itemId] ?? record, reason: error.localizedDescription)'): 'failureReason is read only by Diagnostics',
    ('PodcastDownloadCoordinator.swift', 'fail(record, reason: error.localizedDescription)'): 'failureReason is read only by Diagnostics',
}


def unlisted_uses():
    found = []
    for root in ROOTS:
        for path in sorted(root.rglob('*.swift')):
            for number, line in enumerate(path.read_text().splitlines(), 1):
                text = line.strip()
                if 'localizedDescription' not in text or text.startswith('//'):
                    continue
                if LOG_REASON.search(text) or (path.name, text) in ALLOWED:
                    continue
                found.append(f'{path.relative_to(ROOT)}:{number}: {text}')
    return found


class ListenerErrorTextGuardTests(unittest.TestCase):
    def test_no_failure_line_carries_the_systems_raw_error_text(self):
        self.assertEqual(
            unlisted_uses(), [],
            'Put the error through ListenerErrorText.message(for:) or .line(prefix:error:), or list the use in ALLOWED '
            'with why only a program reads it.')

    def test_every_allowed_use_still_exists(self):
        present = {
            (path.name, line.strip())
            for root in ROOTS for path in root.rglob('*.swift') for line in path.read_text().splitlines()
        }
        self.assertEqual([key for key in ALLOWED if key not in present], [], 'remove the entry; the line is gone')

    def test_the_log_reason_rule_does_not_swallow_a_prefixed_line(self):
        self.assertIsNone(LOG_REASON.search('errorMessage = "Couldn\'t save: \\(error.localizedDescription)"'))
        self.assertIsNone(LOG_REASON.search('reportFailure("Export all Margins failed: \\(error.localizedDescription)")'))
        self.assertIsNone(LOG_REASON.search('return "The file couldn\'t be read. \\(error.localizedDescription)"'))
        self.assertIsNotNone(LOG_REASON.search('return "skipped:\\(error.localizedDescription)"'))
        self.assertIsNotNone(LOG_REASON.search('diagnostics["x"] = "failed: \\(error.localizedDescription)"'))


    def test_every_prefix_the_app_builds_has_a_row_in_the_host_test(self):
        """The audit on PR #3325: a prefix added to a `ListenerErrorText.line` call needs its row in
        ListenerErrorTextTests, which feeds each one a Foundation dump."""
        call = re.compile(r'ListenerErrorText\.line\(prefix: "((?:[^"\\]|\\.)*)"')
        used = {
            match.group(1).replace("\\'", "'")
            for root in ROOTS for path in root.rglob('*.swift')
            for match in call.finditer(path.read_text())
        }
        tested = (ROOT / 'Packages' / 'SessionKit' / 'Tests' / 'SessionKitCoreTests' / 'ListenerErrorTextTests.swift').read_text()
        self.assertGreater(len(used), 10)
        self.assertEqual(sorted(prefix for prefix in used if f'"{prefix}"' not in tested), [])


if __name__ == '__main__':
    unittest.main()
