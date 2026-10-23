import importlib.util
from pathlib import Path
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('substack_canary_issue', SCRIPTS / 'substack_canary_issue.py')
canary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(canary)

FAILED = """Substack canary FAILED: the app's parser missed a publisher voice, or found none on any feed.

- **https://thezvi.substack.com/feed**: FAIL
  - [Post A](https://thezvi.substack.com/p/a): FAIL, parser missed: the parser read no post data from a Substack page (no_preloads); the page holds a completed tts item
- **https://www.noahpinion.blog/feed**: pass (a voice found)
  - [Post B](https://www.noahpinion.blog/p/b): VOICE: generated_voice
"""


class SubstackCanaryIssueTests(unittest.TestCase):
    def test_one_issue_never_one_a_day(self):
        sig = canary.signature(FAILED)
        self.assertEqual(canary.decide(1, False, None, sig), 'open')
        # The same breakage on the next day's newer posts reads the same: no new comment.
        newer = FAILED.replace('Post A', 'Post C').replace('/p/a', '/p/c')
        self.assertEqual(canary.decide(1, True, sig, canary.signature(newer)), None)
        different = FAILED.replace('completed tts item', 'completed voiceover item')
        self.assertEqual(canary.decide(1, True, sig, canary.signature(different)), 'comment')

    def test_a_pass_is_noted_once_and_an_inconclusive_run_files_nothing(self):
        self.assertEqual(canary.decide(0, True, 'abc', 'x'), 'pass_note')
        self.assertIsNone(canary.decide(0, True, 'pass', 'x'))
        self.assertIsNone(canary.decide(0, False, None, 'x'))
        self.assertIsNone(canary.decide(3, True, 'abc', 'x'))
        self.assertIsNone(canary.decide(3, False, None, 'x'))


class RequestHeaderTests(unittest.TestCase):
    def test_a_write_says_it_is_json_and_a_read_does_not(self):
        from unittest import mock

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return b'[]'

        with mock.patch.object(canary.urllib.request, 'urlopen', return_value=Response()) as opened:
            canary.request('POST', '/repos/o/r/issues', 't', {'title': 'x'})
            canary.request('GET', '/repos/o/r/issues', 't')
        write, read = (call.args[0] for call in opened.call_args_list)
        self.assertEqual(write.get_header('Content-type'), 'application/json')  # form-encoded gets 415 (#2265)
        self.assertIsNone(read.get_header('Content-type'))


if __name__ == '__main__':
    unittest.main()
