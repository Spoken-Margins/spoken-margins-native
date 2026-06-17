(function attachSpokenMarginsPopup() {
  "use strict";

  const extensionAPI = typeof browser !== "undefined" ? browser : chrome;
  const nativeApplicationID = "com.spokenmargins.native.browsertext";
  const status = document.getElementById("status");
  const selectedTextButton = document.getElementById("selectedTextButton");
  const readablePageButton = document.getElementById("readablePageButton");

  function setStatus(message) {
    status.textContent = message || "";
  }

  async function activeTab() {
    const tabs = await extensionAPI.tabs.query({ active: true, currentWindow: true });
    if (!tabs.length || tabs[0].id === undefined) {
      throw new Error("No active Safari tab is available.");
    }
    return tabs[0];
  }

  async function capture(action) {
    const tab = await activeTab();
    const response = await extensionAPI.tabs.sendMessage(tab.id, { action });
    if (!response || !response.ok || !response.payload) {
      throw new Error((response && response.error) || "Unable to capture page text.");
    }
    return response.payload;
  }

  async function storePayload(payload) {
    const response = await extensionAPI.runtime.sendNativeMessage(nativeApplicationID, {
      action: "storeBrowserTextPayload",
      payload
    });
    if (!response || !response.ok || !response.openURL) {
      throw new Error((response && response.error) || "Unable to store browser text payload.");
    }
    return response.openURL;
  }

  async function openNativeApp(openURL) {
    const tab = await activeTab();
    await extensionAPI.tabs.update(tab.id, { url: openURL });
  }

  async function run(action) {
    selectedTextButton.disabled = true;
    readablePageButton.disabled = true;
    setStatus("Sending to Spoken Margins...");
    try {
      const payload = await capture(action);
      const openURL = await storePayload(payload);
      await openNativeApp(openURL);
      setStatus("Opening Spoken Margins.");
    } catch (error) {
      setStatus(error.message);
      selectedTextButton.disabled = false;
      readablePageButton.disabled = false;
    }
  }

  selectedTextButton.addEventListener("click", () => run("captureSelectedText"));
  readablePageButton.addEventListener("click", () => run("captureReadablePage"));
})();
