import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";
import { parseHTML } from "linkedom";
import {
  captureReadablePage,
  fallbackReadableMarkdown,
  normalizeSocialEmbedsForReading
} from "./browserExtractionCore.mjs";
import {
  capturePage,
  invokeInjectedCapture
} from "./popupCore.mjs";

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

test("built resources contain the pinned extractor and Safari preprocessor", () => {
  const capture = fs.readFileSync("App/SharedResources/browserTextCapture.js", "utf8");
  const popup = fs.readFileSync("App/SpokenMarginsBrowserTextExtension/Resources/Scripts/popup.js", "utf8");
  const preprocessor = fs.readFileSync("App/SpokenMarginsShareExtension/Resources/SourceLinkPreprocessor.js", "utf8");
  assert.match(capture, /Bundled Defuddle 0\.19\.1/);
  assert.doesNotMatch(capture, /onMessage\.addListener/);
  assert.doesNotMatch(popup, /tabs\.sendMessage/);
  assert.match(popup, /scripting\.executeScript/);
  assert.match(preprocessor, /Bundled Defuddle 0\.19\.1/);
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
    arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
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
