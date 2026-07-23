import {
  captureReadablePage,
  captureSelectedText,
  normalizeWhitespace,
  sourceMetadata
} from "./browserExtractionCore.mjs";

(function attachSpokenMarginsBrowserTextCapture(globalRef) {
  "use strict";

  globalRef.SpokenMarginsBrowserTextCapture = {
    normalizeWhitespace,
    sourceMetadata,
    captureSelectedText: (documentRef) => captureSelectedText(globalRef, documentRef),
    captureReadablePage: (documentRef) => captureReadablePage(globalRef, documentRef)
  };
})(globalThis);
