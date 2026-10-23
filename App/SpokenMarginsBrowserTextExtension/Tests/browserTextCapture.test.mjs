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

  assert.ok(manifest.permissions.includes("activeTab"));
  assert.ok(manifest.permissions.includes("scripting"));
  assert.equal(manifest.action.default_popup, "popup.html");
  assert.deepEqual(Object.keys(manifest.icons), ["48", "96", "128", "256", "512"]);
  for (const [size, icon] of Object.entries(manifest.icons)) {
    assert.match(size, /^\d+$/);
    assert.equal(typeof icon, "string");
    assert.ok(fs.existsSync(`App/SpokenMarginsBrowserTextExtension/Resources/Icons/${icon}`));
  }
  assert.match(popup, /href="popup\.css"/);
  assert.match(popup, /src="popup\.js"/);
  assert.doesNotMatch(popup, /Styles\/popup\.css|Scripts\/popup\.js/);
  assert.match(styles, /width:\s*214px/);
  assert.match(styles, /min-height:\s*32px/);
  assert.doesNotMatch(popup, /selectedTextButton|Selected Text/);
  assert.match(popup, /Adding this page/);
});

function loadCapture(documentRef) {
  const source = fs.readFileSync("App/SharedResources/browserTextCapture.js", "utf8");
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

test("readable page bundle contains the pinned local extractor", () => {
  const source = fs.readFileSync("App/SharedResources/browserTextCapture.js", "utf8");
  const license = fs.readFileSync("App/SharedResources/Defuddle-LICENSE.txt", "utf8");

  assert.match(source, /Bundled Defuddle 0\.19\.5/);
  assert.match(source, /networkFallback/);
  assert.doesNotMatch(source, /captureSelectedText/);
  assert.match(license, /Copyright \(c\) 2025 Steph Ango/);
});
