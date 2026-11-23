// The page for "Find an episode to talk about" (#4707): Site/quiz/page.js driven in linkedom with spies for focus,
// scrolling, the clipboard, the timer and fetch. The real browser is the Test Desk's and the Real-use proof's.
//
// linkedom has no radio groups, no form.elements and no activeElement, so the page keeps its answers in a JS object
// and these tests drive it with events on the elements. After a click that starts async work they flush one task
// with setImmediate: that lets pending promises settle, it is not a wait on the clock.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { parseHTML } from "linkedom";
import { mountQuiz, start } from "../../Site/quiz/page.js";
import { renderPrompt } from "../../Site/quiz/quiz.js";

const quiz = JSON.parse(readFileSync(new URL("../../Contracts/quiz/find-something.v1.json", import.meta.url), "utf8"));
const html = readFileSync(new URL("../../Site/quiz/index.html", import.meta.url), "utf8");
const flush = () => new Promise((resolve) => setImmediate(resolve));
const LOAD_FAILED = "The questions didn't load. Check your connection, then try again.";

function build({ clipboard = "ok", fetchResult } = {}) {
  const { document, window } = parseHTML(html);
  const calls = { focus: [], scroll: [], selectAll: [], writes: [], timers: [], cleared: [], fetches: 0 };
  let nextTimer = 1;
  const env = {
    dataURL: "find-something.json",
    fetch: async () => {
      calls.fetches += 1;
      return (fetchResult ?? (() => ({ ok: true, json: async () => quiz })))();
    },
    clipboard: clipboard === "none" ? null : {
      writeText: async (text) => {
        calls.writes.push(text);
        if (clipboard === "reject") throw new Error("denied");
        if (typeof clipboard === "function") await clipboard();
      },
    },
    setTimeout: (fn, ms) => { const id = nextTimer++; calls.timers.push({ fn, ms, id }); return id; },
    clearTimeout: (id) => calls.cleared.push(id),
    focus: (el) => calls.focus.push(el),
    scrollIntoView: (el) => calls.scroll.push(el),
    selectAll: (el) => calls.selectAll.push(el),
  };
  const $ = (id) => document.getElementById(id);
  const page = {
    document, window, env, calls, $,
    form: $("quiz"),
    radio: (name, value) => $("quiz").querySelector(`input[name="${name}"][value="${value}"]`),
    row: (name, value) => $("quiz").querySelector(`fieldset[data-q="${name}"] label[data-value="${value}"]`),
    type(id, value) {
      const input = $(`q-${id}`);
      input.value = value;
      input.dispatchEvent(new window.Event("input"));
    },
    choose(name, value) {
      const radio = page.radio(name, value);
      radio.checked = true;
      radio.dispatchEvent(new window.Event("change"));
    },
    make() { $("quiz").dispatchEvent(new window.Event("submit", { cancelable: true })); },
    async copy() { $("copy").click(); await flush(); },
    legend: (name) => $("quiz").querySelector(`fieldset[data-q="${name}"] legend`).textContent,
    label: (id) => $("quiz").querySelector(`div[data-q="${id}"] label`).textContent,
    prompt: () => $("prompt-text").value,
    async load() { await start(document, env); },
  };
  return page;
}

async function loaded(options) {
  const page = build(options);
  await page.load();
  return page;
}

test("the questions are drawn from the data, with A friend chosen and nothing else", async () => {
  const page = await loaded();
  assert.deepEqual(page.form.querySelectorAll("fieldset").length, 4);
  assert.deepEqual(page.form.querySelectorAll('div.q input[type="text"]').length, 4);
  for (const question of quiz.questions) {
    if (question.kind === "choice") assert.equal(page.legend(question.id), question.label);
    else assert.equal(page.label(question.id), question.label);
  }
  assert.equal(page.label("now").length > 0, true);
  assert.equal(page.radio("who", "friend").checked, true);
  assert.notEqual(page.radio("who", "self").checked, true);
  for (const name of ["expert", "push", "length"]) {
    for (const option of quiz.questions.find((question) => question.id === name).options) {
      assert.notEqual(page.radio(name, option.value).checked, true, `${name}/${option.value} starts unchecked`);
    }
  }
  assert.equal(page.document.querySelector(".reset").hidden, false);
  assert.equal(page.$("prompt").hidden, true);
  assert.equal(page.$("quiz-status").textContent, "", "the loading line is cleared");
  assert.deepEqual(page.calls.focus, [], "the first load never moves focus");
  assert.equal(page.$("make").textContent, "Make my prompt");
  assert.equal(page.form.querySelectorAll("button.fill").length, 4);
});

test("a text question points at its hint and has no placeholder or length limit", async () => {
  const page = await loaded();
  const input = page.$("q-dinner");
  assert.equal(input.getAttribute("aria-describedby"), "q-dinner-hint");
  assert.equal(page.$("q-dinner-hint").textContent, quiz.questions.find((question) => question.id === "dinner").hint);
  assert.equal(input.getAttribute("placeholder"), null);
  assert.equal(input.getAttribute("maxlength"), null);
  assert.equal(page.form.querySelector('div[data-q="dinner"] label').getAttribute("for"), "q-dinner");
});

test("switching to Me relabels in place, keeps typed text and drops the friend-only option", async () => {
  const page = await loaded();
  const expertRow = page.row("expert", "me");
  const radioBefore = page.radio("who", "self");
  page.type("now", "Podcasts about cities");
  page.choose("expert", "me");
  page.choose("who", "self");
  const now = quiz.questions.find((question) => question.id === "now");
  assert.equal(page.label("now"), now.labelSelf);
  assert.equal(page.$("q-now").value, "Podcasts about cities", "typed text stays");
  assert.equal(page.$("q-now-hint").textContent, now.hint, "no self hint, so the friend hint");
  assert.equal(page.$("q-dinner-hint").textContent, quiz.questions.find((question) => question.id === "dinner").hintSelf);
  assert.equal(expertRow.hidden, true, "the friend-only row is hidden");
  assert.equal(page.radio("expert", "me").checked, false, "and unchecked");
  assert.equal(page.radio("who", "self"), radioBefore, "the radio was relabelled, never rebuilt");
  assert.equal(page.row("expert", "them").querySelector("span").textContent, "Me: I know this subject");
  page.make();
  assert.equal(page.prompt(), renderPrompt(quiz, { who: "self", now: "Podcasts about cities" }));
  assert.ok(!page.prompt().includes("the one sending it"));
  page.choose("who", "friend");
  assert.equal(page.row("expert", "me").hidden, false, "shown again in its place");
  assert.equal(page.legend("length"), quiz.questions.find((question) => question.id === "length").label);
});

test("a fill sets the situation and leaves focus alone", async () => {
  const page = await loaded();
  page.type("situation", "typed first");
  page.form.querySelectorAll("button.fill")[2].click();
  assert.equal(page.$("q-situation").value, "On a walk", "a fill replaces what was typed");
  assert.deepEqual(page.calls.focus, []);
  page.make();
  assert.ok(page.prompt().includes("- Where and how they'll listen: On a walk"));
});

test("Make with nothing answered says so, focuses the first question and shows no prompt", async () => {
  const page = await loaded();
  page.make();
  assert.equal(page.$("quiz-message").textContent, "Answer at least one question first.");
  assert.deepEqual(page.calls.focus, [page.$("q-now")]);
  assert.equal(page.$("prompt").hidden, true);
  page.type("now", "   ");
  page.make();
  assert.equal(page.$("prompt").hidden, true, "only spaces is not an answer");
  page.choose("who", "self");
  page.make();
  assert.equal(page.$("prompt").hidden, true, "choosing Me alone is not an answer");
});

test("Make builds the prompt, moves focus to its heading and scrolls to it", async () => {
  const page = await loaded();
  page.make();
  page.type("now", "Cable news");
  page.make();
  assert.equal(page.$("quiz-message").textContent, "");
  assert.equal(page.prompt(), renderPrompt(quiz, { who: "friend", now: "Cable news" }));
  assert.equal(page.$("prompt").hidden, false);
  assert.deepEqual(page.calls.focus.slice(-1), [page.$("prompt-heading")]);
  assert.deepEqual(page.calls.scroll, [page.$("prompt")]);
});

test("a later edit re-renders, and the copy state goes back to the start", async () => {
  const page = await loaded();
  page.type("now", "Cable news");
  page.make();
  await page.copy();
  assert.equal(page.$("copy-status").textContent, "Prompt copied");
  assert.equal(page.$("copy").textContent, "Copied");
  page.type("dinner", "The school board");
  assert.equal(page.prompt(), renderPrompt(quiz, { who: "friend", now: "Cable news", dinner: "The school board" }));
  assert.equal(page.$("copy-status").textContent, "");
  assert.equal(page.$("copy").textContent, "Copy prompt");
  assert.deepEqual(page.calls.cleared, [page.calls.timers[0].id], "the running copy timer was cancelled");
});

test("clearing every answer hides the prompt without a message", async () => {
  const page = await loaded();
  page.type("now", "Cable news");
  page.make();
  page.type("now", "");
  assert.equal(page.$("prompt").hidden, true);
  assert.equal(page.$("quiz-message").textContent, "");
  page.type("now", "back again");
  assert.equal(page.$("prompt").hidden, true, "typing alone does not bring the prompt back; Make does");
  page.make();
  assert.equal(page.$("prompt").hidden, false);
});

test("an answer clears the Answer-at-least-one message", async () => {
  const page = await loaded();
  page.make();
  page.type("now", "Cable news");
  assert.equal(page.$("quiz-message").textContent, "");
});

test("Copy that works says so for two seconds, then the button is back and the status stays", async () => {
  const page = await loaded();
  page.type("now", "Cable news");
  page.make();
  await page.copy();
  assert.deepEqual(page.calls.writes, [page.prompt()]);
  assert.equal(page.$("copy").textContent, "Copied");
  assert.equal(page.$("copy-status").textContent, "Prompt copied");
  assert.equal(page.calls.timers.length, 1);
  assert.equal(page.calls.timers[0].ms, 2000);
  page.calls.timers[0].fn();
  assert.equal(page.$("copy").textContent, "Copy prompt");
  assert.equal(page.$("copy-status").textContent, "Prompt copied");
});

for (const clipboard of ["reject", "none"]) {
  test(`Copy with ${clipboard === "none" ? "no clipboard" : "a refused clipboard"} selects the text and says so`, async () => {
    const page = await loaded({ clipboard });
    page.type("now", "Cable news");
    page.make();
    await page.copy();
    assert.deepEqual(page.calls.selectAll, [page.$("prompt-text")]);
    assert.equal(page.$("copy").textContent, "Copy prompt");
    assert.equal(
      page.$("copy-status").textContent,
      "Couldn't copy automatically. The prompt is selected, so copy it from your keyboard or the menu.",
    );
    assert.equal(page.calls.timers.length, 0);
  });
}

test("an edit while a copy is pending means the copy never claims success", async () => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const page = await loaded({ clipboard: () => gate });
  page.type("now", "Cable news");
  page.make();
  page.$("copy").click();
  await flush();
  page.type("dinner", "The school board");
  release();
  await flush();
  assert.equal(page.$("copy-status").textContent, "");
  assert.equal(page.$("copy").textContent, "Copy prompt");
  assert.equal(page.calls.timers.length, 0);
});

test("Start over empties the answers, hides the prompt and focuses A friend", async () => {
  const page = await loaded();
  page.choose("who", "self");
  page.type("now", "Cable news");
  page.make();
  await page.copy();
  page.$("start-over").click();
  assert.equal(page.$("prompt").hidden, true);
  assert.equal(page.$("quiz-message").textContent, "");
  assert.equal(page.$("copy-status").textContent, "");
  assert.equal(page.$("copy").textContent, "Copy prompt");
  assert.equal(page.$("q-now").value ?? "", "");
  assert.equal(page.radio("who", "friend").checked, true);
  assert.equal(page.legend("who"), quiz.questions[0].label);
  assert.equal(page.label("now"), quiz.questions.find((question) => question.id === "now").label);
  assert.deepEqual(page.calls.focus.slice(-1), [page.radio("who", "friend")]);
  page.make();
  assert.equal(page.$("quiz-message").textContent, "Answer at least one question first.", "the answers are gone");
});

for (const [name, fetchResult] of [
  ["a network error", () => { throw new Error("offline"); }],
  ["a non-200 answer", () => ({ ok: false, json: async () => quiz })],
  ["a body that is not JSON", () => ({ ok: true, json: async () => { throw new SyntaxError("bad json"); } })],
  ["data the page can't draw", () => ({ ok: true, json: async () => ({}) })],
]) {
  test(`${name} shows the load-failed state with a Try again button`, async () => {
    const page = build({ fetchResult });
    await page.load();
    assert.ok(page.$("quiz-status").textContent.startsWith(LOAD_FAILED));
    assert.ok(page.$("retry"), "there is a Try again button");
    assert.equal(page.$("retry").textContent, "Try again");
    assert.equal(page.form.children.length, 0, "no part-drawn form");
    assert.equal(page.document.querySelector(".reset").hidden, true);
    assert.equal(page.$("prompt").hidden, true);
  });
}

test("Try again draws the form and focuses A friend; a second failure focuses the new button", async () => {
  let online = false;
  const page = build({ fetchResult: () => { if (!online) throw new Error("offline"); return { ok: true, json: async () => quiz }; } });
  await page.load();
  const firstRetry = page.$("retry");
  firstRetry.click();
  await flush();
  assert.ok(page.$("retry") && page.$("retry") !== firstRetry);
  assert.deepEqual(page.calls.focus.slice(-1), [page.$("retry")]);
  online = true;
  page.$("retry").click();
  await flush();
  assert.equal(page.form.querySelectorAll("fieldset").length, 4);
  assert.equal(page.$("quiz-status").textContent, "");
  assert.deepEqual(page.calls.focus.slice(-1), [page.radio("who", "friend")]);
  assert.equal(page.document.querySelector(".reset").hidden, false);
});

test("after a retry the buttons are wired once, not twice", async () => {
  let online = false;
  const page = build({ fetchResult: () => { if (!online) throw new Error("offline"); return { ok: true, json: async () => quiz }; } });
  await page.load();
  online = true;
  page.$("retry").click();
  await flush();
  page.type("now", "Cable news");
  page.make();
  assert.deepEqual(page.calls.scroll.length, 1, "one submit handler");
  await page.copy();
  assert.equal(page.calls.writes.length, 1, "one copy handler");
  assert.equal(page.calls.timers.length, 1);
  page.$("start-over").click();
  assert.equal(page.calls.focus.filter((el) => el === page.radio("who", "friend")).length, 1, "one Start over handler");
});

test("network: once drawn, Make and Copy need no request", async () => {
  const page = build();
  await page.load();
  assert.equal(page.calls.fetches, 1);
  page.env.fetch = async () => { throw new Error("no request after the first"); };
  page.type("now", "Cable news");
  page.make();
  await page.copy();
  assert.equal(page.calls.writes.length, 1);
  assert.equal(page.calls.fetches, 1);
});

test("burst: two Makes give one prompt; two Copies write twice and replace the timer", async () => {
  const page = await loaded();
  page.type("now", "Cable news");
  page.make();
  const first = page.prompt();
  page.make();
  assert.equal(page.prompt(), first);
  assert.equal(page.document.querySelectorAll("#prompt").length, 1);
  assert.equal(page.$("prompt").hidden, false);
  await page.copy();
  await page.copy();
  assert.equal(page.calls.writes.length, 2);
  assert.equal(page.calls.timers.length, 2);
  assert.deepEqual(page.calls.timers.map((timer) => timer.ms), [2000, 2000]);
  assert.deepEqual(page.calls.cleared, [page.calls.timers[0].id], "the first timer was cleared");
});

test("long source: a very long answer is kept whole", async () => {
  const page = await loaded();
  page.type("dinner", "abcdefghij".repeat(200));
  page.make();
  assert.ok(page.prompt().includes("abcdefghij".repeat(200)));
});

test("mountQuiz can be called again: empty answers, and the buttons are still wired once", async () => {
  const page = await loaded();
  page.type("now", "Cable news");
  page.make();
  mountQuiz(page.document, quiz, page.env);
  assert.equal(page.$("prompt").hidden, true);
  page.make();
  assert.equal(page.$("quiz-message").textContent, "Answer at least one question first.");
  assert.equal(page.calls.scroll.length, 1, "no Make after the second mount reached the scroll");
  page.type("now", "Cable news");
  page.make();
  assert.equal(page.calls.scroll.length, 2, "one submit handler");
  await page.copy();
  assert.equal(page.calls.writes.length, 1, "one copy handler");
  page.$("start-over").click();
  assert.equal(page.calls.focus.filter((el) => el === page.radio("who", "friend")).length, 1, "one Start over handler");
});

test("a draw that throws leaves the page wired, so the retry that follows works", async () => {
  const broken = { ...quiz, questions: [...quiz.questions, { id: "oops", kind: "choice" }] };
  let data = broken;
  const page = build({ fetchResult: () => ({ ok: true, json: async () => data }) });
  await page.load();
  assert.ok(page.$("retry"), "the broken data shows the load-failed state");
  data = quiz;
  page.$("retry").click();
  await flush();
  page.type("now", "Cable news");
  page.make();
  assert.equal(page.calls.scroll.length, 1, "Make works after a draw that threw");
  await page.copy();
  assert.equal(page.calls.writes.length, 1);
});
