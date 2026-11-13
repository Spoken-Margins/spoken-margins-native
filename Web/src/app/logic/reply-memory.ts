// Which friend's Margin a new Margin answers when the listener did not press Reply (#4107 B1; the iPhone app's
// SharedMarginReplyMemory.swift, #473, owner 2026-10-25). A Margin begun while a friend's Margin is playing or showing,
// or within `WINDOW_SECONDS` after it ends, is a reply to it. This is the decision alone, with no player and no DOM, so
// it can be tested: the player tells it when a friend's Margin starts and when it ends, and passes the time.
import type { Margin } from '../../shared/model.ts';

/** How long after a friend's Margin ends that a new Margin still answers it: long enough to take a breath, short enough that a thought a minute later stands alone. */
export const WINDOW_SECONDS = 20;

/** The last friend's Margin heard: which one, on which episode, and when it ended (undefined while it is still sounding or showing). */
export interface ReplyMemory {
  readonly heard?: { readonly marginId: string; readonly episodeId: string; readonly endedAtMs?: number };
}

export const NOTHING_HEARD: ReplyMemory = Object.freeze({});

/** A friend's Margin started. It replaces whatever was heard before: two Margins in a row, the later one is answered. */
export function started(_memory: ReplyMemory, marginId: string, episodeId: string): ReplyMemory {
  return { heard: { marginId, episodeId } };
}

/** It ended, finished or was cut. Only the first end counts, so an end path that runs twice cannot stretch the window. */
export function ended(memory: ReplyMemory, atMs: number): ReplyMemory {
  const heard = memory.heard;
  if (!heard || heard.endedAtMs !== undefined) return memory;
  return { heard: { ...heard, endedAtMs: atMs } };
}

/** The id of the friend's Margin that a Margin started at `nowMs` on `episodeId` answers, if any. */
export function suggestion(memory: ReplyMemory, episodeId: string, nowMs: number): string | undefined {
  const heard = memory.heard;
  if (!heard || heard.episodeId !== episodeId) return undefined;
  if (heard.endedAtMs === undefined) return heard.marginId; // still sounding or showing
  return Math.max(0, nowMs - heard.endedAtMs) <= WINDOW_SECONDS * 1000 ? heard.marginId : undefined;
}

/** The Margin the composer answers: the suggestion, found among the episode's friend Margins. Undefined when it is gone from the list. */
export function replyForComposer(
  memory: ReplyMemory, episodeId: string, nowMs: number, friendMargins: readonly Margin[],
): Margin | undefined {
  const id = suggestion(memory, episodeId, nowMs);
  return id === undefined ? undefined : friendMargins.find((m) => m.id === id);
}
