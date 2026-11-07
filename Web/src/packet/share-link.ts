// Opening a share link in the web app. A link is the packet and a small preview, each sealed with AES-256-GCM under a
// key that travels only in the link's `#` part, so the server holds bytes it can't read (#805). Opening reuses the
// landing page's own module (research/B4/server/internal/links/share-link-open.mjs), held to
// research/B4/contracts/fixtures/share-link-sealing-vector.json.
//
// The web app is receive-only for share links (owner, 2026-11-05, #3542): it opens and reports links, and cannot make
// one. Sealing and uploading live under src/cli, which only the Mac's make-share-link command and the
// tests import; nothing under src/app does (src/app/no-link-creation.test.ts checks).

import {
  DAMAGED_MESSAGE,
  DamagedLinkError,
  PART,
  keyFromFragment,
  openPart,
} from '../../../research/B4/server/internal/links/share-link-open.mjs';

export { DAMAGED_MESSAGE, DamagedLinkError, PART, keyFromFragment, openPart };
