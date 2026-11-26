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
const TABLE_CELL_BREAKS = new Set(["td", "th", "tr", "p", "div", "br", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre"]);
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

// A data table: no nested table, at least one of its own rows with two or more cells (Defuddle's line), and no cell
// that holds a heading or two or more paragraphs, list items, quotes or code blocks (a page's content cell beside a
// sidebar, #5364 audit of 3ac974e). Anything else is a layout table, whose text is read as the page's own blocks.
export function isDataTable(table) {
  if (table.querySelector("table")) {
    return false;
  }
  const cells = row => Array.from(row.children).filter(cell => /^(td|th)$/i.test(String(cell.tagName || "")));
  const rows = ownTableRows(table);
  if (!rows.some(row => cells(row).length >= 2)) {
    return false;
  }
  return !rows.some(row => cells(row).some(cell =>
    cell.querySelector("h1,h2,h3,h4,h5,h6") || cell.querySelectorAll("p,li,blockquote,pre").length >= 2));
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
  // A <caption> names the table; keep it as a line above the rows.
  const caption = Array.from(table.children).find(child => String(child.tagName || "").toLowerCase() === "caption");
  const captionText = caption ? tableCellText(caption).replace(/\\\|/g, "|") : "";
  const line = row => `| ${Array.from({ length: width }, (_, index) => row[index] ?? "").join(" | ")} |`;
  const markdown = [line(rows[0]), `| ${Array(width).fill("---").join(" | ")} |`, ...rows.slice(1).map(line)].join("\n");
  return captionText ? `${captionText}\n\n${markdown}` : markdown;
}

// Defuddle keeps a table as HTML when any cell has a colspan or rowspan
// attribute, even colspan="1" (alignment.anthropic.com marks every cell so),
// and the app turns each cell's paragraph into a line of its own. Give every
// such table back as Markdown. A table that won't parse is left as it was.
// Defuddle writes a table it keeps as HTML on lines of its own, so only a
// "<table" that opens a line, outside a code fence, starts one: a code sample
// or a mention of <table> in prose is left as written. A table with no
// closing tag is left too, and the scan goes on after it.
const FENCE_LINE = /^ {0,3}(`{3,}|~{3,})/;
const TABLE_LINE = /^ {0,3}<table\b/i;

function htmlTableBlocks(markdown) {
  const blocks = [];
  const tokens = /<table\b[^>]*>|<\/table\s*>/gi;
  let fence = null;
  let offset = 0;
  while (offset < markdown.length) {
    const lineEnd = markdown.indexOf("\n", offset);
    const next = lineEnd === -1 ? markdown.length : lineEnd + 1;
    const line = markdown.slice(offset, lineEnd === -1 ? markdown.length : lineEnd);
    const fenceMark = line.match(FENCE_LINE);
    if (fence) {
      if (fenceMark && fenceMark[1][0] === fence[0] && fenceMark[1].length >= fence.length) {
        fence = null;
      }
    } else if (fenceMark) {
      fence = fenceMark[1];
    } else if (TABLE_LINE.test(line)) {
      tokens.lastIndex = offset;
      let depth = 0;
      let end = -1;
      for (let match = tokens.exec(markdown); match; match = tokens.exec(markdown)) {
        depth += match[0][1] === "/" ? -1 : 1;
        if (depth === 0) {
          end = match.index + match[0].length;
          break;
        }
      }
      if (end !== -1) {
        blocks.push([offset + line.length - line.trimStart().length, end]);
        const after = markdown.indexOf("\n", end);
        offset = after === -1 ? markdown.length : after + 1;
        continue;
      }
    }
    offset = next;
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
    if (!converted) {
      result += markdown.slice(previous, end);
    } else {
      // Only the blank lines around the table are tidied, never the rest.
      const before = markdown.slice(previous, start).replace(/\s*$/, "");
      result += `${before}${before ? "\n\n" : ""}${converted}\n\n`;
      // Skip the blank lines that followed the HTML table.
      const rest = markdown.slice(end).match(/^\s*/)[0].length;
      previous = end + rest;
      continue;
    }
    previous = end;
  }
  return (result + markdown.slice(previous)).replace(/\n\n$/, previous >= markdown.length ? "" : "\n\n");
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
  // A layout table is no block: its headings and paragraphs are (#5364 audit).
  const dataTables = new Map();
  const isBlock = element => {
    if (String(element.tagName || "").toLowerCase() !== "table") {
      return true;
    }
    if (!dataTables.has(element)) {
      dataTables.set(element, isDataTable(element));
    }
    return dataTables.get(element);
  };
  const insideBlock = element => {
    for (let parent = element.parentElement; parent; parent = parent.parentElement) {
      if (parent.matches?.(selector) && isBlock(parent)) {
        return true;
      }
    }
    return false;
  };
  const blocks = Array.from(root.querySelectorAll(selector))
    .filter(element => isBlock(element) && !insideBlock(element));
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
