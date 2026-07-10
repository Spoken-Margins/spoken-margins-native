(function attachSpokenMarginsBrowserTextCapture(global) {
  "use strict";

  const extensionAPI = global.browser || global.chrome;

  function normalizeWhitespace(text) {
    return String(text || "").replace(/\s+/g, " ").trim();
  }

  function metaContent(documentRef, selectors) {
    for (const selector of selectors) {
      const node = documentRef.querySelector(selector);
      const value = node && (node.getAttribute("content") || node.getAttribute("datetime"));
      if (value && normalizeWhitespace(value)) {
        return normalizeWhitespace(value);
      }
    }
    return null;
  }

  function pageTitle(documentRef) {
    return metaContent(documentRef, [
      "meta[property='og:title']",
      "meta[name='twitter:title']"
    ]) || normalizeWhitespace(documentRef.title) || normalizeWhitespace(documentRef.querySelector("h1") && documentRef.querySelector("h1").textContent) || "Browser Text";
  }

  function sourceMetadata(documentRef) {
    return {
      url: documentRef.location ? documentRef.location.href : "",
      title: pageTitle(documentRef),
      author: metaContent(documentRef, [
        "meta[name='author']",
        "meta[property='article:author']",
        "meta[name='byl']"
      ]),
      publishedAt: metaContent(documentRef, [
        "meta[property='article:published_time']",
        "meta[name='date']",
        "meta[name='citation_publication_date']",
        "time[datetime]"
      ])
    };
  }

  function removeChrome(container) {
    const selectors = [
      "script",
      "style",
      "noscript",
      "nav",
      "footer",
      "header",
      "aside",
      "form",
      "button",
      "[aria-hidden='true']",
      "[hidden]"
    ];
    container.querySelectorAll(selectors.join(",")).forEach((node) => node.remove());
    return container;
  }

  function candidateText(node) {
    return normalizeWhitespace(removeChrome(node.cloneNode(true)).textContent);
  }

  function readableCandidate(documentRef) {
    const preferred = [
      "article",
      "main",
      "[role='main']",
      ".article",
      ".post",
      ".entry-content",
      ".content"
    ];
    for (const selector of preferred) {
      const node = documentRef.querySelector(selector);
      if (node && candidateText(node).length >= 180) {
        return node;
      }
    }

    const blocks = Array.from(documentRef.querySelectorAll("article, main, section, div"));
    return blocks
      .map((node) => ({ node, textLength: candidateText(node).length }))
      .filter((candidate) => candidate.textLength >= 180)
      .sort((left, right) => right.textLength - left.textLength)[0]?.node || documentRef.body;
  }

  function buildPayload(documentRef, captureMode, text, selection) {
    const id = global.crypto && typeof global.crypto.randomUUID === "function"
      ? global.crypto.randomUUID()
      : `browser-text-${Date.now()}-${Math.floor(Math.random() * 100000)}`;
    return {
      id,
      schemaVersion: "browser-text-handoff.v1",
      captureMode,
      source: sourceMetadata(documentRef),
      text: normalizeWhitespace(text),
      selection: selection || null,
      requestedContinuation: {
        startSession: false,
        preferredPlaybackOwner: "app"
      },
      createdAt: new Date().toISOString(),
      metadata: {
        userAgent: global.navigator ? global.navigator.userAgent : null
      }
    };
  }

  function captureSelectedText(documentRef) {
    const selection = documentRef.getSelection ? documentRef.getSelection() : global.getSelection();
    const text = normalizeWhitespace(selection ? selection.toString() : "");
    if (!text) {
      throw new Error("Select text on the page before sending selected text.");
    }
    return buildPayload(documentRef, "selected_text", text, null);
  }

  function captureReadablePage(documentRef) {
    const node = readableCandidate(documentRef);
    const text = candidateText(node);
    if (!text) {
      throw new Error("No readable page text was found.");
    }
    return buildPayload(documentRef, "readable_page", text, null);
  }

  function handleMessage(message) {
    if (!message || !message.action) {
      return null;
    }
    if (message.action === "captureSelectedText") {
      return captureSelectedText(global.document);
    }
    if (message.action === "captureReadablePage") {
      return captureReadablePage(global.document);
    }
    return null;
  }

  if (extensionAPI && extensionAPI.runtime && extensionAPI.runtime.onMessage && global.document) {
    extensionAPI.runtime.onMessage.addListener((message, sender, sendResponse) => {
      try {
        const payload = handleMessage(message);
        sendResponse({ ok: true, payload });
      } catch (error) {
        sendResponse({ ok: false, error: error.message });
      }
      return true;
    });
  }

  global.SpokenMarginsBrowserTextCapture = {
    normalizeWhitespace,
    sourceMetadata,
    captureSelectedText,
    captureReadablePage
  };
})(typeof globalThis !== "undefined" ? globalThis : this);
