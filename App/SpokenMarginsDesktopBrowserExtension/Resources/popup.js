const browserAPI = globalThis.browser || globalThis.chrome;
const button = document.getElementById("listenButton");
const status = document.getElementById("status");
button.addEventListener("click", async () => {
  button.disabled = true;
  status.textContent = "Reading page…";
  try {
    const [tab] = await browserAPI.tabs.query({ active: true, currentWindow: true });
    if (!tab?.id) throw new Error("No active page is available.");
    await browserAPI.scripting.executeScript({ target: { tabId: tab.id }, files: ["browserTextCapture.js"] });
    const results = await browserAPI.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => globalThis.SpokenMarginsBrowserTextCapture?.captureReadablePage(globalThis.document)
    });
    const payload = results?.[0]?.result;
    if (!payload) throw new Error("This page has no readable text, or Safari denied access.");
    const response = await browserAPI.runtime.sendNativeMessage("com.spokenmargins.desktop.browser", {
      action: "storeBrowserTextPayload", payload
    });
    if (!response?.ok || !response.openURL) throw new Error(response?.error || "Desktop handoff failed.");
    await browserAPI.tabs.create({ url: response.openURL, active: true });
    status.textContent = "Opening Spoken Margins…";
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
    button.disabled = false;
  }
});
