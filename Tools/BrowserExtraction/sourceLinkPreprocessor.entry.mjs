import { extractReadableMarkdown, sourceMetadata } from "./browserExtractionCore.mjs";

globalThis.SourceLinkPreprocessor = function SourceLinkPreprocessor() {};

globalThis.SourceLinkPreprocessor.prototype = {
  run(argumentsObject) {
    try {
      const { markdown, result } = extractReadableMarkdown(document);
      const source = sourceMetadata(document, result);
      const canonicalElement = document.querySelector("link[rel='canonical']");
      argumentsObject.completionFunction({
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
        extractorVersion: "0.19.1",
        networkFallback: false
      });
    } catch (error) {
      const fallbackText = String(document.body?.innerText || document.body?.textContent || "").trim();
      argumentsObject.completionFunction({
        url: window.location.href,
        documentURL: document.URL,
        contentType: document.contentType || "",
        isPDFDocument: String(document.contentType || "").toLowerCase() === "application/pdf",
        title: document.title || "Shared Web Page",
        text: fallbackText,
        contentFormat: "plain_text",
        extractionError: error.message
      });
    }
  },

  finalize() {}
};

// Safari looks up this exact global instance after evaluating the configured
// NSExtensionJavaScriptPreprocessingFile.
globalThis.ExtensionPreprocessingJS = new globalThis.SourceLinkPreprocessor();
