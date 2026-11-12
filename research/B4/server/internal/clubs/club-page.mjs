// The club invitation page (#1799, docs/design/club-mailbox.md section 10, slice 4). The server sends a shell that
// never looks the club up and cannot see the key. This module reads the address's `#` part in the browser and
// builds the "Open in Spoken Margins" address from it. It makes no request and writes only text and one href.

const CLUB_ID = /^[0-9a-f]{32}$/;
// The key is 32 bytes as unpadded base64url (43 characters), with any `=` padding a messaging app may have added
// (ShareLinkSealing.Key.init?(fragment:) in SessionKit reads the same shape; the club invite of slice 2, #4156, uses it).
const KEY_FRAGMENT = /^#[A-Za-z0-9_-]{43}=*$/;
// A plain host the app's invite parser could accept: no port, no user, no punctuation.
const HOST = /^[a-z0-9.-]+$/;

// The same sentence the share page and the web app use when a link lost its key (CUT_OFF_MESSAGE in
// share-link-page.mjs).
export const CUT_OFF_MESSAGE = 'This link is cut off. Copy the whole link from the message and open it again.';

/** The address that hands the invite to the app: `spokenmargins://club?link=<the https invite link>`. The app
 * side is slice 5: it must read the invite with the same strict parser as a tapped link (ClubInvite.parse, slice 2,
 * #4156), which checks the path id against the key's, and it must accept the old host's links too. The link is rebuilt from its parts so that nothing else in the address (a
 * query, a user name) rides along. Undefined when the key is missing or cut short, the id is not a club's, or the
 * host is not a plain one. */
export function openInAppAddress(id, host, hash) {
  if (typeof id !== 'string' || !CLUB_ID.test(id)) return undefined;
  if (typeof host !== 'string' || !HOST.test(host)) return undefined;
  if (typeof hash !== 'string' || !KEY_FRAGMENT.test(hash)) return undefined;
  return `spokenmargins://club?link=${encodeURIComponent(`https://${host}/c/${id}${hash}`)}`;
}

/** Shows the open button when the address carries a key, and otherwise says the link is cut off. Returns the
 * status message shown, or '' when the button is. */
export function showInvite(doc, location) {
  const status = doc.getElementById('status');
  const open = doc.getElementById('open');
  const id = doc.getElementById('club')?.dataset.club ?? '';
  const address = openInAppAddress(id, location.host, location.hash);
  if (!address) {
    status.textContent = CUT_OFF_MESSAGE;
    return CUT_OFF_MESSAGE;
  }
  open.setAttribute('href', address);
  open.removeAttribute('hidden');
  status.textContent = '';
  return '';
}

if (typeof document !== 'undefined' && typeof location !== 'undefined') {
  showInvite(document, location);
}
