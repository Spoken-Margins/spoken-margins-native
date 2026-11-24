// The paste-back check on the quiz page (#5270): parsePaste and titlesMatch in Site/quiz/quiz.js against the table
// EpisodeLinkPasteTests also runs (Contracts/fixtures/find-something/paste-*.json and title-match.json), and the check
// block in Site/quiz/page.js driven in linkedom with a fake Apple lookup. The real lookup is the Real-use proof's.
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { parseHTML } from "linkedom";
import { start } from "../../Site/quiz/page.js";
import {
  appleEpisodeId, appleShowId, judgeLookup, linkKind, LOOKUP_LIMIT, lookupURL, parsePaste, renderFollowUp, titlesMatch,
} from "../../Site/quiz/quiz.js";

const quiz = JSON.parse(readFileSync(new URL("../../Contracts/quiz/find-something.v1.json", import.meta.url), "utf8"));
const html = readFileSync(new URL("../../Site/quiz/index.html", import.meta.url), "utf8");
const fixtureFolder = new URL("../../Contracts/fixtures/find-something/", import.meta.url);
const read = (name) => JSON.parse(readFileSync(new URL(name, fixtureFolder), "utf8"));
const pasteFixtures = readdirSync(fileURLToPath(fixtureFolder)).filter((name) => /^paste-.*\.json$/.test(name)).sort();
const flush = () => new Promise((resolve) => setImmediate(resolve));
const APPLE = "https://podcasts.apple.com/us/podcast";

test("there are paste fixtures for every kind of line the rule names", () => {
  assert.ok(pasteFixtures.length >= 5, `only ${pasteFixtures.length} paste fixtures`);
  const kinds = new Set(pasteFixtures.flatMap((name) => read(name).expected.map((entry) => entry.kind)));
  assert.deepEqual([...kinds].sort(), ["apple_episode", "apple_show", "other", "spotify", "substack", "youtube"]);
});

for (const name of pasteFixtures) {
  test(`${name} reads to its expected entries`, () => {
    const fixture = read(name);
    assert.deepEqual(parsePaste(fixture.text), fixture.expected);
  });
}

test("every pair in title-match.json, both ways round", () => {
  const { cases } = read("title-match.json");
  assert.ok(cases.length >= 20);
  for (const { a, b, match } of cases) {
    assert.equal(titlesMatch(a, b), match, `${a} / ${b}`);
    assert.equal(titlesMatch(b, a), match, `reversed: ${a} / ${b}`);
  }
});

test("link kinds and the Apple show and episode ids come from the address alone", () => {
  const rows = [
    [`${APPLE}/t/id1?i=100`, "apple_episode", "1", "100"],
    [`${APPLE}/t/id1`, "apple_show", "1", null],
    [`${APPLE}/t/id1?i=`, "apple_show", "1", null],
    [`${APPLE}/t/id1?i=12abc`, "apple_episode", "1", null],
    ["https://PODCASTS.APPLE.COM/us/podcast/t/id394775318?i=7&uo=4", "apple_episode", "394775318", "7"],
    ["https://itunes.apple.com/us/podcast/id152249110/?i=7", "apple_episode", "152249110", "7"],
    ["https://podcasts.apple.com/us/podcast/idea-show?i=7", "apple_episode", null, "7"],
    ["https://podcasts.apple.com/us/podcast/t/id12x?i=7", "apple_episode", null, "7"],
    ["https://podcasts.apple.com.evil.example/x/id1?i=1", "other", null, null],
    ["https://open.spotify.com/episode/abc", "spotify", null, null],
    ["https://music.youtube.com/watch?v=abc", "youtube", null, null],
    ["https://notyoutube.com/x", "other", null, null],
    ["not a url", "other", null, null],
  ];
  for (const [url, kind, show, episodeId] of rows) {
    assert.equal(linkKind(url), kind, url);
    assert.equal(appleShowId(url), show, url);
    assert.equal(appleEpisodeId(url), episodeId, url);
  }
  // The address the app's share-link check reads too (ShareLinkPlayCheckReads.isAppleLookupAddress).
  assert.equal(lookupURL("394775318"), "https://itunes.apple.com/lookup?id=394775318&entity=podcastEpisode&limit=200");
});

const episode = (trackId, trackName, extra = {}) => ({ wrapperType: "podcastEpisode", kind: "podcast-episode", trackId, trackName, ...extra });

test("judgeLookup finds the link's episode among the show's newest", () => {
  const entry = { claimedTitle: "The Kirkbride Plan" };
  const show = { wrapperType: "track", kind: "podcast", trackId: 394775318, trackName: "99% Invisible" };
  assert.deepEqual(judgeLookup(entry, "5", { results: [show, episode(4, "Other"), episode(5, "The Kirkbride Plan", { collectionName: "99% Invisible" })] }),
    { verdict: "right", resolvedTitle: "The Kirkbride Plan", show: "99% Invisible" });
  assert.equal(judgeLookup(entry, "5", { results: [show, episode(5, "Something Else Entirely")] }).verdict, "wrong");
  assert.equal(judgeLookup(entry, "5", { results: [show, episode(6, "The Kirkbride Plan")] }).verdict, "failed",
    "a show with fewer episodes than the lookup lists doesn't hold it");
  assert.equal(judgeLookup(entry, "5", { results: [show] }).verdict, "failed");
  assert.equal(judgeLookup(entry, "5", { resultCount: 0, results: [] }).verdict, "failed", "no such show");
  assert.equal(judgeLookup(entry, "5", null).verdict, "failed");
  assert.equal(judgeLookup(entry, "5", { results: [show, episode(5, "  ")] }).verdict, "failed");
  assert.equal(judgeLookup({ claimedTitle: null }, "5", { results: [episode(5, "Anything")] }).verdict, "unchecked");
  assert.equal(judgeLookup({ claimedTitle: "???" }, "5", { results: [episode(5, "Anything")] }).verdict, "unchecked");
  const full = [show, ...Array.from({ length: LOOKUP_LIMIT }, (_, i) => episode(1000 + i, `Episode ${i}`))];
  assert.equal(judgeLookup(entry, "5", { results: full }).verdict, "older", "a long show's older episode can't be told");
  assert.equal(judgeLookup({ claimedTitle: "Episode 7" }, "1007", { results: full }).verdict, "right");
});

test("the follow-up prompt names exactly the failed lines, as written", () => {
  const text = renderFollowUp(quiz, ["A — B | x | https://x.com/1", "C — D | https://x.com/2"]);
  assert.equal(text, `${quiz.followUp.opening}\n\nA — B | x | https://x.com/1\nC — D | https://x.com/2\n\n${quiz.followUp.closing}`);
});

// ---- The check block on the page ----

function build({ lookup, online = true, clipboard = "ok" } = {}) {
  const { document, window } = parseHTML(html);
  const calls = { lookups: [], writes: [], focus: [], selectAll: [], timers: [] };
  const env = {
    dataURL: "find-something.json",
    fetch: async () => ({ ok: true, json: async () => quiz }),
    lookup: async (url) => {
      calls.lookups.push(url);
      return lookup(url);
    },
    online: () => online,
    clipboard: { writeText: async (text) => { calls.writes.push(text); if (clipboard === "reject") throw new Error("no"); } },
    setTimeout: (fn, ms) => { calls.timers.push({ fn, ms }); return calls.timers.length; },
    clearTimeout: () => {},
    focus: (el) => calls.focus.push(el),
    scrollIntoView: () => {},
    selectAll: (el) => calls.selectAll.push(el),
  };
  const $ = (id) => document.getElementById(id);
  return {
    document, window, env, calls, $,
    async load() {
      await start(document, env);
      const now = $("q-now");
      now.value = "Cooking shows";
      now.dispatchEvent(new window.Event("input"));
      $("quiz").dispatchEvent(new window.Event("submit", { cancelable: true }));
    },
    async check(text) {
      $("answer-text").value = text;
      $("check").click();
      for (let i = 0; i < 10; i += 1) await flush();
    },
    rows: () => [...$("check-results").querySelectorAll("li")].map((li) => ({
      state: li.dataset.state,
      name: li.querySelector(".check-name").textContent,
      status: li.querySelector(".check-status").textContent,
      href: li.querySelector("a").getAttribute("href"),
    })),
  };
}

// Apple's lookup of show 1 (every Apple link below is ".../s/id1?i=N"): the show's record, then its episodes. A
// title of "error" makes the lookup fail; with no episodes the show doesn't exist.
const lookupFrom = (titles) => async (url) => {
  assert.equal(new URL(url).searchParams.get("id"), "1");
  if (Object.values(titles).includes("error")) return { ok: false, json: async () => ({}) };
  const episodes = Object.entries(titles).map(([id, title]) => episode(Number(id), title, { collectionName: "Show" }));
  const results = episodes.length ? [{ wrapperType: "track", kind: "podcast", trackId: 1 }, ...episodes] : [];
  return { ok: true, json: async () => ({ resultCount: results.length, results }) };
};

const MIXED = [
  `Show — The Right One | 30 min | clean | 05:00 | ${APPLE}/s/id1?i=11`,
  "Why: reasons.",
  `Show — Named One Way | 20 min | clean | 01:00 | ${APPLE}/s/id1?i=22`,
  `Show — Invented | 20 min | clean | 01:00 | ${APPLE}/s/id1?i=33`,
  `Show — A Whole Show | 20 min | clean | 01:00 | (show link) ${APPLE}/s/id1`,
  "Other — On Spotify | 20 min | clean | 01:00 | https://open.spotify.com/episode/abc",
  `Busy — Down | 20 min | clean | 01:00 | ${APPLE}/busy/id2?i=44`,
].join("\n");

test("the check block sits under the prompt and starts empty", async () => {
  const page = build({ lookup: lookupFrom({}) });
  await page.load();
  assert.equal(page.$("prompt").hidden, false);
  assert.equal(page.document.querySelector('label[for="answer-text"]').textContent, "Your assistant's answer");
  assert.equal(page.$("check").textContent, "Check links");
  assert.equal(page.$("check-results").hidden, true);
  assert.equal(page.$("follow-up").hidden, true);
  assert.equal(page.$("none-worked").hidden, true);
  assert.equal(page.$("none-worked").textContent, quiz.noneWorked);
  assert.deepEqual(page.calls.lookups, [], "nothing is looked up before the tap");
});

test("each line gets a row with an icon and words, and each show named by an Apple episode link is looked up once", async () => {
  const show1 = lookupFrom({ 11: "The Right One", 22: "Something Else Entirely" });
  const page = build({
    lookup: (url) => (new URL(url).searchParams.get("id") === "2" ? { ok: false, json: async () => ({}) } : show1(url)),
  });
  await page.load();
  await page.check(MIXED);
  assert.deepEqual(page.calls.lookups.sort(), ["1", "2"].map(lookupURL).sort());
  assert.deepEqual(page.rows().map((row) => [row.state, row.status]), [
    ["right", "✓ Plays: The Right One"],
    ["wrong", "⚠ Plays, but it's called \"Something Else Entirely\". Check it's the one you meant."],
    ["failed", "✕ Couldn't find an episode at this link."],
    ["show", "⚠ This is a whole show, not an episode."],
    ["other", "– Not checked here. Open it to see."],
    ["error", "? Couldn't check this one just now."],
  ]);
  assert.equal(page.rows()[0].name, "Show — The Right One");
  assert.equal(page.rows()[4].href, "https://open.spotify.com/episode/abc");
  for (const link of page.$("check-results").querySelectorAll("a")) {
    assert.equal(link.getAttribute("rel"), "noopener noreferrer");
    assert.equal(link.getAttribute("target"), "_blank");
  }
  for (const icon of page.$("check-results").querySelectorAll(".check-icon")) {
    assert.equal(icon.getAttribute("aria-hidden"), "true", "the words carry the meaning, not the icon");
  }
  assert.equal(page.$("check-message").textContent, "Checked 6 links. 1 of 6 plays the episode named.");
  assert.equal(page.$("none-worked").hidden, true);
  assert.equal(page.$("follow-up").hidden, false);
  assert.equal(page.$("follow-up-text").value, renderFollowUp(quiz, [MIXED.split("\n")[3], MIXED.split("\n")[4]]),
    "only the invented link and the show link, never the lookup error or the unchecked Spotify link");
});

test("when no link works the page says to turn on web search", async () => {
  const page = build({ lookup: lookupFrom({ 7: "Some Other Episode" }) });
  await page.load();
  await page.check(`A — B | ${APPLE}/s/id1?i=1\nC — D | ${APPLE}/s/id2`);
  assert.equal(page.$("none-worked").hidden, false);
  assert.equal(page.$("follow-up").hidden, false);
});

test("a line with no title to check plays but asks for a look", async () => {
  const page = build({ lookup: lookupFrom({ 9: "Anything" }) });
  await page.load();
  await page.check(`${APPLE}/s/id1?i=9`);
  assert.deepEqual(page.rows().map((row) => row.state), ["unchecked"]);
  assert.equal(page.rows()[0].name, `${APPLE}/s/id1?i=9`);
  assert.equal(page.$("follow-up").hidden, true);
});

test("an empty answer, an answer with no links and an offline browser each say so and look nothing up", async () => {
  const page = build({ lookup: lookupFrom({}) });
  await page.load();
  await page.check("   ");
  assert.equal(page.$("check-message").textContent, "Paste your assistant's answer first.");
  assert.equal(page.calls.focus.at(-1), page.$("answer-text"));
  await page.check("Radiolab\n99% Invisible");
  assert.equal(page.$("check-message").textContent,
    "No episode links in this answer. Ask your assistant to follow the prompt's line form.");
  const offline = build({ lookup: lookupFrom({}), online: false });
  await offline.load();
  await offline.check(`A — B | ${APPLE}/s/id1?i=1`);
  assert.equal(offline.$("check-message").textContent,
    "You're offline. Copy the prompt now and check links when you're back online.");
  assert.equal(offline.$("check-results").hidden, true);
  assert.deepEqual([...page.calls.lookups, ...offline.calls.lookups], []);
  // Offline, a paste with only show links still gets its rows: nothing needs the network.
  await offline.check(`A — B | ${APPLE}/s/id1`);
  assert.deepEqual(offline.rows().map((row) => row.state), ["show"]);
});

test("a second tap replaces the first check, and a slow answer from the first draws nothing", async () => {
  let release;
  const slow = new Promise((resolve) => { release = resolve; });
  let first = true;
  const page = build({
    lookup: async (url) => {
      if (first) { first = false; await slow; }
      return lookupFrom({ 1: "Old Title", 2: "New Title" })(url);
    },
  });
  // Both checks name show 1, so the second must make its own lookup, not reuse the first check's.
  await page.load();
  await page.check(`A — Old Title | ${APPLE}/s/id1?i=1`);
  assert.deepEqual(page.rows().map((row) => row.state), ["checking"]);
  await page.check(`A — New Title | ${APPLE}/s/id1?i=2`);
  release();
  for (let i = 0; i < 10; i += 1) await flush();
  assert.deepEqual(page.rows().map((row) => [row.state, row.status]), [["right", "✓ Plays: New Title"]]);
});

test("no more than four lookups run at once, one per show", async () => {
  let running = 0;
  let most = 0;
  const page = build({
    lookup: async (url) => {
      running += 1;
      most = Math.max(most, running);
      await flush();
      running -= 1;
      return { ok: true, json: async () => ({ results: [] }) };
    },
  });
  await page.load();
  const lines = Array.from({ length: 9 }, (_, i) => `A — B${i} | ${APPLE}/s/id${i + 1}?i=${i + 100}`);
  lines.push(`A — Same show again | ${APPLE}/s/id1?i=999`);
  await page.check(lines.join("\n"));
  for (let i = 0; i < 30; i += 1) await flush();
  assert.equal(page.calls.lookups.length, 9);
  assert.equal(most, 4);
  assert.deepEqual(page.rows().map((row) => row.state), Array(10).fill("failed"));
});

test("Copy follow-up prompt copies it, and a refused clipboard selects it instead", async () => {
  const page = build({ lookup: lookupFrom({}) });
  await page.load();
  await page.check(`A — B | ${APPLE}/s/id1?i=1`);
  page.$("copy-follow-up").click();
  await flush();
  assert.deepEqual(page.calls.writes, [page.$("follow-up-text").value]);
  assert.equal(page.$("copy-follow-up").textContent, "Copied");
  assert.equal(page.$("follow-up-status").textContent, "Follow-up prompt copied");
  const refused = build({ lookup: lookupFrom({}), clipboard: "reject" });
  await refused.load();
  await refused.check(`A — B | ${APPLE}/s/id1?i=1`);
  refused.$("copy-follow-up").click();
  await flush();
  assert.deepEqual(refused.calls.selectAll, [refused.$("follow-up-text")]);
  assert.equal(refused.$("copy-follow-up").textContent, "Copy follow-up prompt");
});

test("Start over clears the answer and the check", async () => {
  const page = build({ lookup: lookupFrom({}) });
  await page.load();
  await page.check(`A — B | ${APPLE}/s/id1?i=1`);
  page.$("start-over").click();
  assert.equal(page.$("answer-text").value, "");
  assert.equal(page.$("check-results").hidden, true);
  assert.equal(page.$("check-results").children.length, 0);
  assert.equal(page.$("follow-up").hidden, true);
  assert.equal(page.$("check-message").textContent, "");
});
