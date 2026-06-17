import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

function element(tagName, textContent = "", children = []) {
  return {
    tagName,
    textContent,
    children,
    attributes: {},
    cloneNode() {
      return element(tagName, textContent, children.map((child) => child.cloneNode(true)));
    },
    querySelectorAll(selector) {
      const tags = selector.split(",").map((entry) => entry.trim());
      return children.filter((child) => tags.includes(child.tagName));
    },
    remove() {
      this.textContent = "";
      this.children = [];
    }
  };
}

function loadCapture(documentRef) {
  const source = fs.readFileSync("App/SpokenMarginsBrowserTextExtension/Resources/Scripts/browserTextCapture.js", "utf8");
  const context = {
    document: documentRef,
    navigator: { userAgent: "test" },
    crypto: { randomUUID: () => "test-payload-id" },
    Date,
    Error
  };
  context.globalThis = context;
  vm.createContext(context);
  vm.runInContext(source, context);
  return context.SpokenMarginsBrowserTextCapture;
}

test("selected text capture preserves page metadata", () => {
  const documentRef = {
    title: "Fallback Title",
    location: { href: "https://example.com/selected" },
    getSelection: () => ({ toString: () => "  Selected\n\npage text. " }),
    querySelector: (selector) => {
      if (selector === "meta[property='og:title']") {
        return { getAttribute: () => "Article Title" };
      }
      if (selector === "meta[name='author']") {
        return { getAttribute: () => "A. Writer" };
      }
      return null;
    }
  };

  const capture = loadCapture(documentRef);
  const payload = capture.captureSelectedText(documentRef);

  assert.equal(payload.id, "test-payload-id");
  assert.equal(payload.captureMode, "selected_text");
  assert.equal(payload.text, "Selected page text.");
  assert.equal(payload.source.title, "Article Title");
  assert.equal(payload.source.url, "https://example.com/selected");
  assert.equal(payload.source.author, "A. Writer");
  assert.equal(payload.requestedContinuation.startSession, true);
});

test("readable page capture prefers article text and excludes page chrome", () => {
  const articleText = "Opening paragraph. ".repeat(20);
  const article = element("article", articleText, [element("nav", "Navigation should disappear.")]);
  const body = element("body", `${articleText} Footer noise.`);
  const documentRef = {
    title: "Readable Page",
    location: { href: "https://example.com/readable" },
    body,
    querySelector: (selector) => selector === "article" ? article : null,
    querySelectorAll: () => [article, body]
  };

  const capture = loadCapture(documentRef);
  const payload = capture.captureReadablePage(documentRef);

  assert.equal(payload.captureMode, "readable_page");
  assert.match(payload.text, /Opening paragraph/);
  assert.doesNotMatch(payload.text, /Navigation should disappear/);
  assert.doesNotMatch(payload.text, /Footer noise/);
});
