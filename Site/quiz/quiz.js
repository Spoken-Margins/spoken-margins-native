// The prompt builder for "Find an episode to talk about" (#4707). No DOM access: Node's tests and the page import it.
// The rule it follows is in Contracts/fixtures/find-something/: every fixture there pins one case of it, and the
// app port (#4709) must give the same text.

// JavaScript's \s, spelled out as code points so a Swift port can match it:
// U+0009 to U+000D, U+0020, U+00A0, U+1680, U+2000 to U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF.
// U+0085 is not in the list and stays.
const WHITESPACE_RANGES = [
  [0x09, 0x0d], [0x20, 0x20], [0xa0, 0xa0], [0x1680, 0x1680], [0x2000, 0x200a],
  [0x2028, 0x2029], [0x202f, 0x202f], [0x205f, 0x205f], [0x3000, 0x3000], [0xfeff, 0xfeff],
];
const WHITESPACE = new RegExp(
  "[" + WHITESPACE_RANGES.map(([from, to]) => String.fromCharCode(from) + "-" + String.fromCharCode(to)).join("") + "]+",
  "g",
);

/** "friend" unless the listener chose "self"; a missing answer means "friend". */
export function audience(answers) {
  return answers && answers.who === "self" ? "self" : "friend";
}

/** The question's label for this audience; the friend wording when there is no self wording. */
export function labelFor(question, who) {
  return who === "self" && question.labelSelf ? question.labelSelf : question.label;
}

/** The question's hint for this audience; the friend hint when there is no self hint, "" when there is none. */
export function hintFor(question, who) {
  const hint = who === "self" && question.hintSelf ? question.hintSelf : question.hint;
  return hint || "";
}

/** An option's visible text for this audience. */
export function optionLabel(option, who) {
  return who === "self" && option.labelSelf ? option.labelSelf : option.label;
}

/** The options of a choice question that are offered to this audience. */
export function optionsFor(question, who) {
  return (question.options || []).filter((option) => !option.only || option.only === who);
}

/** Collapse each run of whitespace to one space and trim both ends. Nothing else changes. */
export function cleanText(text) {
  return text.replace(WHITESPACE, " ").replace(/^ | $/g, "");
}

function answerText(question, answer, who) {
  if (question.kind === "text") {
    return typeof answer === "string" ? cleanText(answer) : "";
  }
  if (typeof answer !== "string") return "";
  const option = optionsFor(question, who).find((candidate) => candidate.value === answer);
  if (!option) return "";
  return (who === "self" ? option.promptSelf : option.prompt) || "";
}

/** The "- ..." lines a prompt would hold for these answers. A prompt with no line is not worth making. */
export function answerLines(quiz, answers) {
  const who = audience(answers);
  const lines = [];
  for (const question of quiz.questions) {
    if (question.id === "who") continue;
    const text = answerText(question, answers ? answers[question.id] : undefined, who);
    if (text === "") continue;
    const template = who === "self" ? question.promptLineSelf : question.promptLine;
    // Split and join, never a replacement string, so "$&" and "{answer}" in an answer stay as typed.
    lines.push("- " + template.split("{answer}").join(text));
  }
  return lines;
}

/** The prompt for these answers. */
export function renderPrompt(quiz, answers) {
  const part = quiz.prompt[audience(answers)];
  const lines = answerLines(quiz, answers);
  if (lines.length === 0) return part.opening + "\n\n" + part.closing;
  return part.opening + "\n\n" + part.aboutHeader + "\n" + lines.join("\n") + "\n\n" + part.closing;
}
