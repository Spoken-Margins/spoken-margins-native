import Defuddle from "defuddle/full";

export function normalizeWhitespace(text) {
  return String(text || "").replace(/\s+/g, " ").trim();
}

const SOCIAL_CARD_LINK_PATTERN = /^[ \t]*\[[ \t]*\r?\n([\s\S]*?)\r?\n\]\((https?:\/\/(?:www\.)?(?:x\.com|twitter\.com|bsky\.app|threads\.net|instagram\.com)\/[^)\r\n\s]+)\)[ \t]*$/gim;
const SOCIAL_AUTHOR_PATTERN = /^(.*?)\s*@([A-Za-z0-9_]{1,30})$/;
const SOCIAL_METRIC_PATTERN = /^\d[\d,.]*[KMBT]?\s+(?:views?|replies?|reposts?|likes?|bookmarks?|quotes?)$/i;
const SOCIAL_TIME_PATTERN = /^\d{1,2}:\d{2}(?::\d{2})?\s*(?:am|pm)?$/i;
const SOCIAL_DATE_PATTERN = /^(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{1,2},\s+\d{4}$/i;

function isSocialMetadataLine(line) {
  const atoms = line.split(/[·•]/).map(part => part.trim()).filter(Boolean);
  if (!atoms.length || !atoms.some(atom => SOCIAL_METRIC_PATTERN.test(atom))) {
    return false;
  }
  return atoms.every(atom =>
    SOCIAL_METRIC_PATTERN.test(atom)
      || SOCIAL_TIME_PATTERN.test(atom)
      || SOCIAL_DATE_PATTERN.test(atom)
  );
}

function renderSocialCard(content) {
  const withoutMedia = content
    .replace(/<\s*(?:video|audio|iframe)\b[^>]*>[\s\S]*?<\s*\/\s*(?:video|audio|iframe)\s*>/gi, "\nMedia attached.\n")
    .replace(/<\s*(?:video|audio|iframe)\b[^>]*\/?\s*>/gi, "\nMedia attached.\n")
    .replace(/!\[[^\]]*\]\([^\n)]*\)/g, "\n")
    .replace(/<[^>]+>/g, " ");
  let authorCount = 0;
  const parts = [];
  const punctuatePreviousPart = () => {
    const previous = parts.at(-1);
    if (previous && !/[.!?][\"')\]]?$/.test(previous)) {
      parts[parts.length - 1] = `${previous}.`;
    }
  };
  for (const rawLine of withoutMedia.split(/\r?\n/)) {
    const line = normalizeWhitespace(rawLine);
    if (!line || /^(?:---|___|\*\*\*)$/.test(line) || isSocialMetadataLine(line)) {
      continue;
    }
    const author = line.match(SOCIAL_AUTHOR_PATTERN);
    if (author) {
      if (authorCount > 0) {
        punctuatePreviousPart();
      }
      const name = normalizeWhitespace(author[1]) || `@${author[2]}`;
      parts.push(`${authorCount++ === 0 ? "Post" : "Quoted post"} from ${name}.`);
      continue;
    }
    if (line === "Media attached." && parts.at(-1) === line) {
      continue;
    }
    if (line === "Media attached.") {
      punctuatePreviousPart();
    }
    parts.push(line);
  }
  let rendered = parts.join(" ").trim();
  if (rendered && !/[.!?][\"')\]]?$/.test(rendered)) {
    rendered += ".";
  }
  return rendered;
}

export function normalizeSocialEmbedsForReading(markdown) {
  return String(markdown || "").replace(
    SOCIAL_CARD_LINK_PATTERN,
    (_match, content) => renderSocialCard(content)
  );
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
      extractorVersion: metadata.extractorVersion || "0.19.5",
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

// A table's cells as a Markdown table, so speech announces it once ("Table not
// read.") and Timeline draws it, instead of reading every cell as a sentence
// (#5364). Spans are laid out on a grid: a cell's text fills every column and
// row it covers. The first row is the header, whatever its cells are tagged.
const TABLE_CELL_BREAKS = new Set(["p", "div", "br", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre"]);
const MAX_TABLE_SPAN = 1000;

function tableSpan(cell, attribute) {
  const value = Number.parseInt(String(cell.getAttribute(attribute) ?? "").trim(), 10);
  return Number.isFinite(value) && value >= 1 ? Math.min(value, MAX_TABLE_SPAN) : 1;
}

// The cell's words, with a space where a paragraph or line break separates
// them. Read only: the fallback path runs on the listener's live page.
function cellWords(node, parts) {
  if (node.nodeType === 3) {
    parts.push(node.nodeValue);
    return;
  }
  const tag = String(node.tagName || "").toLowerCase();
  if (tag === "script" || tag === "style") {
    return;
  }
  const breaks = TABLE_CELL_BREAKS.has(tag);
  if (breaks) {
    parts.push(" ");
  }
  for (const child of Array.from(node.childNodes || [])) {
    cellWords(child, parts);
  }
  if (breaks) {
    parts.push(" ");
  }
}

function tableCellText(cell) {
  const parts = [];
  for (const child of Array.from(cell.childNodes || [])) {
    cellWords(child, parts);
  }
  return normalizeWhitespace(parts.join("")).replace(/\|/g, "\\|");
}

function ownTableRows(table) {
  return Array.from(table.querySelectorAll("tr")).filter(row => row.closest("table") === table);
}

export function tableToMarkdown(table) {
  const grid = [];
  const tableRows = ownTableRows(table);
  tableRows.forEach((row, rowIndex) => {
    grid[rowIndex] ??= [];
    let column = 0;
    for (const cell of Array.from(row.children)) {
      const tag = String(cell.tagName || "").toLowerCase();
      if (tag !== "td" && tag !== "th") {
        continue;
      }
      while (grid[rowIndex][column] !== undefined) {
        column += 1;
      }
      const text = tableCellText(cell);
      const columns = tableSpan(cell, "colspan");
      // A row span never makes rows the table doesn't have.
      const rows = Math.min(tableSpan(cell, "rowspan"), tableRows.length - rowIndex);
      for (let down = 0; down < rows; down += 1) {
        grid[rowIndex + down] ??= [];
        for (let across = 0; across < columns; across += 1) {
          grid[rowIndex + down][column + across] = text;
        }
      }
      column += columns;
    }
  });
  const rows = grid.filter(row => row && row.some(cell => cell));
  const width = Math.max(0, ...rows.map(row => row.length));
  if (!rows.length || width === 0) {
    return "";
  }
  const line = row => `| ${Array.from({ length: width }, (_, index) => row[index] ?? "").join(" | ")} |`;
  return [line(rows[0]), `| ${Array(width).fill("---").join(" | ")} |`, ...rows.slice(1).map(line)].join("\n");
}

// Defuddle keeps a table as HTML when any cell has a colspan or rowspan
// attribute, even colspan="1" (alignment.anthropic.com marks every cell so),
// and the app turns each cell's paragraph into a line of its own. Give every
// such table back as Markdown. A table that won't parse is left as it was.
function htmlTableBlocks(markdown) {
  const blocks = [];
  const tokens = /<table\b[^>]*>|<\/table\s*>/gi;
  let depth = 0;
  let start = -1;
  for (const match of markdown.matchAll(tokens)) {
    if (match[0][1] !== "/") {
      if (depth === 0) {
        start = match.index;
      }
      depth += 1;
    } else if (depth > 0) {
      depth -= 1;
      if (depth === 0) {
        blocks.push([start, match.index + match[0].length]);
      }
    }
  }
  return blocks;
}

export function htmlTablesAsMarkdown(markdown, documentRef) {
  const blocks = htmlTableBlocks(markdown);
  if (!blocks.length || !documentRef?.createElement) {
    return markdown;
  }
  let result = "";
  let previous = 0;
  for (const [start, end] of blocks) {
    // A template parses without loading the pictures or running anything in it.
    const holder = documentRef.createElement("template");
    holder.innerHTML = markdown.slice(start, end);
    const table = (holder.content || holder).querySelector("table");
    const converted = table ? tableToMarkdown(table) : "";
    result += markdown.slice(previous, start) + (converted ? `\n\n${converted}\n\n` : markdown.slice(start, end));
    previous = end;
  }
  return (result + markdown.slice(previous)).replace(/\n{3,}/g, "\n\n");
}

// Defuddle strips every element whose class or id starts with "ad-" or ends
// with "-ad" as an advertisement. A few publishers name the article body that
// way (e-flux: "article__body article__body--with-ad"), and then the essay
// disappears and only the footnotes are left. Defuddle copies the page before
// it cleans, so rename the ad-looking names on a prose container while it
// runs and put them back straight after, leaving the page as it was found.
const AD_NAMED_SELECTOR = [
  '[class^="ad-" i]', '[class$="-ad" i]', '[id^="ad-" i]', '[id$="-ad" i]'
].join(",");
const PROSE_CONTAINER_MIN_WORDS = 150;
const PROSE_CONTAINER_MIN_PARAGRAPHS = 3;

function isProseContainer(element) {
  const words = normalizeWhitespace(element.textContent).split(" ").length;
  return words >= PROSE_CONTAINER_MIN_WORDS
    && element.querySelectorAll("p").length >= PROSE_CONTAINER_MIN_PARAGRAPHS;
}

function withoutAdLookingName(name) {
  const unprefixed = /^ad-/i.test(name) ? `sm-${name}` : name;
  return /-ad$/i.test(unprefixed) ? `${unprefixed}-sm` : unprefixed;
}

function shieldProseFromAdSelectors(documentRef) {
  const restores = [];
  for (const element of documentRef.querySelectorAll(AD_NAMED_SELECTOR)) {
    if (!isProseContainer(element)) {
      continue;
    }
    for (const attribute of ["class", "id"]) {
      const original = element.getAttribute(attribute);
      if (original === null) {
        continue;
      }
      const renamed = original.split(/\s+/).map(withoutAdLookingName).join(" ");
      if (renamed !== original) {
        element.setAttribute(attribute, renamed);
        restores.push(() => element.setAttribute(attribute, original));
      }
    }
  }
  return () => restores.forEach(restore => restore());
}

export function extractReadableMarkdown(documentRef) {
  const restoreAdNames = shieldProseFromAdSelectors(documentRef);
  let result;
  try {
    result = new Defuddle(documentRef, {
      markdown: true,
      useAsync: false,
      url: documentURL(documentRef)
    }).parse();
  } finally {
    restoreAdNames();
  }
  const markdown = htmlTablesAsMarkdown(normalizeSocialEmbedsForReading(
    String(result.contentMarkdown || result.content || "")
  ), documentRef).trim();
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

  const selector = "h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,table";
  // Parent block text includes all descendants, including nested lists and
  // quotations. Never deduplicate by prose: repeated sibling text is authored.
  const blocks = Array.from(root.querySelectorAll(selector))
    .filter(element => !element.parentElement?.closest(selector));
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
  if (tagName === "table") {
    // A cell's paragraphs are not sentences of their own (#5364).
    return tableToMarkdown(element) || null;
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
