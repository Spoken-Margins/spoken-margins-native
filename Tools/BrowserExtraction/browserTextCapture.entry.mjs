import {
  captureReadablePage,
  captureSelectedText,
  normalizeWhitespace,
  sourceMetadata
} from "./browserExtractionCore.mjs";

(function attachSpokenMarginsBrowserTextCapture(globalRef) {
  "use strict";
  const extensionAPI = globalRef.browser || globalRef.chrome;

  function handleMessage(message) {
    if (message?.action === "captureSelectedText") {
      return captureSelectedText(globalRef, globalRef.document);
    }
    if (message?.action === "captureReadablePage") {
      return captureReadablePage(globalRef, globalRef.document);
    }
    return null;
  }

  if (extensionAPI?.runtime?.onMessage && globalRef.document) {
    extensionAPI.runtime.onMessage.addListener((message, sender, sendResponse) => {
      try {
        sendResponse({ ok: true, payload: handleMessage(message) });
      } catch (error) {
        sendResponse({ ok: false, error: error.message });
      }
      return true;
    });
  }

  globalRef.SpokenMarginsBrowserTextCapture = {
    normalizeWhitespace,
    sourceMetadata,
    captureSelectedText: (documentRef) => captureSelectedText(globalRef, documentRef),
    captureReadablePage: (documentRef) => captureReadablePage(globalRef, documentRef)
  };
})(globalThis);
