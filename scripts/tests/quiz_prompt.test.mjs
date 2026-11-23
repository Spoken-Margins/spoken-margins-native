// The prompt builder for "Find an episode to talk about" (#4707): Site/quiz/quiz.js against the hand-written
// fixtures in Contracts/fixtures/find-something/, and the cross-field rules the JSON schema can't state.
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  audience, cleanText, hintFor, labelFor, optionLabel, optionsFor, renderPrompt,
} from "../../Site/quiz/quiz.js";

const quiz = JSON.parse(readFileSync(new URL("../../Contracts/quiz/find-something.v1.json", import.meta.url), "utf8"));
const fixtureFolder = new URL("../../Contracts/fixtures/find-something/", import.meta.url);
const fixtures = readdirSync(fileURLToPath(fixtureFolder)).filter((name) => name.endsWith(".json")).sort();

test("there is a fixture for every case the rule names", () => {
  assert.ok(fixtures.length >= 8, `only ${fixtures.length} fixtures`);
});

for (const name of fixtures) {
  test(`${name} renders to its expected text`, () => {
    const fixture = JSON.parse(readFileSync(new URL(name, fixtureFolder), "utf8"));
    assert.strictEqual(renderPrompt(quiz, fixture.answers), fixture.expected);
  });
}

test("the rule's cross-field rules hold in the data", () => {
  const [first, ...rest] = quiz.questions;
  assert.equal(first.id, "who");
  assert.deepEqual(first.options.map((option) => option.value), ["friend", "self"]);
  assert.equal(first.default, "friend");
  assert.equal(first.promptLine, undefined);
  const ids = new Set(["who"]);
  for (const question of rest) {
    assert.ok(!ids.has(question.id), `duplicate id ${question.id}`);
    ids.add(question.id);
    for (const key of ["promptLine", "promptLineSelf"]) {
      assert.equal(question[key].split("{answer}").length - 1, 1, `${question.id}.${key} needs {answer} once`);
    }
    if (question.kind !== "choice") continue;
    for (const option of question.options) {
      assert.ok(option.prompt, `${question.id}/${option.value} has no prompt`);
      if (option.only !== "friend") assert.ok(option.promptSelf, `${question.id}/${option.value} has no promptSelf`);
    }
  }
});

test("optionsFor drops friend-only options for self and keeps them for a friend", () => {
  const expert = quiz.questions.find((question) => question.id === "expert");
  assert.deepEqual(optionsFor(expert, "friend").map((option) => option.value), ["them", "host", "me"]);
  assert.deepEqual(optionsFor(expert, "self").map((option) => option.value), ["them", "host"]);
});

test("visible text falls back to the friend wording; prompt text never does", () => {
  const dinner = quiz.questions.find((question) => question.id === "dinner");
  const now = quiz.questions.find((question) => question.id === "now");
  const host = quiz.questions.find((question) => question.id === "expert").options[1];
  const them = quiz.questions.find((question) => question.id === "expert").options[0];
  assert.equal(labelFor(now, "self"), now.labelSelf);
  assert.equal(hintFor(now, "self"), now.hint, "no hintSelf, so the friend hint");
  assert.equal(hintFor(dinner, "self"), dinner.hintSelf);
  assert.equal(optionLabel(host, "self"), host.label, "no labelSelf, so the friend label");
  assert.equal(optionLabel(them, "self"), them.labelSelf);
  assert.equal(hintFor({ label: "x" }, "friend"), "", "a question with no hint has an empty one");
  // A self prompt never takes an option's friend text: an option without promptSelf adds no line.
  const lone = { questions: [{ id: "a", kind: "choice", options: [{ value: "v", label: "V", prompt: "friend text" }],
    promptLine: "A: {answer}", promptLineSelf: "A: {answer}" }],
    prompt: { friend: { opening: "o", aboutHeader: "h", closing: "c" }, self: { opening: "O", aboutHeader: "H", closing: "C" } } };
  assert.equal(renderPrompt(lone, { who: "self", a: "v" }), "O\n\nC");
  assert.equal(renderPrompt(lone, { who: "friend", a: "v" }), "o\n\nh\n- A: friend text\n\nc");
});

test("audience is friend unless the listener chose self", () => {
  assert.equal(audience({}), "friend");
  assert.equal(audience({ who: "self" }), "self");
  assert.equal(audience({ who: "SELF" }), "friend");
  assert.equal(audience(undefined), "friend");
});

test("cleanText collapses the listed whitespace and nothing else", () => {
  const nel = String.fromCharCode(0x85);
  const spaces = [0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0xa0, 0x1680, 0x2000, 0x200a, 0x2028, 0x2029, 0x202f, 0x205f,
    0x3000, 0xfeff].map((code) => String.fromCharCode(code));
  assert.equal(cleanText(spaces.join("")), "");
  assert.equal(cleanText(`a${spaces.join("")}b`), "a b");
  assert.equal(cleanText(` a${nel}b `), `a${nel}b`, "U+0085 is not in the list and stays");
  assert.equal(cleanText("  {answer} $& $1  "), "{answer} $& $1");
});

test("an answer that is not text, or an option not offered, adds no line", () => {
  const empty = renderPrompt(quiz, { who: "friend" });
  assert.equal(renderPrompt(quiz, { who: "friend", now: ["x"], length: 45, push: "nope", extra: "x" }), empty);
  assert.equal(renderPrompt(quiz, { who: "self", expert: "me" }), renderPrompt(quiz, { who: "self" }));
  assert.equal(renderPrompt(quiz, { who: "friend", now: "   " }), empty);
});
