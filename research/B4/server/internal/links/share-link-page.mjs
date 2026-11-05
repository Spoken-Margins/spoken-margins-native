// The share page for friends without the app (#805, #486). The server sends a shell; this module
// fetches the link's sealed preview from /l/<id>/preview, opens it with the key in location.hash
// (never sent to the server), checks it, and fills in the Margins. Every value goes in as text,
// never as HTML.

import { DamagedLinkError, checkPreview, keyFromFragment, openPreview, safeSourceURL } from './share-link-open.mjs';

// The app's messages for the same outcomes (ShareLinkPacketDownloader in SessionKit).
export const EXPIRED_MESSAGE = 'This link has expired. Ask your friend to share it again.';
export const OFFLINE_MESSAGE = "You're offline. Reconnect, then reload this page.";
export const SERVER_MESSAGE = 'The server had a problem. Try again in a minute.';
// A missing, cut-off or unopenable key (#3355). These are the web app's words for the same thing (ARRIVAL_WORDS.cutOff in
// Web/src/app/logic/arrival.ts; share-link-open.test.mjs checks they match), so a friend reads one sentence whichever
// page they land on. DAMAGED_MESSAGE in share-link-open.mjs stays as it is: the web app's toast and the iPhone app use it.
export const CUT_OFF_MESSAGE = 'This link is cut off. Copy the whole link from the message and open it again.';

const LINK_ID = /^[0-9a-f]{32}$/;
// An origin the server was started with (-links-web-url, #2168): scheme, host and an optional port, nothing else.
const WEB_ORIGIN = /^https?:\/\/[a-z0-9.-]+(:\d{1,5})?$/;

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

// Shown when the preview has no public source page. The app sends the link and the `.spokenmargins` file in one
// message for such an item (owner, 2026-10-20), so a friend who opened only the link is told where the item is.
export const FILE_NOTE = 'The item these Margins are on came as a file in the same message. Open that file in Spoken Margins to hear them in place.';

/** Draws the checked preview into `section`, after its status line. */
export function renderPreview(doc, section, preview) {
  const href = safeSourceURL(preview.source.url);
  if (!href) section.append(element(doc, 'p', FILE_NOTE));
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
 * Where a browser goes to hear the Margins (#2168): the web app's page for this link, with the address's `#` part as it
 * is. Undefined when the server names no web app, the link id is malformed, or the address asks for the report form
 * (`?report`), and then this page stays. The key is not checked here (#3355): a link with no key, or one a messaging app
 * cut short, goes too, and the web app words it ("This link is cut off", Web/src/app/screens/Arrival.tsx). Only a real
 * `#...` part is passed on, so nothing in the address can change the path or the origin. The key travels only in that
 * `#` part, to the web app's own page.
 */
export function playingPageAddress(doc, hash, search) {
  const section = doc.getElementById('margins');
  const web = section?.dataset.web ?? '';
  const id = section?.dataset.link ?? '';
  if (!WEB_ORIGIN.test(web) || !LINK_ID.test(id) || asksForReport(search)) return undefined;
  const fragment = typeof hash === 'string' && hash.startsWith('#') ? hash : '';
  return `${web}/l/${id}${fragment}`;
}

function asksForReport(search) {
  return new URLSearchParams(search ?? '').has('report');
}

/** The report form is closed until the address asks for it (`?report`, which the web app's "Report this link" opens). */
export function openReportForm(doc, search) {
  if (!asksForReport(search)) return;
  const form = doc.getElementById('report');
  form?.setAttribute('open', '');
}

/**
 * Opens the link this page was loaded for. `fetchPreview(path)` resolves to a Response-like
 * `{ status, arrayBuffer() }`. Returns the status message shown, or '' when the Margins are shown.
 */
export async function showSharedMargins(doc, hash, fetchPreview, search = '') {
  const section = doc.getElementById('margins');
  const status = doc.getElementById('status');
  const say = (message) => {
    status.textContent = message;
    return message;
  };
  const id = section?.dataset.link ?? '';
  // Without the key nothing can open, so don't ask the server for bytes. Someone who came to report the link (`?report`,
  // from the web app's own "Report this link") has no key and needs none, so they are told nothing failed (#3355).
  if (!LINK_ID.test(id) || !keyFromFragment(hash)) return say(asksForReport(search) ? '' : CUT_OFF_MESSAGE);
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
    if (error instanceof DamagedLinkError) return say(CUT_OFF_MESSAGE);
    return say(OFFLINE_MESSAGE);
  }
  say('');
  renderPreview(doc, section, preview);
  return '';
}

if (typeof document !== 'undefined' && typeof location !== 'undefined') {
  openReportForm(document, location.search);
  const playing = playingPageAddress(document, location.hash, location.search);
  if (playing) {
    location.replace(playing);
  } else {
    showSharedMargins(
      document,
      location.hash,
      (path) => fetch(path, { cache: 'no-store', credentials: 'omit', redirect: 'error', referrerPolicy: 'no-referrer' }),
      location.search,
    );
  }
}
