import Defuddle from "defuddle/full";

export function normalizeWhitespace(text) {
  return String(text || "").replace(/\s+/g, " ").trim();
}

function metaContent(documentRef, selectors) {
  for (const selector of selectors) {
    const node = documentRef.querySelector(selector);
    const value = node && (node.getAttribute("content") || node.getAttribute("datetime"));
    if (value && normalizeWhitespace(value)) {
      return normalizeWhitespace(value);
    }
  }
  return null;
}

function documentURL(documentRef) {
  return documentRef.location?.href || documentRef.URL || "about:blank";
}

export function sourceMetadata(documentRef, extraction = {}) {
  const title = normalizeWhitespace(extraction.title)
    || metaContent(documentRef, ["meta[property='og:title']", "meta[name='twitter:title']"])
    || normalizeWhitespace(documentRef.title)
    || "Browser Text";
  return {
    url: documentURL(documentRef),
    title,
    author: normalizeWhitespace(extraction.author) || metaContent(documentRef, [
      "meta[name='author']",
      "meta[property='article:author']",
      "meta[name='byl']"
    ]),
    publishedAt: normalizeWhitespace(extraction.published) || metaContent(documentRef, [
      "meta[property='article:published_time']",
      "meta[name='date']",
      "meta[name='citation_publication_date']",
      "time[datetime]"
    ])
  };
}

function payloadID(globalRef) {
  return globalRef.crypto && typeof globalRef.crypto.randomUUID === "function"
    ? globalRef.crypto.randomUUID()
    : `browser-text-${Date.now()}-${Math.floor(Math.random() * 100000)}`;
}

function buildPayload(globalRef, documentRef, captureMode, contentFormat, text, extraction = {}, metadata = {}) {
  return {
    id: payloadID(globalRef),
    schemaVersion: "browser-text-handoff.v1",
    captureMode,
    contentFormat,
    source: sourceMetadata(documentRef, extraction),
    text: String(text || "").trim(),
    selection: null,
    requestedContinuation: {
      startSession: false,
      preferredPlaybackOwner: "app"
    },
    createdAt: new Date().toISOString(),
    metadata: {
      extractor: metadata.extractor || "defuddle",
      extractorVersion: metadata.extractorVersion || "0.19.1",
      networkFallback: false,
      userAgent: globalRef.navigator ? globalRef.navigator.userAgent : null,
      ...(metadata.extractionError ? { extractionError: metadata.extractionError } : {})
    }
  };
}

export function captureSelectedText(globalRef, documentRef) {
  const selection = documentRef.getSelection ? documentRef.getSelection() : globalRef.getSelection?.();
  const text = normalizeWhitespace(selection ? selection.toString() : "");
  if (!text) {
    throw new Error("Select text on the page before sending selected text.");
  }
  return buildPayload(globalRef, documentRef, "selected_text", "plain_text", text);
}

export function extractReadableMarkdown(documentRef) {
  const result = new Defuddle(documentRef, {
    markdown: true,
    useAsync: false,
    url: documentURL(documentRef)
  }).parse();
  const markdown = String(result.contentMarkdown || result.content || "").trim();
  if (!markdown || markdown.startsWith("Partial conversion completed with errors.")) {
    throw new Error("No readable page text was found.");
  }
  return { markdown, result };
}

export function fallbackReadableMarkdown(documentRef) {
  const root = documentRef.querySelector("article")
    || documentRef.querySelector("main")
    || documentRef.body;
  if (!root) {
    throw new Error("No article, main content, or page body was available.");
  }

  const blocks = Array.from(root.querySelectorAll("h1,h2,h3,h4,h5,h6,p,li,blockquote,pre"));
  const rendered = blocks.map(renderFallbackBlock).filter(Boolean);
  const markdown = rendered.join("\n\n").trim();
  const fallbackText = normalizeWhitespace(root.innerText || root.textContent || "");
  const text = markdown || fallbackText;
  if (!text) {
    throw new Error("No readable page text was found in the article, main content, or page body.");
  }
  return text;
}

function renderFallbackBlock(element) {
  const tagName = String(element.tagName || "").toLowerCase();
  if (tagName === "p" && element.closest?.("li,blockquote")) {
    return null;
  }
  const text = normalizeWhitespace(element.innerText || element.textContent || "");
  if (!text) {
    return null;
  }
  if (/^h[1-6]$/.test(tagName)) {
    return `${"#".repeat(Number(tagName.slice(1)))} ${text}`;
  }
  if (tagName === "li") {
    return `- ${text}`;
  }
  if (tagName === "blockquote") {
    return `> ${text}`;
  }
  if (tagName === "pre") {
    return `\`\`\`\n${text}\n\`\`\``;
  }
  return text;
}

export function captureReadablePage(globalRef, documentRef) {
  try {
    const { markdown, result } = extractReadableMarkdown(documentRef);
    return buildPayload(globalRef, documentRef, "readable_page", "markdown", markdown, result);
  } catch (error) {
    const markdown = fallbackReadableMarkdown(documentRef);
    return buildPayload(
      globalRef,
      documentRef,
      "readable_page",
      "markdown",
      markdown,
      {},
      {
        extractor: "semantic_dom_fallback",
        extractorVersion: "1",
        extractionError: error instanceof Error ? error.message : String(error)
      }
    );
  }
}
