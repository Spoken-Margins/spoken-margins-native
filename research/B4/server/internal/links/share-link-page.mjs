// The share page for friends without the app (#805, #486). The server sends a shell; this module
// fetches the link's sealed preview from /l/<id>/preview, opens it with the key in location.hash
// (never sent to the server), checks it, and fills in the Margins. Every value goes in as text,
// never as HTML.

import { DAMAGED_MESSAGE, DamagedLinkError, checkPreview, keyFromFragment, openPreview, safeSourceURL } from './share-link-open.mjs';

// The app's messages for the same outcomes (ShareLinkPacketDownloader in SessionKit).
export const EXPIRED_MESSAGE = 'This link has expired. Ask your friend to share it again.';
export const OFFLINE_MESSAGE = "You're offline. Reconnect, then reload this page.";
export const SERVER_MESSAGE = 'The server had a problem. Try again in a minute.';

const LINK_ID = /^[0-9a-f]{32}$/;

function element(doc, name, text) {
  const node = doc.createElement(name);
  if (text !== undefined) node.textContent = text;
  return node;
}

function excerpt(doc, label, text) {
  const quote = element(doc, 'blockquote');
  quote.append(element(doc, 'small', label), element(doc, 'p', text));
  return quote;
}

/** Draws the checked preview into `section`, after its status line. */
export function renderPreview(doc, section, preview) {
  const href = safeSourceURL(preview.source.url);
  for (const margin of preview.margins) {
    const article = element(doc, 'article');
    article.append(element(doc, 'h2', 'Margin'), element(doc, 'p', margin.text));
    if (margin.before) article.append(excerpt(doc, 'Quotation from the source · before this Margin', margin.before));
    if (margin.after) article.append(excerpt(doc, 'Quotation from the source · after this Margin', margin.after));
    const footer = element(doc, 'footer');
    const source = element(doc, 'p');
    source.append(element(doc, 'strong', preview.source.title));
    if (preview.source.show) source.append(element(doc, 'br'), doc.createTextNode(preview.source.show));
    footer.append(source);
    if (href) {
      const link = element(doc, 'a', 'Open public source');
      link.href = href;
      link.rel = 'noreferrer noopener';
      footer.append(link);
    }
    article.append(footer);
    section.append(article);
  }
}

/**
 * Opens the link this page was loaded for. `fetchPreview(path)` resolves to a Response-like
 * `{ status, arrayBuffer() }`. Returns the status message shown, or '' when the Margins are shown.
 */
export async function showSharedMargins(doc, hash, fetchPreview) {
  const section = doc.getElementById('margins');
  const status = doc.getElementById('status');
  const say = (message) => {
    status.textContent = message;
    return message;
  };
  const id = section?.dataset.link ?? '';
  // Without the key nothing can open, so don't ask the server for bytes.
  if (!LINK_ID.test(id) || !keyFromFragment(hash)) return say(DAMAGED_MESSAGE);
  say('Opening the Margins…');
  let response;
  try {
    response = await fetchPreview(`/l/${id}/preview`);
  } catch {
    return say(OFFLINE_MESSAGE);
  }
  if (response.status === 404 || response.status === 410) return say(EXPIRED_MESSAGE);
  if (response.status !== 200) return say(SERVER_MESSAGE);
  let preview;
  try {
    preview = checkPreview(await openPreview(new Uint8Array(await response.arrayBuffer()), hash));
  } catch (error) {
    if (error instanceof DamagedLinkError) return say(DAMAGED_MESSAGE);
    return say(OFFLINE_MESSAGE);
  }
  say('');
  renderPreview(doc, section, preview);
  return '';
}

if (typeof document !== 'undefined' && typeof location !== 'undefined') {
  showSharedMargins(document, location.hash, (path) =>
    fetch(path, { cache: 'no-store', credentials: 'omit', redirect: 'error', referrerPolicy: 'no-referrer' }),
  );
}
