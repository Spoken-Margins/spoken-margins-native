import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";
import { build } from "esbuild";
import { parseHTML } from "linkedom";
import {
  captureReadablePage,
  fallbackReadableMarkdown,
  normalizeSocialEmbedsForReading,
  sourceMetadata
} from "./browserExtractionCore.mjs";
import {
  canRetry,
  capturePage,
  invokeInjectedCapture
} from "./popupCore.mjs";
import { BUNDLES, esbuildOptions } from "./bundleConfig.mjs";
import { browserLikePage } from "./testDocument.mjs";
import { JOURNAL_BYLINE, JOURNAL_SECTIONS, journalArticleBody } from "./journalArticleFixture.mjs";

function articleDocument() {
  const body = "<p>" + "Useful article prose. ".repeat(80) + "</p>";
  const { document, window } = parseHTML(`<!doctype html><html><head>
    <title>Retirement Guide</title><meta name="author" content="A. Writer">
    </head><body><nav>Navigation noise</nav><article>
    <h2>First section</h2>${body}<h3>Second section</h3>${body}
    </article><footer>Footer noise</footer></body></html>`);
  Object.defineProperty(document, "location", { value: { href: "https://example.com/guide" } });
  Object.defineProperty(document, "URL", { value: "https://example.com/guide" });
  globalThis.document = document;
  globalThis.window = window;
  return document;
}

test("native and bundled fallbacks consume nested quotations and lists once, preserving authored repetition", () => {
  const { document } = parseHTML(`<html><head><title>Quotation</title></head><body><article>
    <blockquote><p>First quoted paragraph.</p><p>Second quoted paragraph.</p>
      <blockquote><p>Nested quotation.</p></blockquote>
      <ul><li>List parent.<ul><li>Nested list.</li></ul></li></ul>
    </blockquote>
    <p>Intentional repetition.</p><p>Intentional repetition.</p>
  </article></body></html>`);
  Object.defineProperty(document, "location", { value: { href: "https://example.com/quote" } });
  // Execute the actual emergency script shipped in the native extractor, not
  // a copied implementation that could pass while the native path regresses.
  const swift = fs.readFileSync("App/SpokenMarginsApp/Sources/SpokenMarginsApp/AppOwnedReadablePageExtractor.swift", "utf8");
  const script = swift.split('private static let semanticFallbackJavaScript = #"""')[1].split('"""#')[0];
  const native = new Function("document", script)(document);
  assert.equal(native.metadata.extractor, "native_semantic_dom_fallback");
  for (const text of [native.text, fallbackReadableMarkdown(document)]) {
    for (const passage of ["First quoted paragraph.", "Second quoted paragraph.", "Nested quotation.", "List parent.", "Nested list."]) {
      assert.equal(text.split(passage).length - 1, 1, passage);
    }
    assert.equal(text.split("Intentional repetition.").length - 1, 2);
    assert.ok(text.indexOf("First quoted paragraph.") < text.indexOf("Second quoted paragraph."));
  }
});

test("social cards retain authored commentary and omit listening-hostile interface metadata", () => {
  const markdown = `Before the post.

[

![X avatar for @netflix](https://cdn.example/avatar.jpg)

Netflix@netflix

DANG!, a new adult animated series, premieres September 8, until their high-achieving sister Ruthie wants

<video controls="" src="https://video.example/trailer.mp4"></video>

3:00 PM · Aug 11, 2026 · 29.7M Views

---

1.42K Replies · 975 Reposts · 23.3K Likes

](https://x.com/netflix/status/2087192315823538471)

After the post.`;

  const normalized = normalizeSocialEmbedsForReading(markdown);

  assert.equal(
    normalized,
    "Before the post.\n\nPost from Netflix. DANG!, a new adult animated series, premieres September 8, until their high-achieving sister Ruthie wants. Media attached.\n\nAfter the post."
  );
  assert.doesNotMatch(normalized, /video|29\.7M|Replies|Reposts|Likes|x\.com|\[|\]/i);
});

test("social-card cleanup preserves quoted posts and ordinary audience prose", () => {
  const markdown = `[

Writer@writer

This is the writer's response.

![](https://cdn.example/quoted-avatar.jpg)

Netflix @netflix

This is the quoted post.

24 Replies · 30 Reposts · 401 Likes

](https://twitter.com/writer/status/1)

The trailer received 29.7M Views in ordinary article prose.`;

  assert.equal(
    normalizeSocialEmbedsForReading(markdown),
    "Post from Writer. This is the writer's response. Quoted post from Netflix. This is the quoted post.\n\nThe trailer received 29.7M Views in ordinary article prose."
  );
});

test("readable capture falls back to local semantic Markdown when the test DOM cannot run Defuddle", () => {
  const document = articleDocument();
  const originalError = console.error;
  const originalLog = console.log;
  console.error = () => {};
  console.log = () => {};
  let payload;
  try {
    payload = captureReadablePage({ crypto: { randomUUID: () => "test-id" }, navigator: {} }, document);
  } finally {
    console.error = originalError;
    console.log = originalLog;
  }

  assert.equal(payload.captureMode, "readable_page");
  assert.equal(payload.contentFormat, "markdown");
  assert.equal(payload.metadata.extractor, "semantic_dom_fallback");
  assert.equal(payload.metadata.extractorVersion, "1");
  assert.match(payload.metadata.extractionError, /No readable page text was found/);
  assert.equal(payload.metadata.networkFallback, false);
  assert.match(payload.text, /## First section/i);
  assert.match(payload.text, /### Second section/i);
  assert.doesNotMatch(payload.text, /Navigation noise|Footer noise/);
  // The rest of the hand-off the app reads: where the page came from, which
  // schema it is, and that capturing must not start a listening session.
  assert.deepEqual(payload.source, {
    url: "https://example.com/guide",
    title: "Retirement Guide",
    author: "A. Writer",
    publishedAt: null
  });
  assert.equal(payload.id, "test-id");
  assert.equal(payload.schemaVersion, "browser-text-handoff.v1");
  assert.equal(payload.selection, null);
  assert.deepEqual(payload.requestedContinuation, { startSession: false, preferredPlaybackOwner: "app" });
});

// The real extractor, not the fallback: the page is a linkedom document with
// the one browser feature Defuddle's Markdown step needs (testDocument.mjs).
function withGlobalDocument(document, run) {
  const previous = globalThis.document;
  globalThis.document = document;
  try {
    return run();
  } finally {
    globalThis.document = previous;
  }
}

const articleProse = "<p>" + "Useful article prose. ".repeat(40) + "</p>";

test("readable capture hands the app Defuddle's Markdown with the page's source details", () => {
  const document = browserLikePage({
    head: `<title>Retirement Guide</title><meta name="author" content="A. Writer">
      <meta property="article:published_time" content="2026-09-01">`,
    body: `<nav>Navigation noise</nav><article><h2>First section</h2>${articleProse}
      <h3>Second section</h3>${articleProse}</article><footer>Footer noise</footer>`
  });
  const payload = withGlobalDocument(document, () =>
    captureReadablePage({ crypto: { randomUUID: () => "test-id" }, navigator: { userAgent: "test-agent" } }, document)
  );

  assert.equal(payload.id, "test-id");
  assert.equal(payload.schemaVersion, "browser-text-handoff.v1");
  assert.equal(payload.captureMode, "readable_page");
  assert.equal(payload.contentFormat, "markdown");
  assert.deepEqual(payload.source, {
    url: "https://example.com/guide",
    title: "Retirement Guide",
    author: "A. Writer",
    publishedAt: "2026-09-01"
  });
  assert.equal(payload.selection, null);
  assert.deepEqual(payload.requestedContinuation, { startSession: false, preferredPlaybackOwner: "app" });
  assert.match(payload.createdAt, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
  assert.deepEqual(payload.metadata, {
    extractor: "defuddle",
    extractorVersion: "0.19.5",
    networkFallback: false,
    userAgent: "test-agent"
  });
  assert.match(payload.text, /^## First section\n\nUseful article prose\./);
  assert.match(payload.text, /\n\n### Second section\n\nUseful article prose\./);
  assert.doesNotMatch(payload.text, /Navigation noise|Footer noise/);
});

test("readable capture speaks a social card as a sentence, not as link and view-count markup", () => {
  const document = browserLikePage({
    head: "<title>Retirement Guide</title>",
    body: `<article><h2>First section</h2>${articleProse}
      <a href="https://x.com/netflix/status/2087192315823538471"><div><p>Netflix@netflix</p></div>
      <div><p>DANG! A new adult animated series premieres September 8.</p></div>
      <div>3:00 PM · Aug 11, 2026 · 29.7M Views</div>
      <div>1.42K Replies · 975 Reposts · 23.3K Likes</div></a>${articleProse}</article>`
  });
  const payload = withGlobalDocument(document, () =>
    captureReadablePage({ crypto: { randomUUID: () => "test-id" }, navigator: {} }, document)
  );

  assert.equal(payload.metadata.extractor, "defuddle");
  assert.match(payload.text, /\n\nPost from Netflix\. DANG! A new adult animated series premieres September 8\.\n\n/);
  assert.doesNotMatch(payload.text, /29\.7M|Replies|Reposts|Likes|x\.com|Netflix@netflix|\[|\]/);
});

test("source details come from the extractor first, then the page's meta tags, then plain defaults", () => {
  const meta = (name, value) => `<meta ${name.startsWith("og:") || name.startsWith("article:") ? "property" : "name"}="${name}" content="${value}">`;
  const page = (head, body = "") => browserLikePage({ head, body });

  // Extractor values beat every meta tag; whitespace is collapsed.
  assert.deepEqual(
    sourceMetadata(
      page(`<title>Tab Title</title>${meta("og:title", "OG Title")}${meta("author", "Meta Author")}${meta("date", "2020-01-01")}`),
      { title: "  Extracted \n Title ", author: " Extracted  Author", published: "2026-01-02" }
    ),
    { url: "https://example.com/guide", title: "Extracted Title", author: "Extracted Author", publishedAt: "2026-01-02" }
  );

  // Title: og:title, then twitter:title, then the tab title, then "Browser Text".
  assert.equal(sourceMetadata(page(`<title>Tab</title>${meta("og:title", "OG")}${meta("twitter:title", "Tw")}`)).title, "OG");
  assert.equal(sourceMetadata(page(`<title>Tab</title>${meta("twitter:title", "Tw")}`)).title, "Tw");
  assert.equal(sourceMetadata(page("<title>  Tab   Title </title>")).title, "Tab Title");
  assert.equal(sourceMetadata(page("")).title, "Browser Text");

  // Author: name=author, then article:author, then byl; none is null.
  assert.equal(sourceMetadata(page(`${meta("author", "A")}${meta("article:author", "B")}${meta("byl", "C")}`)).author, "A");
  assert.equal(sourceMetadata(page(`${meta("article:author", "B")}${meta("byl", "C")}`)).author, "B");
  assert.equal(sourceMetadata(page(`${meta("byl", "C")}`)).author, "C");
  assert.equal(sourceMetadata(page("")).author, null);

  // Published: article:published_time, then name=date, then citation_publication_date, then <time datetime>.
  const published = `${meta("article:published_time", "2026-03-01")}${meta("date", "2026-03-02")}${meta("citation_publication_date", "2026-03-03")}`;
  assert.equal(sourceMetadata(page(published, `<time datetime="2026-03-04">March</time>`)).publishedAt, "2026-03-01");
  assert.equal(sourceMetadata(page(`${meta("date", "2026-03-02")}${meta("citation_publication_date", "2026-03-03")}`)).publishedAt, "2026-03-02");
  assert.equal(sourceMetadata(page(meta("citation_publication_date", "2026-03-03"))).publishedAt, "2026-03-03");
  assert.equal(sourceMetadata(page("", `<time datetime="2026-03-04">March</time>`)).publishedAt, "2026-03-04");
  assert.equal(sourceMetadata(page("")).publishedAt, null);

  // Address: location.href, then document.URL, then about:blank.
  const bare = { querySelector: () => null, title: "" };
  assert.equal(sourceMetadata({ ...bare, location: { href: "https://a.example/x" }, URL: "https://b.example/y" }).url, "https://a.example/x");
  assert.equal(sourceMetadata({ ...bare, URL: "https://b.example/y" }).url, "https://b.example/y");
  assert.equal(sourceMetadata(bare).url, "about:blank");
});

test("semantic DOM fallback preserves article headings and excludes surrounding navigation", () => {
  const document = articleDocument();
  const markdown = fallbackReadableMarkdown(document);

  assert.match(markdown, /## First section/i);
  assert.match(markdown, /### Second section/i);
  assert.doesNotMatch(markdown, /Navigation noise|Footer noise/);
});

test("popup capture returns the injected result without tabs messaging", async () => {
  const payload = {
    captureMode: "readable_page",
    contentFormat: "markdown",
    source: { url: "https://example.com/guide", title: "Guide" },
    text: "Readable page text."
  };
  const calls = [];
  const extensionAPI = {
    tabs: {
      query: async () => [{ id: 42 }]
    },
    scripting: {
      executeScript: async (request) => {
        calls.push(request);
        if (request.files) {
          return [{ frameId: 0 }];
        }
        return [{ frameId: 0, result: { ok: true, payload } }];
      }
    }
  };

  assert.deepEqual(await capturePage(extensionAPI), { payload });
  assert.equal(calls.length, 2);
  assert.deepEqual(calls[0], {
    target: { tabId: 42 },
    files: ["browserTextCapture.js"]
  });
  assert.equal(calls[1].func, invokeInjectedCapture);
  assert.deepEqual(calls[1].args, []);
  assert.equal(extensionAPI.tabs.sendMessage, undefined);
});

test("popup capture reports the injected failure instead of a generic missing response", async () => {
  const extensionAPI = {
    tabs: {
      query: async () => [{ id: 9 }]
    },
    scripting: {
      executeScript: async (request) => request.files
        ? [{ frameId: 0 }]
        : [{ frameId: 0, result: { ok: false, error: "No readable article was found." } }]
    }
  };

  await assert.rejects(
    capturePage(extensionAPI),
    /No readable article was found\./
  );
});

test("injected dispatcher invokes the initialized page capture directly", () => {
  const previousCapture = globalThis.SpokenMarginsBrowserTextCapture;
  const previousDocument = globalThis.document;
  const documentRef = { title: "Direct Capture" };
  globalThis.document = documentRef;
  globalThis.SpokenMarginsBrowserTextCapture = {
    captureReadablePage: (document) => ({ title: document.title })
  };
  try {
    assert.deepEqual(invokeInjectedCapture(), {
      ok: true,
      payload: { title: "Direct Capture" }
    });
  } finally {
    globalThis.SpokenMarginsBrowserTextCapture = previousCapture;
    globalThis.document = previousDocument;
  }
});

function withInjectedPage(documentRef, run) {
  const previousCapture = globalThis.SpokenMarginsBrowserTextCapture;
  const previousDocument = globalThis.document;
  let textCaptures = 0;
  globalThis.document = documentRef;
  globalThis.SpokenMarginsBrowserTextCapture = {
    captureReadablePage: () => {
      textCaptures += 1;
      return { title: "#annotationContainer { overflow: hidden; }" };
    }
  };
  try {
    return run(() => textCaptures);
  } finally {
    globalThis.SpokenMarginsBrowserTextCapture = previousCapture;
    globalThis.document = previousDocument;
  }
}

test("on a PDF tab the injected dispatcher hands back the PDF's address, not the viewer's text (#658)", () => {
  const arxiv = "https://arxiv.org/pdf/2609.31218v1";
  // arXiv serves the PDF without a .pdf suffix, so the content type decides.
  withInjectedPage({ contentType: "application/pdf", location: { href: arxiv } }, (textCaptures) => {
    assert.deepEqual(invokeInjectedCapture(), { ok: true, pdfURL: arxiv });
    assert.equal(textCaptures(), 0);
  });
  // Safari's PDF viewer document, recognised by WebKit's annotation container.
  const viewer = parseHTML(`<html><head><style>#annotationContainer { overflow: hidden; }</style></head>
    <body><div id="annotationContainer"></div></body></html>`).document;
  Object.defineProperty(viewer, "location", { value: { href: "https://example.org/download?id=7" } });
  withInjectedPage(viewer, (textCaptures) => {
    assert.deepEqual(invokeInjectedCapture(), { ok: true, pdfURL: "https://example.org/download?id=7" });
    assert.equal(textCaptures(), 0);
  });
  withInjectedPage({ contentType: "text/html", location: { href: "https://example.org/paper.PDF" } }, () => {
    assert.deepEqual(invokeInjectedCapture(), { ok: true, pdfURL: "https://example.org/paper.PDF" });
  });
});

test("an ordinary page and a non-HTTPS PDF still go through text capture", () => {
  const page = articleDocument();
  withInjectedPage(page, (textCaptures) => {
    assert.equal(invokeInjectedCapture().pdfURL, undefined);
    assert.equal(textCaptures(), 1);
  });
  withInjectedPage({ contentType: "application/pdf", location: { href: "http://example.org/a.pdf" } }, (textCaptures) => {
    assert.equal(invokeInjectedCapture().pdfURL, undefined);
    assert.equal(textCaptures(), 1);
  });
});

// An ordinary article that embeds a PDF (#689). Safari's viewer is the whole
// document; here the embed is one element among the prose.
const MIXED_ARTICLE_URL = "https://example.org/report";
function articleWithEmbeddedPDF() {
  const prose = "<p>" + "The report's findings, explained in plain prose. ".repeat(40) + "</p>";
  return browserLikePage({
    url: MIXED_ARTICLE_URL,
    head: "<title>Annual Report</title>",
    body: `<nav>Home</nav><article><h1>Annual Report</h1>${prose}
      <embed type="application/pdf" src="/attachment.pdf" width="600" height="800">
      <div id="annotationContainer"></div>${prose}</article><footer>Footer</footer>`
  });
}

test("#689: an article that embeds a PDF goes through text capture, not the PDF import", () => {
  withInjectedPage(articleWithEmbeddedPDF(), (textCaptures) => {
    const result = invokeInjectedCapture();
    assert.equal(result.pdfURL, undefined);
    assert.equal(result.ok, true);
    assert.equal(textCaptures(), 1);
  });
});

test("#689: a page that is only a PDF embed hands over the embed's own address", () => {
  const wrapper = browserLikePage({
    url: "https://example.org/view?doc=7",
    head: "<style>body { margin: 0 }</style>",
    body: `<embed type="application/pdf" src="/files/report.pdf?v=2" width="100%" height="100%">`
  });
  withInjectedPage(wrapper, (textCaptures) => {
    assert.deepEqual(invokeInjectedCapture(), { ok: true, pdfURL: "https://example.org/files/report.pdf?v=2" });
    assert.equal(textCaptures(), 0);
  });
  // A relative src follows the page's <base>, as the browser resolves it.
  const based = browserLikePage({
    url: "https://example.org/view?doc=8",
    head: `<base href="https://files.example.org/reports/">`,
    body: `<embed type="application/pdf" src="q3.pdf">`
  });
  withInjectedPage(based, () => {
    assert.deepEqual(invokeInjectedCapture(), { ok: true, pdfURL: "https://files.example.org/reports/q3.pdf" });
  });
  // WebKit's own PDF document points its embed at the tab's address.
  const pluginDocument = browserLikePage({
    url: "https://example.org/download?id=7",
    body: `<embed type="application/pdf" name="plugin" src="https://example.org/download?id=7"><div id="annotationContainer"></div>`
  });
  withInjectedPage(pluginDocument, () => {
    assert.deepEqual(invokeInjectedCapture(), { ok: true, pdfURL: "https://example.org/download?id=7" });
  });
  // An embed that points at a non-https address can't go to the PDF import.
  const insecure = browserLikePage({
    url: "https://example.org/view",
    body: `<embed type="application/pdf" src="http://files.example.org/a.pdf">`
  });
  withInjectedPage(insecure, (textCaptures) => {
    assert.equal(invokeInjectedCapture().pdfURL, undefined);
    assert.equal(textCaptures(), 1);
  });
});

test("popup capture passes a PDF address through instead of a text payload", async () => {
  const extensionAPI = {
    tabs: { query: async () => [{ id: 3 }] },
    scripting: {
      executeScript: async (request) => request.files
        ? [{ frameId: 0 }]
        : [{ frameId: 0, result: { ok: true, pdfURL: "https://arxiv.org/pdf/2609.31218v1" } }]
    }
  };
  assert.deepEqual(await capturePage(extensionAPI), { pdfURL: "https://arxiv.org/pdf/2609.31218v1" });
});

// Safari refuses scripting.executeScript on a tab the extension has no access
// to, such as a PDF opened straight in Safari (#1143).
const SAFARI_REFUSAL = "Invalid call to scripting.executeScript(). This extension does not have access to this tab.";

function refusedTabAPI(tab, { refuse = SAFARI_REFUSAL, calls = [], ErrorType = Error } = {}) {
  return {
    tabs: { query: async () => [{ id: 11, ...tab }] },
    scripting: {
      executeScript: async (request) => {
        calls.push(request);
        throw typeof refuse === "string" ? new ErrorType(refuse) : refuse;
      }
    }
  };
}

const SHARE_SHEET_ADVICE = /Tap Share in Safari and choose Spoken Margins\./;

test("a refused PDF tab is sent through the PDF import from the tab's own address", async () => {
  const calls = [];
  const api = refusedTabAPI({ url: "https://www.cam.ac.uk/casp/what-if.pdf" }, { calls });
  assert.deepEqual(await capturePage(api), { pdfURL: "https://www.cam.ac.uk/casp/what-if.pdf" });
  assert.equal(calls.length, 1, "no second injection is attempted on a tab Safari refused");
});

test("a refused page that is not a PDF names the Share sheet and offers no retry", async () => {
  const api = refusedTabAPI({ url: "https://example.com/guide" });
  await assert.rejects(capturePage(api), (error) => {
    assert.match(error.message, /Can’t import this page from the Safari extension\./);
    assert.match(error.message, SHARE_SHEET_ADVICE);
    assert.doesNotMatch(error.message, /could not access|executeScript/i);
    assert.equal(canRetry(error), false);
    return true;
  });
});

test("a refused tab whose address Safari withholds names the Share sheet", async () => {
  for (const tab of [{}, { url: undefined }, { url: null }, { url: "" }, { url: 42 }]) {
    await assert.rejects(capturePage(refusedTabAPI(tab)), (error) => {
      assert.match(error.message, SHARE_SHEET_ADVICE);
      assert.equal(canRetry(error), false);
      return true;
    });
  }
});

test("a refused tab's address decides between the PDF import and the Share sheet", async () => {
  const rows = [
    // [tab address, address handed to the PDF import, or null for the Share sheet advice, "PDF" or "page" wording]
    ["https://example.org/a.pdf", "https://example.org/a.pdf"],
    ["https://example.org/A.PDF", "https://example.org/A.PDF"],
    ["https://example.org/a.pdf?download=1", "https://example.org/a.pdf?download=1"],
    ["https://example.org/a.pdf#page=3", "https://example.org/a.pdf#page=3"],
    ["  https://example.org/a.pdf  ", "https://example.org/a.pdf"],
    ["HTTPS://Example.ORG/a.pdf", "https://example.org/a.pdf"],
    ["https://example.org/" + "a".repeat(5000) + ".pdf", "https://example.org/" + "a".repeat(5000) + ".pdf"],
    // The PDF import takes https addresses only, so these go to the Share sheet.
    ["http://example.org/a.pdf", null, "PDF"],
    ["file:///var/mobile/a.pdf", null, "PDF"],
    // Lookalikes: the path must end in .pdf.
    ["https://example.org/a.pdf/", null, "page"],
    ["https://example.org/a.pdf.html", null, "page"],
    ["https://example.org.pdf/", null, "page"],
    ["https://example.org/pdf/2609.31218v1", null, "page"],
    ["https://example.org/", null, "page"],
    ["blob:https://example.org/3f1c", null, "page"],
    ["not a url", null, "page"]
  ];
  for (const [url, handedOver, wording] of rows) {
    const label = JSON.stringify(url.length > 80 ? `${url.slice(0, 40)}…` : url);
    if (handedOver) {
      assert.deepEqual(await capturePage(refusedTabAPI({ url })), { pdfURL: handedOver }, label);
      continue;
    }
    await assert.rejects(capturePage(refusedTabAPI({ url })), (error) => {
      assert.match(error.message, new RegExp(`Can’t import this ${wording} from the Safari extension\\.`), label);
      assert.match(error.message, SHARE_SHEET_ADVICE, label);
      assert.equal(canRetry(error), false, label);
      return true;
    });
  }
});

test("only Safari's no-access refusals are told apart from other injection errors", async () => {
  const refusals = [
    SAFARI_REFUSAL,
    "This extension does not have access to this tab",
    "THIS EXTENSION DOES NOT HAVE ACCESS TO THIS TAB.",
    "  Invalid call to scripting.executeScript().\n\tThis extension does not have access to this tab.  ",
    { message: SAFARI_REFUSAL }
  ];
  for (const refusal of refusals) {
    const label = JSON.stringify(refusal);
    await assert.rejects(capturePage(refusedTabAPI({ url: "https://example.com/x" }, { refuse: refusal })), (error) => {
      assert.match(error.message, SHARE_SHEET_ADVICE, label);
      assert.equal(canRetry(error), false, label);
      return true;
    });
  }
  const transient = [
    new Error("The network connection was lost."),
    new Error("Script execution timed out."),
    // Same "Invalid call" prefix, different reason: Try Again may fix these.
    new Error("Invalid call to scripting.executeScript(). No tab with id 11."),
    new Error("Invalid call to scripting.executeScript(). The file browserTextCapture.js was not found."),
    new Error("Cannot access contents of the page."),
    new Error(""),
    "plain string failure",
    null
  ];
  for (const failure of transient) {
    await assert.rejects(
      capturePage(refusedTabAPI({ url: "https://example.org/a.pdf" }, { refuse: failure })),
      (error) => {
        assert.match(error.message, /^Safari could not access this page: /);
        assert.doesNotMatch(error.message, /Share/);
        assert.equal(canRetry(error), true, String(failure));
        return true;
      }
    );
  }
});

test("a refusal on the capture call, after the script loaded, is handled the same way", async () => {
  const api = {
    tabs: { query: async () => [{ id: 4, url: "https://example.org/a.pdf" }] },
    scripting: {
      executeScript: async (request) => {
        if (request.files) { return [{ frameId: 0 }]; }
        throw new Error(SAFARI_REFUSAL);
      }
    }
  };
  assert.deepEqual(await capturePage(api), { pdfURL: "https://example.org/a.pdf" });
  const page = { ...api, tabs: { query: async () => [{ id: 4, url: "https://example.org/guide" }] } };
  await assert.rejects(capturePage(page), (error) => SHARE_SHEET_ADVICE.test(error.message) && !canRetry(error));
});

test("a tab the extension can read still goes through page capture whatever its address", async () => {
  const payload = { captureMode: "readable_page", text: "Readable page text." };
  const api = {
    tabs: { query: async () => [{ id: 5, url: "https://example.org/looks-like.pdf" }] },
    scripting: {
      executeScript: async (request) => request.files
        ? [{ frameId: 0 }]
        : [{ frameId: 0, result: { ok: true, payload } }]
    }
  };
  assert.deepEqual(await capturePage(api), { payload });
});

test("other popup failures keep Try Again", () => {
  assert.equal(canRetry(new Error("The page capture returned no content.")), true);
  assert.equal(canRetry(new Error("Unable to send this PDF to Spoken Margins.")), true);
  assert.equal(canRetry("a string"), true);
  assert.equal(canRetry(undefined), true);
});

// Runs the built popup.js against a stand-in popup page and extension API.
// `makeAPI` gets the popup's own Error class so `instanceof Error` behaves as in Safari.
async function runBuiltPopup(makeAPI) {
  const source = fs.readFileSync("App/SpokenMarginsBrowserTextExtension/Resources/Scripts/popup.js", "utf8");
  const status = { textContent: "" };
  const button = { disabled: false, hidden: true, addEventListener: () => {} };
  const elements = { status, readablePageButton: button };
  const context = vm.createContext({ console, URL, document: { getElementById: (id) => elements[id] } });
  context.browser = makeAPI(vm.runInContext("Error", context));
  vm.runInContext(source, context);
  await new Promise((resolve) => setTimeout(resolve, 20));
  return { status: status.textContent, tryAgainShown: !button.hidden, tryAgainEnabled: !button.disabled };
}

test("built popup: a refused page shows the Share sheet advice and no Try Again (#1143)", async () => {
  const shown = await runBuiltPopup((ErrorType) => {
    const api = refusedTabAPI({ url: "https://example.org/notes" }, { ErrorType });
    api.tabs.update = async () => { throw new Error("must not open the app"); };
    return api;
  });
  assert.equal(shown.status, "Can’t import this page from the Safari extension. Tap Share in Safari and choose Spoken Margins.");
  assert.equal(shown.tryAgainShown, false);
});

test("built popup: a refused .pdf tab is handed to the app's PDF import", async () => {
  const sent = [];
  const opened = [];
  const shown = await runBuiltPopup((ErrorType) => {
    const api = refusedTabAPI({ url: "https://www.cam.ac.uk/casp/what-if.pdf" }, { ErrorType });
    api.runtime = {
      sendNativeMessage: async (id, message) => {
        sent.push(message);
        return { ok: true, openURL: "spokenmargins://source-link?payloadId=abc" };
      }
    };
    api.tabs.update = async (id, change) => { opened.push([id, change.url]); };
    return api;
  });
  assert.equal(shown.status, "Opening Spoken Margins.");
  assert.deepEqual(JSON.parse(JSON.stringify(sent)), [{ action: "storeRemotePDFHandoff", url: "https://www.cam.ac.uk/casp/what-if.pdf" }]);
  assert.deepEqual(opened, [[11, "spokenmargins://source-link?payloadId=abc"]]);
  assert.equal(shown.status, "Opening Spoken Margins.");
});

// A tab the extension can read. Like Safari, executeScript runs the shipped
// capture script and then the popup's function, from its source text, in the
// page's own context, and reports frame 0's result.
function readableTabAPI(page, url, sent) {
  const pageContext = vm.createContext({
    document: page,
    navigator: { userAgent: "test" },
    crypto: { randomUUID: () => "test-payload-id" },
    URL,
    Date
  });
  return {
    tabs: { query: async () => [{ id: 12, url }], update: async () => {} },
    scripting: {
      executeScript: async (request) => {
        if (request.files) {
          vm.runInContext(fs.readFileSync("App/SharedResources/browserTextCapture.js", "utf8"), pageContext);
          return [{ frameId: 0 }];
        }
        return [{ frameId: 0, result: vm.runInContext(`(${request.func.toString()})()`, pageContext) }];
      }
    },
    runtime: {
      sendNativeMessage: async (id, message) => {
        sent.push(message);
        return { ok: true, openURL: "spokenmargins://browser-text?payloadId=abc" };
      }
    }
  };
}

test("#689: built popup sends an article with an embedded PDF as page text, never its address as a PDF", async () => {
  const sent = [];
  const shown = await runBuiltPopup(() => readableTabAPI(articleWithEmbeddedPDF(), MIXED_ARTICLE_URL, sent));
  assert.equal(shown.status, "Opening Spoken Margins.");
  assert.deepEqual(sent.map((message) => message.action), ["storeBrowserTextPayload"]);
  assert.match(JSON.stringify(sent[0].payload), /findings, explained in plain prose/);
});

test("built popup: a PDF tab is still sent to the PDF import", async () => {
  const sent = [];
  const pdfTab = "https://example.org/download?id=7";
  const page = browserLikePage({ url: pdfTab, body: `<embed type="application/pdf" name="plugin" src="${pdfTab}">` });
  Object.defineProperty(page, "contentType", { value: "application/pdf" });
  const shown = await runBuiltPopup(() => readableTabAPI(page, pdfTab, sent));
  assert.equal(shown.status, "Opening Spoken Margins.");
  assert.deepEqual(JSON.parse(JSON.stringify(sent)), [{ action: "storeRemotePDFHandoff", url: pdfTab }]);
});

test("built popup: a transient injection failure still offers Try Again", async () => {
  const shown = await runBuiltPopup((ErrorType) =>
    refusedTabAPI({ url: "https://example.org/notes" }, { refuse: "The network connection was lost.", ErrorType }));
  assert.match(shown.status, /^Safari could not access this page: The network connection was lost\.$/);
  assert.equal(shown.tryAgainShown, true);
  assert.equal(shown.tryAgainEnabled, true);
});

test("built resources contain the pinned extractor and Safari preprocessor", () => {
  const capture = fs.readFileSync("App/SharedResources/browserTextCapture.js", "utf8");
  const popup = fs.readFileSync("App/SpokenMarginsBrowserTextExtension/Resources/Scripts/popup.js", "utf8");
  const preprocessor = fs.readFileSync("App/SpokenMarginsShareExtension/Resources/SourceLinkPreprocessor.js", "utf8");
  assert.match(capture, /Bundled Defuddle 0\.19\.5/);
  assert.doesNotMatch(capture, /onMessage\.addListener/);
  assert.doesNotMatch(popup, /tabs\.sendMessage/);
  assert.match(popup, /scripting\.executeScript/);
  assert.match(popup, /does not have access to this tab/);
  assert.match(preprocessor, /Bundled Defuddle 0\.19\.5/);
  assert.match(preprocessor, /SourceLinkPreprocessor/);
  assert.match(preprocessor, /plain_text/);
});

test("Safari preprocessor identifies a PDF document even when it has no readable body", () => {
  const preprocessorSource = fs.readFileSync(
    "App/SpokenMarginsShareExtension/Resources/SourceLinkPreprocessor.js",
    "utf8"
  );
  const context = {
    console,
    document: {
      URL: "https://example.com/brief.pdf",
      contentType: "application/pdf",
      title: "Brief PDF",
      body: null,
      querySelector: () => null
    },
    window: { location: { href: "https://example.com/brief.pdf" } }
  };
  vm.runInNewContext(preprocessorSource, context);
  assert.ok(context.ExtensionPreprocessingJS);
  let payload;
  context.ExtensionPreprocessingJS.run({
    completionFunction: (value) => { payload = value; }
  });

  assert.equal(payload.contentType, "application/pdf");
  assert.equal(payload.isPDFDocument, true);
  assert.equal(payload.documentURL, "https://example.com/brief.pdf");
});

function runPreprocessorOnPDF(fetchImplementation) {
  const preprocessorSource = fs.readFileSync(
    "App/SpokenMarginsShareExtension/Resources/SourceLinkPreprocessor.js",
    "utf8"
  );
  const context = {
    console,
    fetch: fetchImplementation,
    btoa,
    AbortController,
    setTimeout,
    clearTimeout,
    document: {
      URL: "https://pmc.ncbi.nlm.nih.gov/articles/PMC13305550/pdf/f1000research-12-147832.pdf",
      contentType: "application/pdf",
      title: "f1000research-12-147832.pdf",
      body: null,
      querySelector: () => null
    },
    window: { location: { href: "https://pmc.ncbi.nlm.nih.gov/articles/PMC13305550/pdf/f1000research-12-147832.pdf" } }
  };
  vm.runInNewContext(preprocessorSource, context);
  return new Promise((resolve) => {
    context.ExtensionPreprocessingJS.run({ completionFunction: resolve });
  });
}

function response(bytes, { ok = true, contentLength = bytes.length } = {}) {
  return {
    ok,
    headers: { get: (name) => (name.toLowerCase() === "content-length" ? String(contentLength) : null) },
    body: new ReadableStream({
      start(controller) {
        controller.enqueue(bytes);
        controller.close();
      }
    }),
    arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
  };
}

// A PDF answer with no content-length that keeps sending 1 MB chunks, counting what was read.
function endlessPDFResponse({ ok = true } = {}) {
  const stats = { chunksRead: 0, cancelled: false, arrayBufferCalled: false };
  const chunk = new Uint8Array(1024 * 1024);
  chunk.set(new TextEncoder().encode("%PDF-1.7"));
  return {
    stats,
    response: {
      ok,
      headers: { get: () => null },
      body: new ReadableStream({
        pull(controller) {
          stats.chunksRead += 1;
          controller.enqueue(chunk.slice());
        },
        cancel() {
          stats.cancelled = true;
        }
      }),
      arrayBuffer: async () => {
        stats.arrayBufferCalled = true;
        throw new Error("the whole body must never be buffered");
      }
    }
  };
}

test("#271: Safari preprocessor hands over the PDF the page has open", async () => {
  const pdfBytes = new TextEncoder().encode("%PDF-1.7 F1000Research 12:1146");
  let requested;
  const payload = await runPreprocessorOnPDF(async (url, options) => {
    requested = { url, credentials: options.credentials };
    return response(pdfBytes);
  });

  assert.equal(payload.isPDFDocument, true);
  assert.deepEqual(requested, {
    url: "https://pmc.ncbi.nlm.nih.gov/articles/PMC13305550/pdf/f1000research-12-147832.pdf",
    credentials: "include"
  });
  assert.equal(Buffer.from(payload.pdfBase64, "base64").toString("latin1"), "%PDF-1.7 F1000Research 12:1146");
});

test("#271: an HTML answer, a failed fetch or an oversized PDF leaves only the link", async () => {
  const html = new TextEncoder().encode("<html>Preparing to download ...</html>");
  const htmlPayload = await runPreprocessorOnPDF(async () => response(html));
  assert.equal(htmlPayload.pdfBase64, undefined);
  assert.equal(htmlPayload.documentURL, "https://pmc.ncbi.nlm.nih.gov/articles/PMC13305550/pdf/f1000research-12-147832.pdf");

  const failedPayload = await runPreprocessorOnPDF(async () => { throw new Error("offline"); });
  assert.equal(failedPayload.pdfBase64, undefined);

  const oversized = new TextEncoder().encode("%PDF-1.7");
  const oversizedPayload = await runPreprocessorOnPDF(async () => response(oversized, { contentLength: 16 * 1024 * 1024 }));
  assert.equal(oversizedPayload.pdfBase64, undefined);
});

test("#271: an oversized PDF without a declared length is cut off at the cap", async () => {
  const { stats, response: endless } = endlessPDFResponse();
  const payload = await runPreprocessorOnPDF(async () => endless);

  assert.equal(payload.pdfBase64, undefined);
  assert.equal(stats.cancelled, true);
  assert.equal(stats.arrayBufferCalled, false);
  assert.ok(stats.chunksRead <= 17, `read ${stats.chunksRead} MB before stopping`);
});

test("#271: a rejected answer releases its body without reading it", async () => {
  const failed = endlessPDFResponse({ ok: false });
  const failedPayload = await runPreprocessorOnPDF(async () => failed.response);
  assert.equal(failedPayload.pdfBase64, undefined);
  assert.equal(failed.stats.cancelled, true);
  assert.equal(failed.stats.arrayBufferCalled, false);

  const declared = endlessPDFResponse();
  declared.response.headers = { get: (name) => (name.toLowerCase() === "content-length" ? String(16 * 1024 * 1024) : null) };
  const declaredPayload = await runPreprocessorOnPDF(async () => declared.response);
  assert.equal(declaredPayload.pdfBase64, undefined);
  assert.equal(declared.stats.cancelled, true);
});

test("#271: a web page share never fetches its page again", async () => {
  const preprocessorSource = fs.readFileSync(
    "App/SpokenMarginsShareExtension/Resources/SourceLinkPreprocessor.js",
    "utf8"
  );
  let fetched = false;
  const context = {
    console,
    fetch: async () => { fetched = true; return response(new Uint8Array()); },
    btoa,
    document: {
      URL: "https://example.com/article",
      contentType: "text/html",
      title: "Article",
      body: null,
      querySelector: () => null
    },
    window: { location: { href: "https://example.com/article" } }
  };
  vm.runInNewContext(preprocessorSource, context);
  let payload;
  context.ExtensionPreprocessingJS.run({ completionFunction: (value) => { payload = value; } });

  assert.equal(payload.isPDFDocument, false);
  assert.equal(payload.pdfBase64, undefined);
  assert.equal(fetched, false);
});

const preprocessorPath = "App/SpokenMarginsShareExtension/Resources/SourceLinkPreprocessor.js";

test("Safari preprocessor hands over an article page as Markdown with its source details", () => {
  const prose = "<p>" + "Useful article prose. ".repeat(40) + "</p>";
  const page = browserLikePage({
    url: "https://example.com/guide",
    head: `<title>Retirement Guide</title><meta name="author" content="A. Writer">
      <meta property="article:published_time" content="2026-09-01">
      <link rel="canonical" href="https://example.com/canonical">`,
    body: `<nav>Navigation noise</nav><article><h2>First section</h2>${prose}
      <h3>Second section</h3>${prose}</article><footer>Footer noise</footer>`
  });
  Object.defineProperty(page, "contentType", { value: "text/html" });
  const context = {
    console,
    URL,
    document: page,
    window: { location: { href: "https://example.com/guide?utm_source=newsletter" } }
  };
  vm.runInNewContext(fs.readFileSync(preprocessorPath, "utf8"), context);
  let payload;
  context.ExtensionPreprocessingJS.run({ completionFunction: (value) => { payload = JSON.parse(JSON.stringify(value)); } });

  const { markdown, ...rest } = payload;
  assert.deepEqual(rest, {
    url: "https://example.com/guide?utm_source=newsletter",
    documentURL: "https://example.com/guide",
    canonicalURL: "https://example.com/canonical",
    contentType: "text/html",
    isPDFDocument: false,
    title: "Retirement Guide",
    author: "A. Writer",
    publishedAt: "2026-09-01",
    contentFormat: "markdown",
    extractor: "defuddle",
    extractorVersion: "0.19.5",
    networkFallback: false
  });
  assert.match(markdown, /^## First section\n\nUseful article prose\./);
  assert.match(markdown, /\n\n### Second section\n\nUseful article prose\./);
  assert.doesNotMatch(markdown, /Navigation noise|Footer noise/);
});

// Timers that record themselves instead of running; the handle is the record,
// since the page code treats a falsy handle as "no timer".
function fakeTimers(timers) {
  return {
    setTimeout: (callback, milliseconds) => {
      const timer = { callback, milliseconds, cleared: false };
      timers.push(timer);
      return timer;
    },
    clearTimeout: (timer) => { timer.cleared = true; }
  };
}

// A PDF fetch that never answers must not hold the share sheet open: the
// preprocessor aborts it after eight seconds and hands over the link alone.
function runPreprocessorWithHungFetch() {
  const pdfURL = "https://example.com/slow.pdf";
  const timers = [];
  const seen = {};
  const context = {
    console,
    btoa,
    AbortController,
    ...fakeTimers(timers),
    fetch: (_url, options) => new Promise((_resolve, reject) => {
      seen.signal = options.signal;
      options.signal.addEventListener("abort", () => reject(new Error("aborted")));
    }),
    document: { URL: pdfURL, contentType: "application/pdf", title: "slow.pdf", body: null, querySelector: () => null },
    window: { location: { href: pdfURL } }
  };
  vm.runInNewContext(fs.readFileSync(preprocessorPath, "utf8"), context);
  const done = new Promise((resolve) => context.ExtensionPreprocessingJS.run({ completionFunction: resolve }));
  return { pdfURL, timers, seen, done };
}

test("#271: a PDF fetch that never answers is aborted after eight seconds and the link still goes through", async () => {
  const { pdfURL, timers, seen, done } = runPreprocessorWithHungFetch();

  assert.equal(timers.length, 1, "the fetch has no timeout");
  assert.equal(timers[0].milliseconds, 8000);
  assert.ok(seen.signal, "the fetch is not given an abort signal");
  assert.equal(seen.signal.aborted, false);
  timers[0].callback();
  assert.equal(seen.signal.aborted, true);

  const payload = await done;
  assert.equal(payload.isPDFDocument, true);
  assert.equal(payload.documentURL, pdfURL);
  assert.equal(payload.pdfBase64, undefined);
  assert.equal(timers[0].cleared, true, "the timeout is left running after the fetch ended");
});

test("#271: the abort timeout is cancelled once the PDF has arrived", async () => {
  const timers = [];
  const bytes = new TextEncoder().encode("%PDF-1.7 small");
  const pdfURL = "https://example.com/quick.pdf";
  const context = {
    console,
    btoa,
    AbortController,
    ...fakeTimers(timers),
    fetch: async () => response(bytes),
    document: { URL: pdfURL, contentType: "application/pdf", title: "quick.pdf", body: null, querySelector: () => null },
    window: { location: { href: pdfURL } }
  };
  vm.runInNewContext(fs.readFileSync(preprocessorPath, "utf8"), context);
  const payload = await new Promise((resolve) => context.ExtensionPreprocessingJS.run({ completionFunction: resolve }));

  assert.equal(Buffer.from(payload.pdfBase64, "base64").toString("latin1"), "%PDF-1.7 small");
  assert.equal(timers.length, 1);
  assert.equal(timers[0].cleared, true);
});

function captureJournalPage(options) {
  const document = browserLikePage({
    url: "https://example.com/series/1/essay",
    head: "<title>A Placeholder Essay</title>",
    body: journalArticleBody(options)
  });
  const payload = withGlobalDocument(document, () =>
    captureReadablePage({ crypto: { randomUUID: () => "test-id" }, navigator: {} }, document)
  );
  return { document, payload };
}

// #796: e-flux keeps the essay in "article__body article__body--with-ad". Defuddle
// strips any element whose class ends in "-ad" as an advertisement, so the essay
// went and the capture began at "Notes" with the footnotes.
test("readable capture of a journal page whose body class ends in -ad starts with the essay and keeps its section headings in order", () => {
  const { payload } = captureJournalPage();

  assert.equal(payload.metadata.extractor, "defuddle");
  assert.match(payload.text, /^This is sentence 1 of a paragraph about the opening argument/);
  const headings = payload.text.split("\n").filter(line => /^## /.test(line)).map(line => line.slice(3));
  assert.deepEqual(headings, JOURNAL_SECTIONS);
  // The footnotes follow the body; they do not replace it.
  const notes = payload.text.indexOf("\nNotes\n");
  assert.ok(notes > payload.text.lastIndexOf(`## ${JOURNAL_SECTIONS.at(-1)}`), "the notes come after the last section");
  assert.ok(!payload.text.split("\n").some(line => /^#+\s*Notes\s*$/.test(line)));
  assert.ok(!payload.text.split("\n").some(line => line.includes(JOURNAL_BYLINE) && /^#/.test(line)), "the byline is not a heading");
  // The Category and Subject labels are lower-level headings the chapter step ignores
  // (ChapterCorpusScorerTests, journal-footnotes-block); none is a section heading.
  assert.deepEqual(payload.text.split("\n").filter(line => /^#{1,3}\s/.test(line)).length, JOURNAL_SECTIONS.length);
  assert.ok(payload.text.length > 8000, `the whole essay is there (${payload.text.length} characters)`);
});

test("the journal fixture's capture is the Markdown the chapter corpus checks (Contracts/fixtures/chapters)", () => {
  const { payload } = captureJournalPage();
  const committed = fs.readFileSync(
    new URL("../../Contracts/fixtures/chapters/journal-footnotes-block.md", import.meta.url), "utf8"
  );
  assert.equal(payload.text + "\n", committed, "regenerate the fixture if the capture changed on purpose");
});

test("capturing a page leaves its class and id names as the publisher wrote them", () => {
  const body = `<article id="story-ad"><div class="ad-body wide"><h2>Heading</h2>${articleProse}${articleProse}${articleProse}</div></article>`;
  const document = browserLikePage({ head: "<title>Names</title>", body });
  const before = document.documentElement.outerHTML;
  withGlobalDocument(document, () =>
    captureReadablePage({ crypto: { randomUUID: () => "test-id" }, navigator: {} }, document)
  );
  assert.equal(document.documentElement.outerHTML, before);
});

test("ad-looking names on article bodies are neighbours of the e-flux case; real ad blocks still go", () => {
  const advertisement = "<aside class=\"%CLASS%\"><p>Buy a placeholder subscription today and save on placeholder offers.</p></aside>";
  const wide = `<h2>Section</h2>${articleProse}${articleProse}${articleProse}`;
  const contains = (payload, text) => payload.text.includes(text);
  // Something has to be left when the wrapper is dropped, or Defuddle gives up and the
  // semantic fallback reads the essay anyway and hides the bug.
  const capture = (wrapper) => {
    const document = browserLikePage({
      head: "<title>Names</title>",
      body: `<article><h1>Title</h1>${wrapper}<div class="footnotes"><p>Placeholder footnote text, long enough to be kept.</p></div></article>`
    });
    const payload = withGlobalDocument(document, () =>
      captureReadablePage({ crypto: { randomUUID: () => "test-id" }, navigator: {} }, document)
    );
    assert.equal(payload.metadata.extractor, "defuddle");
    return payload;
  };
  const essay = "Useful article prose.";

  // Essay containers named like an ad: the essay stays.
  for (const attributes of [
    'class="article__body article__body--with-ad"',   // e-flux
    'class="body-ad"',                                // the whole name ends in -ad
    'class="ad-body"',                                // starts with ad-
    'class="AD-BODY"',                                // case does not matter
    'class="story Story--With-AD"',
    'id="story-ad"',                                  // ids are tested the same way
    'id="ad-story"',
    'class="x-ad" id="y-ad"',                         // both attributes at once
    'class="ad-story-ad"'                             // starts and ends like an ad
  ]) {
    const payload = capture(`<div ${attributes}>${wide}</div>`);
    assert.ok(contains(payload, essay), `${attributes} keeps the essay`);
    assert.ok(contains(payload, "## Section"), `${attributes} keeps the heading`);
  }

  // Names that only look similar were never touched.
  for (const attributes of ['class="bread"', 'class="reader"', 'class="download-area"', 'class="headline-body"']) {
    const payload = capture(`<div ${attributes}>${wide}</div>`);
    assert.ok(contains(payload, essay), `${attributes} is plain content`);
  }

  // A real ad block, however it is named, is short and has no body paragraphs: still removed.
  for (const name of ["ad-slot", "sidebar-ad", "top-AD", "ad-"]) {
    const payload = capture(`${advertisement.replace("%CLASS%", name)}${articleProse}${articleProse}`);
    assert.ok(!contains(payload, "Buy a placeholder subscription"), `${name} is still dropped`);
    assert.ok(contains(payload, essay), `${name} leaves the essay`);
  }

  // A long text with few paragraphs is not prose enough to protect: a promo that rambles stays dropped.
  const promo = `<div class="promo-ad"><p>${"Sponsored placeholder words. ".repeat(60)}</p></div>`;
  assert.ok(!contains(capture(`${promo}${articleProse}${articleProse}`), "Sponsored placeholder words."));
});

// The app ships the built scripts, and the tests above that import the
// sources never see them. A source edit with no rebuild would otherwise pass.
test("every shipped script is exactly what its source builds to", async () => {
  for (const configuration of BUNDLES) {
    const result = await build({ ...esbuildOptions(configuration), write: false });
    // build.mjs strips trailing whitespace from each line after bundling.
    const built = result.outputFiles[0].text.split("\n").map((line) => line.replace(/[ \t]+$/g, "")).join("\n");
    const shipped = fs.readFileSync(configuration.outfile, "utf8");
    assert.ok(shipped === built, `${configuration.outfile} is stale; run npm run build:browser-extraction`);
  }
});
