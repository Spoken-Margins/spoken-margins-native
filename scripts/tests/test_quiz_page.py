"""The "Find an episode to talk about" page (Site/quiz/, #4707): its tests, its data copy and its promises.

The questions and the prompt are data in Contracts/quiz/find-something.v1.json; the site serves a byte-for-byte copy.
Node runs the prompt and page tests (scripts/tests/quiz_*.test.mjs) on the Node .nvmrc names, found the way the web
step finds it, and this file checks what Node can't: the copy, the HTML's fixed text, and that the page stores and
requests nothing it shouldn't. If no suitable Node is installed the test fails; it never skips.
"""
import importlib.util
import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
QUIZ_DIR = ROOT / "Site" / "quiz"
DATA = ROOT / "Contracts" / "quiz" / "find-something.v1.json"

spec = importlib.util.spec_from_file_location("verification_for_quiz_page", SCRIPTS / "verify-tests.py")
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)

LOAD_FAILED = "The questions didn't load. Check your connection, then try again."
GITHUB_JSON = "https://github.com/Spoken-Margins/spoken-margins-native/blob/main/Contracts/quiz/find-something.v1.json"


def html() -> str:
    return (QUIZ_DIR / "index.html").read_text(encoding="utf-8")


def source(name: str) -> str:
    return (QUIZ_DIR / name).read_text(encoding="utf-8")


class QuizNodeTests(unittest.TestCase):
    def test_the_prompt_and_page_tests_pass_on_the_pinned_node(self):
        node = verification.node_for_nvmrc() / "node"
        result = subprocess.run(
            [str(node), "--test", "scripts/tests/quiz_prompt.test.mjs", "scripts/tests/quiz_page.test.mjs"],
            cwd=ROOT, capture_output=True, text=True, timeout=120)
        tail = "\n".join((result.stdout + result.stderr).splitlines()[-40:])
        self.assertEqual(result.returncode, 0, tail)


class QuizDataCopyTests(unittest.TestCase):
    def test_the_site_copy_matches_the_contracts_file(self):
        result = subprocess.run([str(SCRIPTS / "sync-quiz-data.py"), "--check"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_sync_script_says_what_it_did_and_rejects_other_arguments(self):
        result = subprocess.run([str(SCRIPTS / "sync-quiz-data.py"), "--nope"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage", result.stderr)

    def test_the_heading_and_intro_in_the_html_are_the_data_word_for_word(self):
        data = json.loads(DATA.read_text(encoding="utf-8"))
        page = html()
        heading = re.search(r"<h1>(.*?)</h1>", page, re.S)
        intro = re.search(r'<p class="intro">(.*?)</p>', page, re.S)
        self.assertIsNotNone(heading)
        self.assertIsNotNone(intro)
        self.assertEqual(heading.group(1), data["title"])
        self.assertEqual(intro.group(1), data["intro"])


class QuizHtmlTests(unittest.TestCase):
    def test_a_browser_without_the_script_still_reads_the_page(self):
        page = html()
        self.assertIn('<html lang="en">', page)
        self.assertIn("<noscript><p>This page needs JavaScript to build your prompt. Nothing you type is sent anywhere.</p></noscript>", page)
        self.assertIn('<p class="pitch">', page)
        self.assertIn("<footer>", page)

    def test_a_module_that_never_ran_says_so(self):
        page = html()
        fallback = re.search(r"<script>(.*?)</script>", page, re.S)
        self.assertIsNotNone(fallback, "no inline fallback script")
        self.assertIn("dataset.quiz", fallback.group(1))
        self.assertIn(LOAD_FAILED, fallback.group(1))
        self.assertNotIn("retry", fallback.group(1))
        self.assertLess(page.index("<script>"), page.index('<script type="module" src="./page.js"></script>'))

    def test_the_pitch_is_one_line_with_one_link_to_join(self):
        pitch = re.search(r'<p class="pitch">(.*?)</p>', html(), re.S).group(1)
        self.assertEqual(re.findall(r'href="([^"]+)"', pitch), ["/join/"])
        self.assertTrue(pitch.startswith("Have the conversation in Spoken Margins:"))
        self.assertIn("It's in private beta.", pitch)
        for banned in ("share link", "friend's answer", "hear their answer"):
            self.assertNotIn(banned, pitch.lower())

    def test_the_footer_links_the_open_data_and_the_privacy_policy(self):
        footer = re.search(r"<footer>(.*?)</footer>", html(), re.S).group(1)
        self.assertEqual(re.findall(r'href="([^"]+)"', footer), [GITHUB_JSON, "/privacy/"])

    def test_the_page_names_every_part_the_script_and_later_work_rely_on(self):
        page = html()
        for fixed in ('id="quiz-status"', 'id="quiz"', 'id="prompt" hidden', 'id="prompt-heading" tabindex="-1"',
                      'id="prompt-text" readonly', 'id="copy"', 'id="copy-status" aria-live="polite"',
                      'class="reset" hidden', 'id="start-over"'):
            self.assertIn(fixed, page)

    def test_nothing_on_the_page_comes_from_another_origin(self):
        page = html()
        for url in re.findall(r'(?:src|href)="([^"]+)"', page):
            self.assertTrue(url.startswith(("/", "./")) or url == GITHUB_JSON, f"{url} is another origin")
        self.assertNotIn("<link", page, "the page carries its own style")


class QuizScriptPromiseTests(unittest.TestCase):
    def test_the_browser_gets_wrappers_never_the_bare_window_functions(self):
        # Called as env.fetch(...) or env.setTimeout(...), Window's own functions throw "Illegal invocation".
        script = source("page.js")
        self.assertIn("(url) => fetch(url)", script)
        self.assertIn("(fn, ms) => setTimeout(fn, ms)", script)
        self.assertNotRegex(script, r"fetch:\s*fetch\b")
        self.assertNotRegex(script, r"setTimeout:\s*setTimeout\b")

    def test_nothing_is_stored_and_nothing_is_requested_but_the_questions(self):
        for name in ("page.js", "quiz.js"):
            script = source(name)
            for banned in ("localStorage", "sessionStorage", "document.cookie", "indexedDB", "XMLHttpRequest",
                           "sendBeacon", "http://", "https://"):
                self.assertNotIn(banned, script, f"{name} mentions {banned}")
        self.assertEqual(len(re.findall(r"find-something\.json", source("page.js"))), 1)
        self.assertIn('dataURL: new URL("./v1/find-something.json", import.meta.url)', source("page.js"))
        self.assertEqual(len(re.findall(r"\bfetch\(", source("quiz.js"))), 0)


if __name__ == "__main__":
    unittest.main()
