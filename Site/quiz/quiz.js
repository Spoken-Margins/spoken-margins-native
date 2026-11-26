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

// ---- The paste-back check (#5270, the site half of #4708) ----
// parsePaste and titlesMatch port EpisodeLinkPaste (Packages/SessionKit/Sources/SessionKit/EpisodeLinkPaste.swift)
// line for line. The shared table in Contracts/fixtures/find-something/ (paste-*.json, title-match.json) runs on both
// sides, so a change to one that the other doesn't share fails a test.

// Swift's CharacterSet.newlines and CharacterSet.whitespaces (Unicode Zs plus tab).
const NEWLINES = /[\n\r\u000b\u000c\u0085\u2028\u2029]/;
const EDGE_SPACES = /^[\t\p{Zs}]+|[\t\p{Zs}]+$/gu;
const LINK = /https?:\/\/[^\s<>"'`]+/;
const FIELD_EDGES = /^[\t\p{Zs}"\u201c\u201d*_:]+|[\t\p{Zs}"\u201c\u201d*_:]+$/gu;
const TITLE_EDGES = /^[\t\p{Zs}"\u201c\u201d]+|[\t\p{Zs}"\u201c\u201d]+$/gu;
const SEPARATORS = [" — ", " – ", " - ", ": "];

function trimSpaces(text) {
  return text.replace(EDGE_SPACES, "");
}

function parsedURL(text) {
  try {
    return new URL(text);
  } catch {
    return null;
  }
}

/** What a link points at, from the address alone: the raw values of EpisodeLinkPaste.LinkKind. */
export function linkKind(urlString) {
  const url = parsedURL(urlString);
  const host = url && url.hostname ? url.hostname.toLowerCase() : "";
  if (!host) return "other";
  const on = (domain) => host === domain || host.endsWith("." + domain);
  if (on("podcasts.apple.com") || on("itunes.apple.com")) {
    return url.searchParams.get("i") ? "apple_episode" : "apple_show";
  }
  if (on("spotify.com") || on("spotify.link")) return "spotify";
  if (on("youtube.com") || on("youtu.be")) return "youtube";
  if (on("substack.com")) return "substack";
  return "other";
}

/** The Apple episode id (the `i` parameter) of an Apple episode link, or null. */
export function appleEpisodeId(urlString) {
  if (linkKind(urlString) !== "apple_episode") return null;
  const id = parsedURL(urlString).searchParams.get("i");
  return /^\d{1,19}$/.test(id) ? id : null;
}

/** An Apple episode link whose `i` is not an episode id: it can't open an episode. */
export function hasBadEpisodeId(urlString) {
  return linkKind(urlString) === "apple_episode" && appleEpisodeId(urlString) === null;
}

/** The Apple show id (the "id123" path part) of an Apple link, or null. */
export function appleShowId(urlString) {
  const url = parsedURL(urlString);
  if (!url || !["apple_episode", "apple_show"].includes(linkKind(urlString))) return null;
  const match = /\/id(\d{1,19})(?:\/|$)/.exec(url.pathname);
  return match ? match[1] : null;
}

function cleanedURL(raw) {
  let url = raw;
  // Trailing markdown or sentence punctuation is never part of a podcast address.
  while (url.length > 0 && ")]}>.,;:!?*_".includes(url[url.length - 1])) {
    if (url[url.length - 1] === ")" && url.split("(").length >= url.split(")").length) break;
    url = url.slice(0, -1);
  }
  return url;
}

function cleanedField(raw) {
  return raw
    .replace(/^\s*(?:[-*•]|\d+[.)])\s+/u, "")
    .split("**").join("")
    .split("__").join("")
    .replace(/[[\]`]/g, "")
    .replace(FIELD_EDGES, "");
}

function showAndTitle(field) {
  if (field === "") return [null, null];
  for (const separator of SEPARATORS) {
    const at = field.indexOf(separator);
    if (at === -1) continue;
    const show = trimSpaces(field.slice(0, at));
    const title = field.slice(at + separator.length).replace(TITLE_EDGES, "");
    return [show || null, title || null];
  }
  return [null, field];
}

/** One suggestion line read as EpisodeLinkPaste.entry(fromLine:), or null when it holds no http(s) link. */
export function parseLine(rawLine) {
  const line = trimSpaces(rawLine);
  const match = LINK.exec(line);
  if (!match) return null;
  const url = cleanedURL(match[0]);
  const parsed = parsedURL(url);
  if (!parsed || !parsed.hostname) return null;
  let before = line.slice(0, match.index);
  const markedShowLink = /\(show link\)/i.test(before);
  before = before.replace(/\(show link\)/gi, "");
  // A markdown link "[label](url)" leaves "[label](" before the address.
  before = before.replace(/\[([^\]]*)\]\($/, "$1");
  const [show, title] = showAndTitle(cleanedField(before.split("|")[0]));
  return { url, kind: linkKind(url), claimedShow: show, claimedTitle: title, markedShowLink, line };
}

/**
 * The suggestion lines in a pasted answer, first link per line. When any linked line uses the requested
 * "fields | link" form, only those lines count, so a Sources list after the picks is not read as more picks.
 */
export function parsePaste(text) {
  const all = String(text).split(NEWLINES).map(parseLine).filter(Boolean);
  const formed = all.filter((entry) => {
    const at = entry.line.indexOf(entry.url);
    return at !== -1 && entry.line.slice(0, at).includes("|");
  });
  return formed.length > 0 ? formed : all;
}

const IGNORED_WORDS = new Set(["the", "a", "an", "and", "of", "ep", "episode", "part", "pt"]);

// Foundation's folding(.caseInsensitive, .diacriticInsensitive, .widthInsensitive), as SessionKit's tests see it:
// accents from the combining-diacritics blocks go, other marks (Devanagari vowel signs) stay, ß becomes ss, a final
// sigma becomes σ, and Hangul stays composed. title-match.json pins each of these on both sides.
const COMBINING_DIACRITICS = /[\u0300-\u036f\u1ab0-\u1aff\u1dc0-\u1dff\u20d0-\u20ff\ufe20-\ufe2f]/g;

function folded(text) {
  return String(text)
    .normalize("NFKD")
    .replace(COMBINING_DIACRITICS, "")
    .normalize("NFC")
    .toLowerCase()
    .replace(/ß/g, "ss")
    .replace(/ς/g, "σ");
}

// Swift's Character count: extended grapheme clusters.
function characterCount(word) {
  if (typeof Intl !== "undefined" && typeof Intl.Segmenter === "function") {
    return [...new Intl.Segmenter("en", { granularity: "grapheme" }).segment(word)].length;
  }
  return [...word].length;
}

function normalizedTokens(text) {
  return folded(text)
    .replace(/&/g, " and ")
    .replace(/[\u2018\u2019']/g, "")
    .split(/[^\p{L}\p{M}\p{N}]+/u)
    .filter((word) => word !== "" && !IGNORED_WORDS.has(word));
}

/**
 * Whether two episode titles name the same episode: one contains the other, or most of the shorter title's words
 * are in the longer one. Case, accents, curly quotes, "&" and punctuation don't count.
 */
export function titlesMatch(lhs, rhs) {
  const a = normalizedTokens(lhs);
  const b = normalizedTokens(rhs);
  if (a.length === 0 || b.length === 0) return false;
  const joinedA = a.join(" ");
  const joinedB = b.join(" ");
  const shorter = a.length <= b.length ? a : b;
  const longer = a.length <= b.length ? b : a;
  if (shorter.length >= 2 || characterCount(shorter[0]) >= 6) {
    if (joinedA === joinedB || joinedB.includes(joinedA) || joinedA.includes(joinedB)) return true;
  } else if (joinedA === joinedB) {
    return true;
  }
  const longerWords = new Set(longer);
  const shared = new Set(shorter.filter((word) => longerWords.has(word))).size;
  return shorter.length >= 2 && shared / shorter.length >= 0.7;
}

/** The follow-up prompt for the lines whose links failed, each as the assistant wrote it. */
export function renderFollowUp(quiz, failedLines) {
  return quiz.followUp.opening + "\n\n" + failedLines.join("\n") + "\n\n" + quiz.followUp.closing;
}

// Apple's lookup answers at most this many of a show's newest episodes.
export const LOOKUP_LIMIT = 200;

/**
 * Apple's public lookup of a show's newest episodes. It answers any origin and needs no cookies. Asked for an
 * episode's own id it answers nothing (seen 2026-11-24), so the check asks for the show and finds the episode in it,
 * the same address the app's share-link check reads (ShareLinkPlayCheckReads.swift).
 */
export function lookupURL(showId) {
  return "https://itunes.apple.com/lookup?id=" + encodeURIComponent(showId) + "&entity=podcastEpisode&limit=" + LOOKUP_LIMIT;
}

/**
 * What Apple's lookup answer for the link's show means for this entry: "right", "wrong" (plays, another title),
 * "unchecked" (plays, no title named), "failed" (no such show, or a show with fewer than LOOKUP_LIMIT episodes that
 * doesn't hold this one) or "older" (the show has more episodes than the lookup lists, and this one isn't among the
 * newest, so the page can't tell). `body` is the lookup's parsed JSON.
 */
export function judgeLookup(entry, episodeId, body) {
  const results = body && Array.isArray(body.results) ? body.results : [];
  const episodes = results.filter((result) => result && result.kind === "podcast-episode");
  const episode = episodes.find((result) => String(result.trackId) === episodeId);
  if (!episode) {
    return { verdict: episodes.length >= LOOKUP_LIMIT ? "older" : "failed" };
  }
  if (typeof episode.trackName !== "string" || episode.trackName.trim() === "") return { verdict: "failed" };
  const resolvedTitle = episode.trackName;
  const show = typeof episode.collectionName === "string" ? episode.collectionName : null;
  if (!entry.claimedTitle || normalizedTokens(entry.claimedTitle).length === 0) {
    return { verdict: "unchecked", resolvedTitle, show };
  }
  return { verdict: titlesMatch(entry.claimedTitle, resolvedTitle) ? "right" : "wrong", resolvedTitle, show };
}
