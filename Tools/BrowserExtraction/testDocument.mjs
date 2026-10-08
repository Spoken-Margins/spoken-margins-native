import { parseHTML } from "linkedom";

// Test support, not shipped. Defuddle finds the article in a linkedom page
// without help, but its Markdown step (Turndown) calls
// document.implementation.createHTMLDocument(...) on the global document and
// linkedom has no such thing, so on a bare linkedom page extraction always
// ends in "Partial conversion completed with errors" and the capture code
// takes its fallback branch. This gives a linkedom document the one missing
// piece, backed by linkedom itself, so the real extractor runs to the end.
function createHTMLDocument() {
  let current = parseHTML("<!doctype html><html><body></body></html>").document;
  return {
    open() {},
    close() {},
    write(html) {
      current = parseHTML(`<!doctype html><html><body>${html}</body></html>`).document;
    },
    getElementById: (id) => current.getElementById(id)
  };
}

export function withHTMLImplementation(document) {
  Object.defineProperty(document, "implementation", {
    value: { createHTMLDocument },
    configurable: true
  });
  return document;
}

// A page the way Safari would hand it over: address, title and article, built
// with linkedom plus the implementation above. `head` and `body` are HTML.
export function browserLikePage({ url = "https://example.com/guide", head = "", body = "" } = {}) {
  const { document } = parseHTML(`<!doctype html><html><head>${head}</head><body>${body}</body></html>`);
  Object.defineProperty(document, "location", { value: { href: url } });
  Object.defineProperty(document, "URL", { value: url });
  return withHTMLImplementation(document);
}
