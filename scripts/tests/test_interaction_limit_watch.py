import importlib.util
import urllib.error
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('interaction_limit_watch', SCRIPTS / 'interaction_limit_watch.py')
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)

LIMIT = {'limit': 'collaborators_only', 'origin': 'repository', 'expires_at': '2027-04-21T16:56:10Z'}


def at(text):
    return datetime.fromisoformat(text).replace(tzinfo=timezone.utc)


class StageTests(unittest.TestCase):
    def test_the_stage_follows_the_days_left(self):
        self.assertEqual(watch.stage(LIMIT, at('2027-01-01T00:00:00')), 'ok')
        self.assertEqual(watch.stage(LIMIT, at('2027-03-22T16:56:09')), 'ok')  # 30 days and a second left
        self.assertEqual(watch.stage(LIMIT, at('2027-03-22T16:56:10')), 'warn30')  # exactly 30 days
        self.assertEqual(watch.stage(LIMIT, at('2027-04-14T16:56:09')), 'warn30')  # just over 7 days
        self.assertEqual(watch.stage(LIMIT, at('2027-04-14T16:56:10')), 'warn7')  # exactly 7 days
        self.assertEqual(watch.stage(LIMIT, at('2027-04-21T16:56:10')), 'gone')  # the moment it lapses

    def test_no_limit_at_all_is_gone_and_a_limit_without_an_end_is_fine(self):
        self.assertEqual(watch.stage({}, at('2026-11-01T00:00:00')), 'gone')  # the API's answer for none
        self.assertEqual(watch.stage(None, at('2026-11-01T00:00:00')), 'gone')
        self.assertEqual(watch.stage({'limit': 'collaborators_only'}, at('2030-01-01T00:00:00')), 'ok')


class DecideTests(unittest.TestCase):
    def test_nothing_is_filed_while_the_limit_is_far_off(self):
        self.assertIsNone(watch.decide('ok', False, set()))
        self.assertIsNone(watch.decide('ok', True, {'warn30'}))

    def test_one_issue_then_one_comment_per_stage(self):
        self.assertEqual(watch.decide('warn30', False, set()), 'open')
        self.assertIsNone(watch.decide('warn30', True, {'warn30'}))  # not one a day
        self.assertEqual(watch.decide('warn7', True, {'warn30'}), 'comment')
        self.assertIsNone(watch.decide('warn7', True, {'warn30', 'warn7'}))
        self.assertEqual(watch.decide('gone', True, {'warn30', 'warn7'}), 'comment')

    def test_a_lapsed_limit_with_no_issue_still_opens_one(self):
        self.assertEqual(watch.decide('gone', False, set()), 'open')


class MessageAndReadTests(unittest.TestCase):
    def test_the_message_names_the_date_and_the_marker_stage(self):
        self.assertIn('2027-04-21T16:56:10Z', watch.message('warn30', LIMIT))
        self.assertIn('under 7 days', watch.message('warn7', LIMIT))
        self.assertIn('is gone', watch.message('gone', {}))

    def test_a_token_that_cannot_read_the_limit_falls_back_to_the_known_date(self):
        error = urllib.error.HTTPError('u', 403, 'Forbidden', {}, None)
        with mock.patch.object(watch, 'request', side_effect=error):
            limit, note = watch.read_limit('o/r', 't')
        self.assertEqual(limit['expires_at'], watch.FALLBACK_EXPIRY)
        self.assertIn('HTTP 403', note)

    def test_any_other_failure_is_not_swallowed(self):
        error = urllib.error.HTTPError('u', 500, 'Server Error', {}, None)
        with mock.patch.object(watch, 'request', side_effect=error):
            with self.assertRaises(urllib.error.HTTPError):
                watch.read_limit('o/r', 't')

    def test_the_fallback_date_is_still_the_one_in_agents_md(self):
        root = SCRIPTS.parent
        self.assertIn('2027-04-21', (root / 'AGENTS.md').read_text())
        self.assertTrue(watch.FALLBACK_EXPIRY.startswith('2027-04-21'))


if __name__ == '__main__':
    unittest.main()
