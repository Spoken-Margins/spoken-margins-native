export async function activeTab(extensionAPI) {
  const tabs = await extensionAPI.tabs.query({ active: true, currentWindow: true });
  if (!tabs.length || tabs[0].id === undefined) {
    throw new Error("No active Safari tab is available.");
  }
  return tabs[0];
}

// Runs in the page, so it must not reference anything outside its own body.
// On a PDF, Safari's tab document is its built-in PDF viewer, whose only text
// is the viewer's own CSS (#658). Hand back the PDF's address instead.
export function invokeInjectedCapture() {
  try {
    const documentRef = globalThis.document;
    const href = String(documentRef?.location?.href || documentRef?.URL || "");
    let path = "";
    try { path = new URL(href).pathname; } catch { path = ""; }
    const isPDF = String(documentRef?.contentType || "").toLowerCase() === "application/pdf"
      || /\.pdf$/i.test(path)
      || Boolean(documentRef?.querySelector?.('embed[type="application/pdf"], #annotationContainer'));
    if (isPDF && /^https:\/\//i.test(href)) {
      return { ok: true, pdfURL: href };
    }
    const capture = globalThis.SpokenMarginsBrowserTextCapture;
    if (!capture) {
      return { ok: false, error: "The page capture script did not initialize." };
    }
    const captureFunction = capture.captureReadablePage;
    if (typeof captureFunction !== "function") {
      return { ok: false, error: "The requested page capture action is unavailable." };
    }
    const payload = captureFunction(documentRef);
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

// Safari refuses scripting.executeScript on a tab the extension has no access
// to, such as a PDF opened straight in Safari (#1143). Trying again can't help,
// so the popup shows this error without Try Again.
export class TabAccessError extends Error {
  constructor(message) {
    super(message);
    this.name = "TabAccessError";
    this.retryable = false;
  }
}

export function canRetry(error) {
  return !(error instanceof TabAccessError);
}

// Safari words it "Invalid call to scripting.executeScript(). This extension
// does not have access to this tab." The "Invalid call" prefix alone also covers
// other reasons (no such tab, a bad target) that Try Again may fix, so match the
// no-access sentence only.
const TAB_ACCESS_REFUSAL = /does not have access to this tab/i;

function isTabAccessRefusal(error) {
  const message = typeof error?.message === "string" ? error.message : String(error);
  return TAB_ACCESS_REFUSAL.test(message);
}

// The PDF import takes https addresses only, and a PDF's path ends in .pdf.
function pdfPathAddress(address) {
  if (typeof address !== "string") { return null; }
  let url;
  try { url = new URL(address.trim()); } catch { return null; }
  return /\.pdf$/i.test(url.pathname) ? url : null;
}

// Safari won't run the capture script here, but the tab's own address may
// still say it is a PDF, which the app can fetch without the page.
function recoverFromRefusedTab(tab) {
  const pdf = pdfPathAddress(tab.url);
  if (pdf?.protocol === "https:" && pdf.host) {
    return { pdfURL: pdf.href };
  }
  throw new TabAccessError(
    `Can’t import this ${pdf ? "PDF" : "page"} from the Safari extension. Tap Share in Safari and choose Spoken Margins.`
  );
}

// Returns { payload } for page text, or { pdfURL } when the tab shows a PDF.
export async function capturePage(extensionAPI) {
  const tab = await activeTab(extensionAPI);
  const target = { tabId: tab.id };
  try {
    await extensionAPI.scripting.executeScript({
      target,
      files: ["browserTextCapture.js"]
    });
  } catch (error) {
    if (isTabAccessRefusal(error)) { return recoverFromRefusedTab(tab); }
    throw new Error(`Safari could not access this page: ${error instanceof Error ? error.message : String(error)}`);
  }

  let results;
  try {
    results = await extensionAPI.scripting.executeScript({
      target,
      func: invokeInjectedCapture,
      args: []
    });
  } catch (error) {
    if (isTabAccessRefusal(error)) { return recoverFromRefusedTab(tab); }
    throw new Error(`Safari could not run page capture: ${error instanceof Error ? error.message : String(error)}`);
  }

  const response = results?.find((entry) => entry.frameId === 0)?.result
    || results?.[0]?.result;
  if (response?.ok && response.pdfURL) {
    return { pdfURL: response.pdfURL };
  }
  if (!response || !response.ok || !response.payload) {
    throw new Error(response?.error || "The page capture returned no result.");
  }
  return { payload: response.payload };
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

export async function storeRemotePDF(extensionAPI, nativeApplicationID, url) {
  const response = await extensionAPI.runtime.sendNativeMessage(nativeApplicationID, {
    action: "storeRemotePDFHandoff",
    url
  });
  if (!response || !response.ok || !response.openURL) {
    throw new Error(response?.error || "Unable to send this PDF to Spoken Margins.");
  }
  return response.openURL;
}

export async function openNativeApp(extensionAPI, openURL) {
  const tab = await activeTab(extensionAPI);
  await extensionAPI.tabs.update(tab.id, { url: openURL });
}
