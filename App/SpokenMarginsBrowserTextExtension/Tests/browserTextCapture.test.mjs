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

test("popup and manifest reference flattened bundled resources", () => {
  const manifest = JSON.parse(fs.readFileSync("App/SpokenMarginsBrowserTextExtension/Resources/manifest.json", "utf8"));
  const popup = fs.readFileSync("App/SpokenMarginsBrowserTextExtension/Resources/popup.html", "utf8");
  const styles = fs.readFileSync("App/SpokenMarginsBrowserTextExtension/Resources/Styles/popup.css", "utf8");

  assert.deepEqual(manifest.content_scripts[0].js, ["browserTextCapture.js"]);
  assert.match(popup, /href="popup\.css"/);
  assert.match(popup, /src="popup\.js"/);
  assert.doesNotMatch(popup, /Styles\/popup\.css|Scripts\/popup\.js/);
  assert.match(styles, /width:\s*176px/);
  assert.match(styles, /min-height:\s*36px/);
});

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
  assert.equal(payload.contentFormat, "plain_text");
  assert.equal(payload.text, "Selected page text.");
  assert.equal(payload.source.title, "Article Title");
  assert.equal(payload.source.url, "https://example.com/selected");
  assert.equal(payload.source.author, "A. Writer");
  assert.equal(payload.requestedContinuation.startSession, false);
});

test("readable page bundle contains the pinned local extractor", () => {
  const source = fs.readFileSync("App/SpokenMarginsBrowserTextExtension/Resources/Scripts/browserTextCapture.js", "utf8");
  const license = fs.readFileSync("App/SpokenMarginsBrowserTextExtension/Resources/Defuddle-LICENSE.txt", "utf8");

  assert.match(source, /Bundled Defuddle 0\.19\.1/);
  assert.match(source, /networkFallback/);
  assert.match(license, /Copyright \(c\) 2025 Steph Ango/);
});
