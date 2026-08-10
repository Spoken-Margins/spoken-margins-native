import {
  captureReadablePage,
  normalizeWhitespace,
  sourceMetadata
} from "./browserExtractionCore.mjs";

(function attachSpokenMarginsBrowserTextCapture(globalRef) {
  "use strict";

  globalRef.SpokenMarginsBrowserTextCapture = {
    normalizeWhitespace,
    sourceMetadata,
    captureReadablePage: (documentRef) => captureReadablePage(globalRef, documentRef)
  };
})(globalThis);
