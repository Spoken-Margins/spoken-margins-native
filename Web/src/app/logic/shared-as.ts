// Which of the listener's Margins went out in a packet, and under what name (#4174). A friend's reply to one of them
// names it `packet:<digest of the packet it travelled in>:margin-000N` as its `replyToId`. The app keeps that on the
// Margin as `sharedAs` when the packet file is built; the web keeps it the same way, so a reply that comes back can be
// found under the Margin it answers. Plain TypeScript, covered by shared-as.test.ts.
import type { Margin } from '../../shared/model.ts';
import { packetMarginId } from '../../packet/read.ts';
import { scopedMarginId } from '../../packet/write.ts';

/** What the writer says about a packet it wrote: its digest, and the Margins in it in the order it named them. */
export interface WrittenFacts {
  contentDigest: string;
  included: readonly string[];
}

/**
 * A rewritten Margin keeps the links the stored one has. The voice composer keeps its own copy of the Margin it saved and
 * writes it again when the words arrive or the reply link changes; that older copy must not drop a packet the Margin
 * was shared in since (the same rule as `keepingStar`). Every link of either is kept, none twice; their order is not meaningful.
 */
export function keepingSharedAs(margin: Margin, stored: Margin | undefined): Margin {
  if (!stored?.sharedAs?.length) return margin;
  const merged = [...new Set([...stored.sharedAs, ...(margin.sharedAs ?? [])])];
  return merged.length === margin.sharedAs?.length ? margin : { ...margin, sharedAs: merged };
}

/**
 * The Margins to store again with the packet they just went out in added to their `sharedAs`. A Margin `written` names
 * that is not in `margins`, or already carries this link (the same file written twice), is left out. A packet written
 * again is a new digest, so a Margin shared twice carries both links and a reply to either finds it.
 */
export function withSharedAs(written: WrittenFacts, margins: readonly Margin[]): Margin[] {
  const byId = new Map(margins.map((m) => [m.id, m]));
  const stamped: Margin[] = [];
  written.included.forEach((id, index) => {
    const margin = byId.get(id);
    if (!margin) return;
    const link = packetMarginId(written.contentDigest, scopedMarginId(index));
    if (margin.sharedAs?.includes(link)) return;
    stamped.push({ ...margin, sharedAs: [...(margin.sharedAs ?? []), link] });
  });
  return stamped;
}
