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
        self.assertIsNone(watch.decide('ok', None, set()))
        self.assertIsNone(watch.decide('ok', 'open', {'warn30'}))

    def test_one_issue_then_one_comment_per_stage(self):
        self.assertEqual(watch.decide('warn30', None, set()), 'open')
        self.assertIsNone(watch.decide('warn30', 'open', {'warn30'}))  # not one a day
        self.assertEqual(watch.decide('warn7', 'open', {'warn30'}), 'comment')
        self.assertIsNone(watch.decide('warn7', 'open', {'warn30', 'warn7'}))
        self.assertEqual(watch.decide('gone', 'open', {'warn30', 'warn7'}), 'comment')

    def test_a_lapsed_limit_with_no_issue_still_opens_one(self):
        self.assertEqual(watch.decide('gone', None, set()), 'open')

    def test_a_closed_issue_means_the_owner_dealt_with_that_expiry(self):
        for stage in ('warn30', 'warn7', 'gone'):
            self.assertIsNone(watch.decide(stage, 'closed', {'warn30'}))

    def test_the_issue_is_named_for_the_expiry_and_a_limit_with_none_has_no_key(self):
        self.assertEqual(watch.issue_key(LIMIT), '2027-04-21')
        self.assertIsNone(watch.issue_key({}))
        self.assertIsNone(watch.issue_key(None))


def titled(key):
    return f'{watch.TITLE} ({key})'


def issue(number, state='open', body='', association='NONE', login='stranger', key='2027-04-21'):
    return {'number': number, 'state': state, 'title': titled(key), 'body': body,
            'author_association': association, 'user': {'login': login}}


def ours(number, **kwargs):
    return issue(number, association='COLLABORATOR', login='uncomposed', **kwargs)


def marker(stage):
    return f'<!-- interaction-limit: {stage} -->'


class RunTests(unittest.TestCase):
    def run_watch(self, found, comments, now='2027-03-25T00:00:00', limit=None):
        """Runs main against canned API answers and returns the POSTs it made and the GETs it asked. With no `limit`
        the token cannot read it and the fallback date applies."""
        posts, gets = [], []

        def fake(method, path, token, body=None):
            if method == 'POST':
                posts.append((path, body))
                return {'number': 99}
            gets.append(path)
            if path.endswith('/interaction-limits'):
                if limit is None:
                    raise urllib.error.HTTPError('u', 403, 'Forbidden', {}, None)
                return limit
            if path.startswith('/search/issues'):
                return {'items': found}
            return comments.get(int(path.split('/issues/')[1].split('/')[0]), [])

        env = {'GITHUB_REPOSITORY': 'o/r', 'GITHUB_TOKEN': 't'}
        with mock.patch.object(watch, 'request', side_effect=fake), mock.patch.dict('os.environ', env), \
                mock.patch('sys.argv', ['x', '--now', now + 'Z']):
            watch.main()
        return posts, gets

    def test_the_issue_is_found_by_a_title_search_not_a_page_scan(self):
        posts, gets = self.run_watch([], {})
        self.assertEqual([path for path, _ in posts], ['/repos/o/r/issues'])
        self.assertEqual(posts[0][1]['title'], titled('2027-04-21'))
        search = [path for path in gets if path.startswith('/search/issues')]
        self.assertEqual(len(search), 1)
        self.assertIn('in%3Atitle', search[0])
        self.assertFalse([path for path in gets if path.startswith('/repos/o/r/issues?')], 'no scan of the repository\'s issue list')

    def test_a_strangers_issue_with_our_title_does_not_receive_the_comment(self):
        posts, _ = self.run_watch([issue(5, body=marker('warn30'))], {})
        self.assertEqual([path for path, _ in posts], ['/repos/o/r/issues'])  # a real issue is opened

    def test_a_strangers_marker_does_not_silence_a_stage(self):
        stranger_comment = {'body': marker('warn7'), 'author_association': 'NONE', 'user': {'login': 'x'}}
        posts, _ = self.run_watch([ours(7, body=marker('warn30'))], {7: [stranger_comment]}, now='2027-04-15T00:00:00')
        self.assertEqual([path for path, _ in posts], ['/repos/o/r/issues/7/comments'])

    def test_the_bots_own_issue_and_marker_count(self):
        bot = issue(8, association='NONE', login='github-actions[bot]', body=marker('warn30'))
        self.assertEqual(self.run_watch([bot], {})[0], [])

    def test_a_closed_issue_of_ours_stops_the_daily_refiling_on_a_stale_fallback_date(self):
        self.assertEqual(self.run_watch([ours(9, state='closed', body=marker('warn30'))], {})[0], [])
        self.assertEqual(self.run_watch([ours(9, state='closed', body=marker('warn30'))], {}, now='2027-04-15T00:00:00')[0], [])

    def test_the_next_renewal_gets_its_own_warning_after_the_last_one_was_closed(self):
        """Cycle 2: the owner renewed to 2027-10-21 and closed the first issue; the new expiry is a new issue, so its
        30-day warning is sent, and so is the one after the next renewal."""
        old = ours(9, state='closed', body=marker('warn30'), key='2027-04-21')
        renewed = {'limit': 'collaborators_only', 'expires_at': '2027-10-21T16:56:10Z'}
        posts, _ = self.run_watch([old], {}, now='2027-09-25T00:00:00', limit=renewed)  # the old issue is still in the search
        self.assertEqual([path for path, _ in posts], ['/repos/o/r/issues'])
        self.assertEqual(posts[0][1]['title'], titled('2027-10-21'))

    def test_a_gone_limit_joins_the_open_issue_of_the_expiry_that_ran_out(self):
        open_issue = ours(3, body=marker('warn30'), key='2027-04-21')
        posts, _ = self.run_watch([open_issue], {3: [{'body': marker('warn7'), 'author_association': 'OWNER', 'user': {'login': 'u'}}]},
                                  now='2027-04-22T00:00:00', limit={})
        self.assertEqual([path for path, _ in posts], ['/repos/o/r/issues/3/comments'])
        self.assertIn('is gone', posts[0][1]['body'])

    def test_a_gone_limit_with_no_issue_at_all_opens_one_lapsed_issue(self):
        posts, _ = self.run_watch([], {}, now='2027-05-02T00:00:00', limit={})
        self.assertEqual(posts[0][1]['title'], titled('lapsed'))

    def test_a_gone_limit_files_nothing_more_once_the_newest_issue_is_marked_or_closed(self):
        marked = ours(4, body=marker('gone'), key='lapsed')
        self.assertEqual(self.run_watch([marked], {}, now='2027-06-02T00:00:00', limit={})[0], [])
        closed = ours(5, state='closed', key='2027-04-21')  # a lasting rule replaced the limit; the owner closed it
        self.assertEqual(self.run_watch([closed], {}, now='2027-06-02T00:00:00', limit={})[0], [])


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
