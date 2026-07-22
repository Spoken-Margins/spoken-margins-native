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
  const selectedTextButton = globalRef.document.getElementById("selectedTextButton");
  const readablePageButton = globalRef.document.getElementById("readablePageButton");

  function setStatus(message) {
    status.textContent = message || "";
  }

  async function run(action) {
    selectedTextButton.disabled = true;
    readablePageButton.disabled = true;
    setStatus("Sending to Spoken Margins...");
    try {
      const payload = await capturePageText(extensionAPI, action);
      const openURL = await storePayload(extensionAPI, nativeApplicationID, payload);
      await openNativeApp(extensionAPI, openURL);
      setStatus("Opening Spoken Margins.");
    } catch (error) {
      setStatus(error instanceof Error ? error.message : String(error));
      selectedTextButton.disabled = false;
      readablePageButton.disabled = false;
    }
  }

  selectedTextButton.addEventListener("click", () => { void run("captureSelectedText"); });
  readablePageButton.addEventListener("click", () => { void run("captureReadablePage"); });
})(globalThis);
