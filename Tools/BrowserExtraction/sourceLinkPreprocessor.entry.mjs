import { extractReadableMarkdown, sourceMetadata } from "./browserExtractionCore.mjs";

// #271: Safari has the PDF it is showing, but a fresh download of the same link can
// return something else (PubMed Central answers with an HTML "Preparing to download" page).
// Read the bytes from inside the page, with its cookies, and hand them to the extension.
// Over the cap, or on any error, the payload carries only the link, as before.
const maximumPagePDFBytes = 15 * 1024 * 1024;
const pagePDFTimeoutMs = 8000;

function hasPDFSignature(bytes) {
  const signature = [0x25, 0x50, 0x44, 0x46, 0x2d]; // "%PDF-"
  const limit = Math.min(bytes.length - signature.length, 1024);
  for (let start = 0; start <= limit; start += 1) {
    if (signature.every((value, offset) => bytes[start + offset] === value)) return true;
  }
  return false;
}

function base64FromBytes(bytes) {
  let binary = "";
  const chunkSize = 0x8000;
  for (let start = 0; start < bytes.length; start += chunkSize) {
    binary += String.fromCharCode.apply(null, bytes.subarray(start, start + chunkSize));
  }
  return btoa(binary);
}

function cancelQuietly(stream) {
  try {
    stream?.cancel?.()?.catch?.(() => {});
  } catch {
    // Already closed or locked: nothing left to release.
  }
}

// Reads at most the cap, so an oversized or endless answer never fills the page's memory.
async function boundedBody(response) {
  const body = response.body;
  if (!body || typeof body.getReader !== "function") {
    // No stream to count while reading: trust only a declared length under the cap.
    const declaredLength = Number(response.headers?.get?.("content-length") || 0);
    if (declaredLength <= 0 || declaredLength > maximumPagePDFBytes) return null;
    const bytes = new Uint8Array(await response.arrayBuffer());
    return bytes.length > maximumPagePDFBytes ? null : bytes;
  }
  const reader = body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maximumPagePDFBytes) {
      cancelQuietly(reader);
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

async function pagePDFBase64(documentURL) {
  if (typeof fetch !== "function" || typeof btoa !== "function") return null;
  const controller = typeof AbortController === "function" ? new AbortController() : null;
  const timer = controller ? setTimeout(() => controller.abort(), pagePDFTimeoutMs) : null;
  try {
    const response = await fetch(documentURL, {
      credentials: "include",
      cache: "force-cache",
      signal: controller?.signal
    });
    const declaredLength = Number(response.headers?.get?.("content-length") || 0);
    if (!response.ok || declaredLength > maximumPagePDFBytes) {
      cancelQuietly(response.body);
      return null;
    }
    const bytes = await boundedBody(response);
    if (!bytes || bytes.length === 0 || !hasPDFSignature(bytes)) return null;
    return base64FromBytes(bytes);
  } catch {
    return null;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

// #5338: Safari hands the result to the share extension as a property list, and a
// property list has no null. One null (a page with no author or date) and the whole
// result never arrives: the extension's loadItem gets nil and refuses the share.
// So only strings, finite numbers, booleans, arrays and plain objects go across;
// a missing value is left out, which the extension already reads as "none".
function propertyListSafe(value) {
  if (value === null || value === undefined) return undefined;
  if (typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
  if (Array.isArray(value)) {
    return value.map(propertyListSafe).filter((item) => item !== undefined);
  }
  if (typeof value === "object") {
    const safe = {};
    for (const [key, item] of Object.entries(value)) {
      const kept = propertyListSafe(item);
      if (kept !== undefined) safe[key] = kept;
    }
    return safe;
  }
  return undefined;
}

function complete(argumentsObject, payload) {
  argumentsObject.completionFunction(propertyListSafe(payload));
}

function completeWithPagePDF(argumentsObject, payload) {
  if (!payload.isPDFDocument || typeof fetch !== "function") {
    complete(argumentsObject, payload);
    return;
  }
  pagePDFBase64(payload.documentURL).then(
    (encoded) => {
      if (encoded) payload.pdfBase64 = encoded;
      complete(argumentsObject, payload);
    },
    () => complete(argumentsObject, payload)
  );
}

globalThis.SourceLinkPreprocessor = function SourceLinkPreprocessor() {};

globalThis.SourceLinkPreprocessor.prototype = {
  run(argumentsObject) {
    try {
      const { markdown, result } = extractReadableMarkdown(document);
      const source = sourceMetadata(document, result);
      const canonicalElement = document.querySelector("link[rel='canonical']");
      completeWithPagePDF(argumentsObject, {
        url: window.location.href,
        documentURL: document.URL,
        canonicalURL: canonicalElement?.href || "",
        contentType: document.contentType || "",
        isPDFDocument: String(document.contentType || "").toLowerCase() === "application/pdf",
        title: source.title,
        author: source.author,
        publishedAt: source.publishedAt,
        markdown,
        contentFormat: "markdown",
        extractor: "defuddle",
        extractorVersion: "0.19.5",
        networkFallback: false
      });
    } catch (error) {
      const fallbackText = String(document.body?.innerText || document.body?.textContent || "").trim();
      completeWithPagePDF(argumentsObject, {
        url: window.location.href,
        documentURL: document.URL,
        contentType: document.contentType || "",
        isPDFDocument: String(document.contentType || "").toLowerCase() === "application/pdf",
        title: document.title || "Shared Web Page",
        text: fallbackText,
        contentFormat: "plain_text",
        extractionError: String(error?.message || error)
      });
    }
  },

  finalize() {}
};

// Safari looks up this exact global instance after evaluating the configured
// NSExtensionJavaScriptPreprocessingFile.
globalThis.ExtensionPreprocessingJS = new globalThis.SourceLinkPreprocessor();
