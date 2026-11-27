// Which episode on this page came from a link that carried a reply part (#4675). The arrival page (and a pasted link)
// starts the reply fetch beside the packet fetch, and registers it here under the episode the packet landed on; the Share
// section reads it.
//
// A box that opened is also kept in this browser's store, as a `replyBox:<episode id>` settings row beside the Margins
// (#5419), so a reload of the web app's own address still offers "Send to <sender>" and shows the Sent tags. The row holds
// only what posting an answer takes (box id, post proof, seal key, sender's name, packet digest), never the link key. It
// goes when a post says the box can't take answers any more ('ended': closed, removed, full or switched off); a reopened
// link whose fetch fails falls back to the kept box, and one whose fetch opens a box replaces it.
import { useCallback, useSyncExternalStore } from 'react';
import { readReplyBoxRow, replyBoxRowValue, type KeptReplyBox, type ReplyBox } from './logic/reply-box.ts';
import { putMany, remove } from './store/db.ts';
import { REPLY_BOX_PREFIX } from './store/schema.ts';

export type ReplyBoxState =
  /** The episode didn't come through a link with a reply part, or its fetch failed or took too long. */
  | { kind: 'none' }
  /** The fetch hasn't settled yet (at most 5 seconds): the Share section waits. */
  | { kind: 'waiting' }
  | {
    kind: 'ready';
    box: ReplyBox;
    /** The link's sender's name, if the packet has one. */
    sender: string | undefined;
    /** The content digest of the packet the link carried: a reply goes through the box only when it answers a Margin from it. */
    packetDigest: string;
  };

const NONE: ReplyBoxState = Object.freeze({ kind: 'none' });
const WAITING: ReplyBoxState = Object.freeze({ kind: 'waiting' });

const states = new Map<string, ReplyBoxState>();
const tokens = new Map<string, object>();
const listeners = new Set<() => void>();
/** The boxes kept in storage, by episode id, as last written or read. */
const kept = new Map<string, KeptReplyBox>();

function set(episodeId: string, state: ReplyBoxState): void {
  states.set(episodeId, state);
  for (const listener of listeners) listener();
}

const readyFrom = (box: KeptReplyBox): ReplyBoxState => ({ kind: 'ready', box: box.box, sender: box.sender, packetDigest: box.packetDigest });

function keep(episodeId: string, box: KeptReplyBox): void {
  kept.set(episodeId, box);
  // Not kept only costs the reply box after a reload, which reopening the link brings back; the page goes on.
  void putMany('settings', [{ key: `${REPLY_BOX_PREFIX}${episodeId}`, value: replyBoxRowValue(box) }]).catch((error: unknown) =>
    console.warn('Could not keep the link’s reply box.', error),
  );
}

/**
 * Brings back the boxes kept in storage (#5419), from the snapshot's `replyBox:` rows, before the first screen draws. A
 * row that doesn't read is skipped. An episode a link already registered this page keeps that link's state.
 */
export function restoreReplyBoxes(rows: Readonly<Record<string, unknown>> | undefined): void {
  if (!rows) return;
  for (const [episodeId, value] of Object.entries(rows)) {
    const box = readReplyBoxRow(value);
    if (!box) continue;
    kept.set(episodeId, box);
    if (!tokens.has(episodeId)) set(episodeId, readyFrom(box));
  }
}

/**
 * Drops the kept box of an episode once a post into it said it can't take answers (#5419), so the next visit shows
 * today's Share section. This page keeps showing the box, with its "can't take answers" line, until it closes. Only the
 * box that answered is dropped: a newer link's box for the same episode stays.
 */
export function forgetReplyBox(episodeId: string, linkId: string): void {
  const box = kept.get(episodeId);
  if (!box || box.box.linkId !== linkId) return;
  kept.delete(episodeId);
  void remove('settings', `${REPLY_BOX_PREFIX}${episodeId}`).catch((error: unknown) => console.warn('Could not drop the link’s reply box.', error));
}

/**
 * Registers a link's reply fetch for the episode its packet landed on. The latest link opened for an episode wins; an
 * earlier fetch that settles afterwards changes nothing.
 */
export function trackReplyBox(
  episodeId: string, fetching: Promise<ReplyBox | undefined>, sender: string | undefined, packetDigest: string,
): void {
  const token = {};
  tokens.set(episodeId, token);
  set(episodeId, WAITING);
  void fetching.then(
    (box) => {
      if (tokens.get(episodeId) !== token) return;
      if (box) {
        const opened: KeptReplyBox = { box, sender, packetDigest };
        keep(episodeId, opened);
        set(episodeId, readyFrom(opened));
        return;
      }
      fellThrough(episodeId);
    },
    () => {
      if (tokens.get(episodeId) === token) fellThrough(episodeId);
    },
  );
}

/** The fetch found no box (offline, slow, a link with none): the kept box if there is one, else today's section. */
function fellThrough(episodeId: string): void {
  const box = kept.get(episodeId);
  set(episodeId, box ? readyFrom(box) : NONE);
}

/** The reply box for an episode, re-rendering when its fetch settles. */
export function useReplyBox(episodeId: string | undefined): ReplyBoxState {
  const subscribe = useCallback((listener: () => void) => {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  }, []);
  const snapshot = () => (episodeId === undefined ? NONE : states.get(episodeId) ?? NONE);
  return useSyncExternalStore(subscribe, snapshot, snapshot);
}
