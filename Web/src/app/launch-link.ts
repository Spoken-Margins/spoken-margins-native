// The app opened at a share link's own address (`<app>/l/<id>#<key>`, #3003). The link is read once, before the
// app renders, and the address bar and history get the app's own address back, so the key doesn't linger there
// and the tabs' `#` routing starts clean.
import { parseShareLink, type ParsedLink } from './logic/share-link.ts';

const LINK_PATH = /\/l\/[A-Za-z0-9_-]{1,64}\/?$/;

export function takeLaunchLink(): ParsedLink {
  const here = new URL(window.location.href);
  if (!LINK_PATH.test(here.pathname)) return { kind: 'none' };
  const parsed = parseShareLink(here.href);
  window.history.replaceState(null, '', `${here.pathname.replace(LINK_PATH, '/')}#library`);
  return parsed.kind === 'none' ? { kind: 'damaged' } : parsed;
}
