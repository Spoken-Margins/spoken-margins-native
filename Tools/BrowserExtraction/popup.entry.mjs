import {
  capturePageText,
  openNativeApp,
  storePayload
} from "./popupCore.mjs";

(function attachSpokenMarginsPopup(globalRef) {
  "use strict";

  const extensionAPI = globalRef.browser || globalRef.chrome;
  const nativeApplicationID = "com.spokenmargins.native.browsertext";
  const status = globalRef.document.getElementById("status");
  const readablePageButton = globalRef.document.getElementById("readablePageButton");

  function setStatus(message) {
    status.textContent = message || "";
  }

  async function run() {
    readablePageButton.disabled = true;
    readablePageButton.hidden = true;
    setStatus("Sending to Spoken Margins...");
    try {
      const payload = await capturePageText(extensionAPI);
      const openURL = await storePayload(extensionAPI, nativeApplicationID, payload);
      await openNativeApp(extensionAPI, openURL);
      setStatus("Opening Spoken Margins.");
    } catch (error) {
      setStatus(error instanceof Error ? error.message : String(error));
      readablePageButton.disabled = false;
      readablePageButton.hidden = false;
    }
  }

  readablePageButton.addEventListener("click", () => { void run(); });
  void run();
})(globalThis);
