// "Send" on the web hands the packet to the browser's share sheet. A browser may refuse that (#4095): Chrome on Android
// answers a `navigator.share` that runs after a slow packet write with a not-allowed error, because the tap is no longer
// fresh, and the listener read the browser's own words, "Permission denied". The outcome is one of three things the screen
// acts on; the browser's wording never reaches the listener. Plain TypeScript, so `npm run test:web` covers it.
import { friendNames, type ReplyBackOffer } from './reply-back.ts';

export type SendOutcome = 'shared' | 'cancelled' | 'refused';

/**
 * Offers the file to the share sheet. `cancelled` is the listener closing the sheet, which is no failure. Any other
 * refusal (NotAllowedError, SecurityError, TypeError, DataError, whatever the browser throws) is `refused`: the listener
 * can do the same thing about all of them, which is to save the file and send it themselves.
 */
export async function sendFile(
  share: (data: { files: File[]; title: string }) => Promise<void>,
  file: File,
  title: string,
): Promise<SendOutcome> {
  try {
    await share({ files: [file], title });
    return 'shared';
  } catch (error) {
    if (typeof error === 'object' && error !== null && (error as { name?: unknown }).name === 'AbortError') return 'cancelled';
    return 'refused';
  }
}

/**
 * What to tell the listener when the browser refused the share sheet: why Send is gone and what to do instead. It names
 * the friend when the episode has a friend's Margins, as the saved-file sentence does (#3784).
 */
export function sendRefusedNextStep(offer: ReplyBackOffer | undefined): string {
  const whom = offer ? friendNames(offer.friendLabels) : undefined;
  return `This browser wouldn’t open its share sheet. Tap Save as a file, then send the file${whom ? ` to ${whom}` : ''} in a message.`;
}
