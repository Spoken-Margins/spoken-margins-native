// The page for "Find an episode to talk about" (#4707): draws the questions from the quiz data, builds the prompt in
// the browser and offers a Copy button. Nothing is stored. The answers live in a plain object in this module, and the
// only requests are the questions file and, after the sender taps "Check links" (#5270), one Apple lookup per show
// named by an Apple episode link, carrying only the show's id.
//
// `document` and `env` are passed in, so a test can drive the page with a fake DOM and fake clocks. The last lines
// of the file are the only code that touches the real browser.
import {
  answerLines, appleEpisodeId, appleShowId, audience, hasBadEpisodeId, hintFor, judgeLookup, labelFor, lookupURL, optionLabel, optionsFor, parsePaste,
  renderFollowUp, renderPrompt,
} from "./quiz.js";

const LOADING = "Loading the questions…";
const LOAD_FAILED = "The questions didn't load. Check your connection, then try again.";
const NOTHING_ANSWERED = "Answer at least one question first.";
const COPY_FAILED =
  "Couldn't copy automatically. The prompt is selected, so copy it from your keyboard or the menu.";
const FOLLOW_UP_COPY_FAILED =
  "Couldn't copy automatically. The follow-up prompt is selected, so copy it from your keyboard or the menu.";

// The check block's words (#4674's Design, 2b and 2d). Status is an icon plus words, never colour alone.
const CHECK = {
  empty: "Paste your assistant's answer first.",
  noLinks: "No episode links in this answer. Ask your assistant to follow the prompt's line form.",
  offline: "You're offline. Copy the prompt now and check links when you're back online.",
  checking: "Checking…",
};
const ROW = {
  right: { icon: "✓", tone: "works", words: (title) => `Plays: ${title}` },
  wrong: { icon: "⚠", tone: "look", words: (title) => `Plays, but it's called "${title}". Check it's the one you meant.` },
  unchecked: { icon: "?", tone: "look", words: () => "Plays, but there's no title to check. Open it to make sure." },
  show: { icon: "⚠", tone: "look", words: () => "This is a whole show, not an episode." },
  failed: { icon: "✕", tone: "look", words: () => "Couldn't find an episode at this link." },
  error: { icon: "?", tone: "look", words: () => "Couldn't check this one just now." },
  other: { icon: "–", tone: "plain", words: () => "Not checked here. Open it to see." },
  // The show has more episodes than Apple's lookup lists, and this one isn't among the newest.
  older: { icon: "–", tone: "plain", words: () => "Not checked here. Open it to see." },
  checking: { icon: "…", tone: "plain", words: () => CHECK.checking },
};
const LOOKUPS_AT_ONCE = 4;
const LOOKUP_TIMEOUT_MS = 15000;

// One context per form, so a retry draws the form again without wiring the page's buttons a second time.
const contexts = new WeakMap();

function element(document, tag, attributes = {}, text) {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value);
  if (text !== undefined) node.textContent = text;
  return node;
}

function parts(document) {
  return {
    form: document.getElementById("quiz"),
    status: document.getElementById("quiz-status"),
    prompt: document.getElementById("prompt"),
    heading: document.getElementById("prompt-heading"),
    text: document.getElementById("prompt-text"),
    copy: document.getElementById("copy"),
    copyStatus: document.getElementById("copy-status"),
    reset: document.querySelector(".reset"),
    startOver: document.getElementById("start-over"),
    answer: document.getElementById("answer-text"),
    check: document.getElementById("check"),
    checkMessage: document.getElementById("check-message"),
    results: document.getElementById("check-results"),
    noneWorked: document.getElementById("none-worked"),
    followUp: document.getElementById("follow-up"),
    followUpText: document.getElementById("follow-up-text"),
    copyFollowUp: document.getElementById("copy-follow-up"),
    followUpStatus: document.getElementById("follow-up-status"),
  };
}

function cancelCopyTimer(ctx) {
  if (ctx.copyTimer !== null) ctx.env.clearTimeout(ctx.copyTimer);
  ctx.copyTimer = null;
}

// The prompt on screen no longer matches what "Copied" said, so the copy state goes back to the start.
function resetCopyState(ctx) {
  ctx.renderCount += 1;
  cancelCopyTimer(ctx);
  ctx.parts.copy.textContent = "Copy prompt";
  ctx.parts.copyStatus.textContent = "";
}

// Every change to the answers ends here: re-render a prompt that is showing, hide it when nothing is answered.
function answersChanged(ctx) {
  const lines = answerLines(ctx.quiz, ctx.answers);
  const message = ctx.document.getElementById("quiz-message");
  if (lines.length > 0 && message) message.textContent = "";
  if (!ctx.promptShown) return;
  resetCopyState(ctx);
  if (lines.length === 0) {
    ctx.promptShown = false;
    ctx.parts.prompt.hidden = true;
    return;
  }
  ctx.parts.text.value = renderPrompt(ctx.quiz, ctx.answers);
}

// Switching between "A friend" and "Me" changes words in place, so focus stays on the radio just picked.
function applyAudience(ctx) {
  const who = audience(ctx.answers);
  for (const question of ctx.quiz.questions) {
    if (question.kind === "choice") {
      const fieldset = ctx.parts.form.querySelector(`fieldset[data-q="${question.id}"]`);
      fieldset.querySelector("legend").textContent = labelFor(question, who);
      const offered = new Set(optionsFor(question, who).map((option) => option.value));
      for (const option of question.options) {
        const row = fieldset.querySelector(`label[data-value="${option.value}"]`);
        row.querySelector("span").textContent = optionLabel(option, who);
        row.hidden = !offered.has(option.value);
        if (!offered.has(option.value)) {
          row.querySelector("input").checked = false;
          if (ctx.answers[question.id] === option.value) delete ctx.answers[question.id];
        }
      }
    } else {
      const block = ctx.parts.form.querySelector(`div[data-q="${question.id}"]`);
      block.querySelector("label").textContent = labelFor(question, who);
      const hint = block.querySelector(".hint");
      if (hint) hint.textContent = hintFor(question, who);
    }
  }
}

function drawChoice(ctx, question, who) {
  const { document } = ctx;
  const fieldset = element(document, "fieldset", { "data-q": question.id });
  fieldset.appendChild(element(document, "legend", {}, labelFor(question, who)));
  const offered = new Set(optionsFor(question, who).map((option) => option.value));
  for (const option of question.options) {
    const row = element(document, "label", { class: "choice", "data-value": option.value });
    const radio = element(document, "input", { type: "radio", name: question.id, value: option.value });
    radio.checked = question.default === option.value;
    radio.addEventListener("change", () => {
      ctx.answers[question.id] = option.value;
      if (question.id === "who") applyAudience(ctx);
      answersChanged(ctx);
    });
    row.appendChild(radio);
    row.appendChild(element(document, "span", {}, optionLabel(option, who)));
    row.hidden = !offered.has(option.value);
    fieldset.appendChild(row);
  }
  return fieldset;
}

function drawText(ctx, question, who) {
  const { document } = ctx;
  const block = element(document, "div", { class: "q", "data-q": question.id });
  const label = element(document, "label", {}, labelFor(question, who));
  label.setAttribute("for", `q-${question.id}`);
  block.appendChild(label);
  const hint = hintFor(question, who);
  if (hint) block.appendChild(element(document, "p", { class: "hint", id: `q-${question.id}-hint` }, hint));
  const input = element(document, "input", {
    type: "text",
    id: `q-${question.id}`,
    autocomplete: "off",
  });
  if (hint) input.setAttribute("aria-describedby", `q-${question.id}-hint`);
  input.addEventListener("input", () => {
    ctx.answers[question.id] = input.value;
    answersChanged(ctx);
  });
  block.appendChild(input);
  if (Array.isArray(question.fills) && question.fills.length > 0) {
    const fills = element(document, "div", { class: "fills" });
    for (const fill of question.fills) {
      const button = element(document, "button", { type: "button", class: "fill" }, fill);
      // Focus stays on the button: focusing the input would open the keyboard right after a tap meant to avoid typing.
      button.addEventListener("click", () => {
        ctx.answers[question.id] = fill;
        input.value = fill;
        answersChanged(ctx);
      });
      fills.appendChild(button);
    }
    block.appendChild(fills);
  }
  return block;
}

// Draw every question, the Make button and its message into the form, from the answers as they stand now.
function drawForm(ctx) {
  const { document, parts: page } = ctx;
  const who = audience(ctx.answers);
  page.form.replaceChildren();
  for (const question of ctx.quiz.questions) {
    page.form.appendChild(question.kind === "choice" ? drawChoice(ctx, question, who) : drawText(ctx, question, who));
  }
  page.form.appendChild(element(document, "button", { type: "submit", id: "make" }, "Make my prompt"));
  page.form.appendChild(element(document, "p", { id: "quiz-message", role: "alert" }));
}

function makePrompt(ctx) {
  const { parts: page } = ctx;
  const message = ctx.document.getElementById("quiz-message");
  if (answerLines(ctx.quiz, ctx.answers).length === 0) {
    message.textContent = NOTHING_ANSWERED;
    ctx.env.focus(ctx.document.getElementById("q-now"));
    return;
  }
  message.textContent = "";
  ctx.promptShown = true;
  resetCopyState(ctx);
  page.text.value = renderPrompt(ctx.quiz, ctx.answers);
  page.prompt.hidden = false;
  ctx.env.focus(page.heading);
  ctx.env.scrollIntoView(page.prompt);
}

async function copyPrompt(ctx) {
  const { parts: page, env } = ctx;
  const copiedRender = ctx.renderCount;
  try {
    if (!env.clipboard || typeof env.clipboard.writeText !== "function") throw new Error("no clipboard");
    await env.clipboard.writeText(page.text.value);
  } catch {
    cancelCopyTimer(ctx);
    page.copy.textContent = "Copy prompt";
    env.selectAll(page.text);
    page.copyStatus.textContent = COPY_FAILED;
    return;
  }
  // The answers changed while the copy was pending: "Prompt copied" would describe text that is gone.
  if (copiedRender !== ctx.renderCount) return;
  cancelCopyTimer(ctx);
  page.copy.textContent = "Copied";
  page.copyStatus.textContent = "Prompt copied";
  ctx.copyTimer = env.setTimeout(() => {
    ctx.copyTimer = null;
    page.copy.textContent = "Copy prompt";
  }, 2000);
}

function startOver(ctx) {
  const { parts: page } = ctx;
  ctx.answers = { who: "friend" };
  ctx.promptShown = false;
  resetCopyState(ctx);
  drawForm(ctx);
  page.prompt.hidden = true;
  clearCheck(ctx);
  page.answer.value = "";
  ctx.env.focus(page.form.querySelector('input[name="who"][value="friend"]'));
}

// ---- The check block (#5270) ----

function cancelFollowUpTimer(ctx) {
  if (ctx.followUpTimer !== null) ctx.env.clearTimeout(ctx.followUpTimer);
  ctx.followUpTimer = null;
}

// Forget any check on screen; a check still running finds its generation gone and draws nothing more.
function clearCheck(ctx) {
  const { parts: page } = ctx;
  ctx.checkGeneration += 1;
  cancelFollowUpTimer(ctx);
  page.checkMessage.textContent = "";
  page.results.replaceChildren();
  page.results.hidden = true;
  page.noneWorked.hidden = true;
  page.followUp.hidden = true;
  page.followUpText.value = "";
  page.copyFollowUp.textContent = "Copy follow-up prompt";
  page.followUpStatus.textContent = "";
}

function namedAs(entry) {
  if (entry.claimedShow && entry.claimedTitle) return `${entry.claimedShow} — ${entry.claimedTitle}`;
  return entry.claimedTitle || entry.claimedShow || entry.url;
}

function drawRow(ctx, row, state, title) {
  const { document } = ctx;
  const look = ROW[state];
  row.dataset.state = state;
  row.className = `check-row ${look.tone}`;
  const status = row.querySelector(".check-status");
  const icon = element(document, "span", { class: "check-icon", "aria-hidden": "true" }, look.icon);
  status.replaceChildren(icon, document.createTextNode(" " + look.words(title)));
}

function newRow(ctx, entry) {
  const { document } = ctx;
  const row = element(document, "li", { class: "check-row" });
  row.appendChild(element(document, "p", { class: "check-name" }, namedAs(entry)));
  // The pasted link, as a plain link: it opens in a new tab and sends no referrer.
  const link = element(document, "a", { href: entry.url, target: "_blank", rel: "noopener noreferrer", referrerpolicy: "no-referrer" },
    entry.url);
  row.appendChild(element(document, "p", { class: "check-link" }));
  row.lastChild.appendChild(link);
  row.appendChild(element(document, "p", { class: "check-status" }));
  return row;
}

async function lookUp(ctx, showId) {
  const { env } = ctx;
  let timer = null;
  const timeout = new Promise((_, reject) => {
    timer = env.setTimeout(() => reject(new Error("timed out")), LOOKUP_TIMEOUT_MS);
  });
  try {
    const response = await Promise.race([env.lookup(lookupURL(showId)), timeout]);
    if (!response.ok) throw new Error("lookup failed");
    return await Promise.race([response.json(), timeout]);
  } finally {
    env.clearTimeout(timer);
  }
}

// What one row ends as: its state, and the resolved title when the episode plays. Links to the same show share one
// lookup within a check.
async function judge(ctx, entry, shows) {
  if (entry.kind === "apple_show" || entry.markedShowLink) return { state: "show" };
  if (hasBadEpisodeId(entry.url)) return { state: "failed" };
  const episodeId = appleEpisodeId(entry.url);
  const showId = appleShowId(entry.url);
  if (!episodeId) return { state: "other" };
  if (!showId) return { state: "failed" };
  if (!shows.has(showId)) shows.set(showId, lookUp(ctx, showId));
  let body;
  try {
    body = await shows.get(showId);
  } catch {
    return { state: "error" };
  }
  const result = judgeLookup(entry, episodeId, body);
  return { state: result.verdict, title: result.resolvedTitle };
}

async function runChecks(ctx, jobs, generation) {
  let next = 0;
  const shows = new Map();
  const worker = async () => {
    while (next < jobs.length) {
      const job = jobs[next++];
      job.outcome = await judge(ctx, job.entry, shows);
      if (generation !== ctx.checkGeneration) return;
      drawRow(ctx, job.row, job.outcome.state, job.outcome.title);
    }
  };
  await Promise.all(Array.from({ length: Math.min(LOOKUPS_AT_ONCE, jobs.length) }, worker));
}

async function checkLinks(ctx) {
  const { parts: page, env } = ctx;
  clearCheck(ctx);
  const generation = ctx.checkGeneration;
  if (page.answer.value.trim() === "") {
    page.checkMessage.textContent = CHECK.empty;
    env.focus(page.answer);
    return;
  }
  const entries = parsePaste(page.answer.value);
  if (entries.length === 0) {
    page.checkMessage.textContent = CHECK.noLinks;
    return;
  }
  const needsNetwork = entries.some((entry) => entry.kind !== "apple_show" && !entry.markedShowLink && appleEpisodeId(entry.url));
  if (needsNetwork && !env.online()) {
    page.checkMessage.textContent = CHECK.offline;
    return;
  }
  const jobs = entries.map((entry) => ({ entry, row: newRow(ctx, entry), outcome: null }));
  for (const job of jobs) {
    drawRow(ctx, job.row, "checking");
    page.results.appendChild(job.row);
  }
  page.results.hidden = false;
  page.checkMessage.textContent = jobs.length === 1 ? "Checking 1 link…" : `Checking ${jobs.length} links…`;
  await runChecks(ctx, jobs, generation);
  if (generation !== ctx.checkGeneration) return;

  const states = jobs.map((job) => job.outcome.state);
  const playing = states.filter((state) => state === "right").length;
  page.checkMessage.textContent = `Checked ${jobs.length === 1 ? "1 link" : `${jobs.length} links`}. ` +
    `${playing} of ${jobs.length} ${playing === 1 ? "plays" : "play"} the episode named.`;
  const failed = jobs.filter((job) => job.outcome.state === "show" || job.outcome.state === "failed");
  page.noneWorked.hidden = failed.length !== jobs.length;
  if (failed.length > 0) {
    page.followUpText.value = renderFollowUp(ctx.quiz, failed.map((job) => job.entry.line));
    page.followUp.hidden = false;
  }
}

async function copyFollowUp(ctx) {
  const { parts: page, env } = ctx;
  const generation = ctx.checkGeneration;
  try {
    if (!env.clipboard || typeof env.clipboard.writeText !== "function") throw new Error("no clipboard");
    await env.clipboard.writeText(page.followUpText.value);
  } catch {
    if (generation !== ctx.checkGeneration) return;
    cancelFollowUpTimer(ctx);
    page.copyFollowUp.textContent = "Copy follow-up prompt";
    env.selectAll(page.followUpText);
    page.followUpStatus.textContent = FOLLOW_UP_COPY_FAILED;
    return;
  }
  if (generation !== ctx.checkGeneration) return;
  cancelFollowUpTimer(ctx);
  page.copyFollowUp.textContent = "Copied";
  page.followUpStatus.textContent = "Follow-up prompt copied";
  ctx.followUpTimer = env.setTimeout(() => {
    ctx.followUpTimer = null;
    page.copyFollowUp.textContent = "Copy follow-up prompt";
  }, 2000);
}

/** Draw the form into #quiz from this quiz data and wire the page. Safe to call again after a failed load. */
export function mountQuiz(document, quiz, env) {
  const page = parts(document);
  let ctx = contexts.get(page.form);
  if (!ctx) {
    ctx = { copyTimer: null, followUpTimer: null, renderCount: 0, checkGeneration: 0, wired: false };
    contexts.set(page.form, ctx);
  }
  Object.assign(ctx, { document, quiz, env, parts: page, answers: { who: "friend" }, promptShown: false });
  cancelCopyTimer(ctx);
  page.prompt.hidden = true;
  page.copy.textContent = "Copy prompt";
  page.copyStatus.textContent = "";
  page.noneWorked.textContent = quiz.noneWorked;
  clearCheck(ctx);
  if (!ctx.wired) {
    // These elements outlive a redraw, so their listeners are attached once, here, and read the context as it is
    // now. The flag is set before anything below can throw, so a retry after a failed draw neither skips nor repeats.
    ctx.wired = true;
    page.form.addEventListener("submit", (event) => {
      event.preventDefault();
      makePrompt(ctx);
    });
    page.copy.addEventListener("click", () => copyPrompt(ctx));
    page.startOver.addEventListener("click", () => startOver(ctx));
    page.check.addEventListener("click", () => checkLinks(ctx));
    page.copyFollowUp.addEventListener("click", () => copyFollowUp(ctx));
  }
  drawForm(ctx);
  page.reset.hidden = false;
}

function showLoadFailed(document, env) {
  const page = parts(document);
  page.form.replaceChildren();
  page.reset.hidden = true;
  page.prompt.hidden = true;
  page.status.textContent = LOAD_FAILED;
  const retry = element(document, "button", { type: "button", id: "retry" }, "Try again");
  retry.addEventListener("click", async () => {
    page.status.textContent = LOADING;
    await start(document, env);
    const friend = page.form.querySelector('input[name="who"][value="friend"]');
    env.focus(page.form.children.length > 0 && friend ? friend : document.getElementById("retry"));
  });
  page.status.appendChild(retry);
}

/** Load the questions and draw the page. Always resolves: a failure shows the load-failed state. */
export async function start(document, env) {
  const page = parts(document);
  page.status.textContent = LOADING;
  try {
    const response = await env.fetch(env.dataURL);
    if (!response.ok) throw new Error("the questions did not load");
    const quiz = await response.json();
    mountQuiz(document, quiz, env);
    page.status.textContent = "";
  } catch {
    showLoadFailed(document, env);
  }
}

if (typeof document !== "undefined") {
  document.documentElement.dataset.quiz = "started";
  start(document, {
    fetch: (url) => fetch(url),
    // Only after a tap on "Check links": no cookies, no referrer.
    lookup: (url) => fetch(url, { credentials: "omit", referrerPolicy: "no-referrer" }),
    online: () => navigator.onLine !== false,
    dataURL: new URL("./v1/find-something.json", import.meta.url),
    clipboard: navigator.clipboard,
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (id) => clearTimeout(id),
    focus: (el) => el.focus(),
    scrollIntoView: (el) => el.scrollIntoView({ block: "start" }),
    selectAll: (textarea) => {
      textarea.focus();
      textarea.setSelectionRange(0, textarea.value.length);
    },
  });
}
