// Which episode on this page came from a link that carried a reply part (#4675). The arrival page (and a pasted link)
// starts the reply fetch beside the packet fetch, and registers it here under the episode the packet landed on; the Share
// section reads it. Kept in memory for the page only: the web keeps no link key or box detail in storage, so a later visit
// that doesn't come through the link shows today's Share section. Reopening the link fetches it again.
import { useCallback, useSyncExternalStore } from 'react';
import type { ReplyBox } from './logic/reply-box.ts';

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

function set(episodeId: string, state: ReplyBoxState): void {
  states.set(episodeId, state);
  for (const listener of listeners) listener();
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
      if (tokens.get(episodeId) === token) set(episodeId, box ? { kind: 'ready', box, sender, packetDigest } : NONE);
    },
    () => {
      if (tokens.get(episodeId) === token) set(episodeId, NONE);
    },
  );
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
