"""The "Find an episode to talk about" page (Site/quiz/, #4707): its tests, its data copy and its promises.

The questions and the prompt are data in Contracts/quiz/find-something.v1.json; the site serves a byte-for-byte copy.
Node runs the prompt, page and check tests (scripts/tests/quiz_*.test.mjs) on the Node .nvmrc names, found the way the web
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
            [str(node), "--test", "scripts/tests/quiz_prompt.test.mjs", "scripts/tests/quiz_page.test.mjs",
             "scripts/tests/quiz_check.test.mjs"],
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

    def test_the_footer_links_the_open_data_and_the_site_policies(self):
        # The copyright and content-policy links are on every static footer (test_designated_agent_links,
        # test_share_link_policy_pages), a departure from the Design's footer that the PR names.
        footer = re.search(r"<footer>(.*?)</footer>", html(), re.S).group(1)
        self.assertEqual(re.findall(r'href="([^"]+)"', footer),
                         [GITHUB_JSON, "/privacy/", "/copyright/", "/content-policy/"])

    def test_the_empty_live_regions_stay_rendered_so_a_screen_reader_announces_them(self):
        style = re.search(r"<style>(.*?)</style>", html(), re.S).group(1)
        self.assertNotIn("display:none", style.replace("display:none !important", ""))

    def test_the_page_names_every_part_the_script_and_later_work_rely_on(self):
        page = html()
        for fixed in ('id="quiz-status"', 'id="quiz"', 'id="prompt" hidden', 'id="prompt-heading" tabindex="-1"',
                      'id="prompt-text" readonly', 'id="copy"', 'id="copy-status" aria-live="polite"',
                      'class="reset" hidden', 'id="start-over"', 'id="answer-text"', 'id="check"',
                      'id="check-message" aria-live="polite"', 'id="check-results"', 'id="none-worked" hidden',
                      'id="follow-up" hidden', 'id="follow-up-text" readonly', 'id="copy-follow-up"',
                      'id="follow-up-status" aria-live="polite"'):
            self.assertIn(fixed, page)

    def test_nothing_on_the_page_comes_from_another_origin(self):
        page = html()
        for url in re.findall(r'(?:src|href)="([^"]+)"', page):
            same_origin = (url.startswith("/") and not url.startswith("//")) or url.startswith("./")
            self.assertTrue(same_origin or url == GITHUB_JSON, f"{url} is another origin")
        self.assertNotIn("<link", page, "the page carries its own style")


class QuizScriptPromiseTests(unittest.TestCase):
    def test_the_browser_gets_wrappers_never_the_bare_window_functions(self):
        # Called as env.fetch(...) or env.setTimeout(...), Window's own functions throw "Illegal invocation".
        script = source("page.js")
        self.assertIn("(url) => fetch(url)", script)
        self.assertIn("(fn, ms) => setTimeout(fn, ms)", script)
        self.assertNotRegex(script, r"fetch:\s*fetch\b")
        self.assertNotRegex(script, r"setTimeout:\s*setTimeout\b")

    def test_nothing_is_stored_and_nothing_is_requested_but_the_questions_and_apple_lookups(self):
        lookup = "https://itunes.apple.com/lookup?id="
        for name in ("page.js", "quiz.js"):
            script = source(name)
            for banned in ("localStorage", "sessionStorage", "document.cookie", "indexedDB", "XMLHttpRequest",
                           "sendBeacon", "http://"):
                self.assertNotIn(banned, script, f"{name} mentions {banned}")
            # The only address either script may name is Apple's lookup (#5270), in quiz.js, once.
            addresses = re.findall(r"https://[^\s\"'`]+", script)
            self.assertEqual(addresses, [lookup] if name == "quiz.js" else [], f"{name} names {addresses}")
        self.assertEqual(len(re.findall(r"find-something\.json", source("page.js"))), 1)
        self.assertIn('dataURL: new URL("./v1/find-something.json", import.meta.url)', source("page.js"))
        self.assertEqual(len(re.findall(r"\bfetch\(", source("quiz.js"))), 0)

    def test_the_lookup_runs_only_from_the_check_and_carries_no_cookies(self):
        script = source("page.js")
        self.assertEqual(len(re.findall(r"(?<!\.)\bfetch\(", script)), 2, "the questions file and the lookup")
        self.assertIn('lookup: (url) => fetch(url, { credentials: "omit", referrerPolicy: "no-referrer" })', script)
        self.assertEqual(len(re.findall(r"env\.lookup\(", script)), 1)
        self.assertEqual(len(re.findall(r'page\.check\.addEventListener\("click"', script)), 1)

    def test_the_check_block_words_follow_the_design(self):
        page = html()
        self.assertIn("with web search turned on. Then paste its answer below to check the links.</p>", page)
        self.assertIn('<label for="answer-text" class="field-label">Your assistant\'s answer</label>', page)
        self.assertIn('<button type="button" id="check">Check links</button>', page)
        self.assertIn('<button type="button" id="copy-follow-up">Copy follow-up prompt</button>', page)
        # The words are in the data or the script, never only a colour: blue and orange tones each carry an icon.
        script = source("page.js")
        for words in ("This is a whole show, not an episode.", "Couldn't find an episode at this link.",
                      "Not checked here. Open it to see.", "Couldn't check this one just now.",
                      "Plays, but there's no title to check. Open it to make sure.",
                      "You're offline. Copy the prompt now and check links when you're back online."):
            self.assertIn(words, script)

if __name__ == "__main__":
    unittest.main()
