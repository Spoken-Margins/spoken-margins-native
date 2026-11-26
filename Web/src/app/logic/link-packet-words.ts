// What the arrival page says when a share link's packet arrived but this page's reader refused it (#5266).
//
// The packet behind a link is sealed with an authenticated cipher (share-link.ts), so once it opens, its bytes are
// exactly the bytes the friend sent. A refusal after that is almost never damage on the way: it is most often a packet
// written by a newer Spoken Margins than this page reads, and sending it again gives the same result. So no outcome
// but `damaged` says "damaged" or "send it again", and the version outcomes give a step that can work: open the link
// again (which loads the page's newest version), and if that doesn't help, open it in the iPhone app.
//
// The reader's own sentences (packet/errors.ts) are written for a file opened from the Library ("Update the app"), so
// the page words a link's refusal here instead. Every outcome has its words: a new PacketOutcome won't type-check
// until it gets some.
import { ARRIVAL_WORDS } from './arrival.ts';
import { LISTENING_MAP_DETAIL, PacketError, type PacketOutcome } from '../../packet/errors.ts';

/** The step for a refusal a newer page or the iPhone app can get past. */
// Not "reload this page": by now the page has taken the link and its key out of the address (Arrival), so a reload opens
// the Library. Opening the link again is a fresh navigation, which the service worker sends to the network first.
const RELOAD_THEN_APP = 'Open your friend’s link again, so this page loads its newest version. If they still won’t open, open the link in the Spoken Margins app on iPhone.';

/** The words for each way the reader can refuse a link's packet. The first sentence is the card's heading. */
export const LINK_PACKET_WORDS: Readonly<Record<PacketOutcome, string>> = Object.freeze({
  needsNewerApp: `These Margins were made by a newer Spoken Margins than this page can read. ${RELOAD_THEN_APP}`,
  // Authenticated, so the bytes are what was sent: a packet this page can't read in a link is a version gap, not damage.
  doesNotMatch: `This page couldn’t read these Margins. ${RELOAD_THEN_APP}`,
  // Opened under the key but not a packet at all: no page or app version reads it, so the sender shares the Margins again.
  notAPacket: 'This link doesn’t hold Margins that Spoken Margins can open. Ask your friend to share their Margins again.',
  tooLarge: 'These Margins are bigger than Spoken Margins can open. Ask your friend to share fewer Margins at a time.',
  damaged: ARRIVAL_WORDS.unreadable,
  // The reader never refuses with this one today; if it ever does, it reads as the damaged file did before (#5266).
  cannotShare: ARRIVAL_WORDS.unreadable,
});

/** A Listening Map is not a version gap the page will close: only the iPhone app opens one. */
export const LINK_LISTENING_MAP_WORDS = 'This link holds a Listening Map, which the browser can’t open. Open the link in the Spoken Margins app on iPhone.';

/**
 * The words for an error the arrival page met after the link's packet was fetched, or undefined when it isn't a reader
 * refusal (the page's own fallback then applies).
 */
export function linkPacketWords(error: unknown): string | undefined {
  if (!(error instanceof PacketError)) return undefined;
  if (error.outcome === 'needsNewerApp' && error.detail === LISTENING_MAP_DETAIL) return LINK_LISTENING_MAP_WORDS;
  return LINK_PACKET_WORDS[error.outcome];
}
