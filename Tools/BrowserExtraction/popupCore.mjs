export async function activeTab(extensionAPI) {
  const tabs = await extensionAPI.tabs.query({ active: true, currentWindow: true });
  if (!tabs.length || tabs[0].id === undefined) {
    throw new Error("No active Safari tab is available.");
  }
  return tabs[0];
}

export function invokeInjectedCapture(action) {
  try {
    const capture = globalThis.SpokenMarginsBrowserTextCapture;
    if (!capture) {
      return { ok: false, error: "The page capture script did not initialize." };
    }
    const captureFunction = action === "captureSelectedText"
      ? capture.captureSelectedText
      : action === "captureReadablePage"
        ? capture.captureReadablePage
        : null;
    if (typeof captureFunction !== "function") {
      return { ok: false, error: "The requested page capture action is unavailable." };
    }
    const payload = captureFunction(globalThis.document);
    return payload
      ? { ok: true, payload }
      : { ok: false, error: "The page capture returned no content." };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : String(error)
    };
  }
}

export async function capturePageText(extensionAPI, action) {
  const tab = await activeTab(extensionAPI);
  const target = { tabId: tab.id };
  try {
    await extensionAPI.scripting.executeScript({
      target,
      files: ["browserTextCapture.js"]
    });
  } catch (error) {
    throw new Error(`Safari could not access this page: ${error instanceof Error ? error.message : String(error)}`);
  }

  let results;
  try {
    results = await extensionAPI.scripting.executeScript({
      target,
      func: invokeInjectedCapture,
      args: [action]
    });
  } catch (error) {
    throw new Error(`Safari could not run page capture: ${error instanceof Error ? error.message : String(error)}`);
  }

  const response = results?.find((entry) => entry.frameId === 0)?.result
    || results?.[0]?.result;
  if (!response || !response.ok || !response.payload) {
    throw new Error(response?.error || "The page capture returned no result.");
  }
  return response.payload;
}

export async function storePayload(extensionAPI, nativeApplicationID, payload) {
  const response = await extensionAPI.runtime.sendNativeMessage(nativeApplicationID, {
    action: "storeBrowserTextPayload",
    payload
  });
  if (!response || !response.ok || !response.openURL) {
    throw new Error(response?.error || "Unable to store browser text payload.");
  }
  return response.openURL;
}

export async function openNativeApp(extensionAPI, openURL) {
  const tab = await activeTab(extensionAPI);
  await extensionAPI.tabs.update(tab.id, { url: openURL });
}
