import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import { parseHTML } from "linkedom";

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

test("Defuddle capture emits local Markdown with headings", async () => {
  const document = articleDocument();
  const { captureReadablePage } = await import("./browserExtractionCore.mjs");
  const payload = captureReadablePage({ crypto: { randomUUID: () => "test-id" }, navigator: {} }, document);

  assert.equal(payload.captureMode, "readable_page");
  assert.equal(payload.contentFormat, "markdown");
  assert.equal(payload.metadata.extractorVersion, "0.19.1");
  assert.equal(payload.metadata.networkFallback, false);
  assert.match(payload.text, /## First section/i);
  assert.match(payload.text, /### Second section/i);
  assert.doesNotMatch(payload.text, /Navigation noise|Footer noise/);
});

test("built resources contain the pinned extractor and Safari preprocessor", () => {
  const capture = fs.readFileSync("App/SpokenMarginsBrowserTextExtension/Resources/Scripts/browserTextCapture.js", "utf8");
  const preprocessor = fs.readFileSync("App/SpokenMarginsShareExtension/Resources/SourceLinkPreprocessor.js", "utf8");
  assert.match(capture, /Bundled Defuddle 0\.19\.1/);
  assert.match(preprocessor, /Bundled Defuddle 0\.19\.1/);
  assert.match(preprocessor, /SourceLinkPreprocessor/);
  assert.match(preprocessor, /plain_text/);
});
