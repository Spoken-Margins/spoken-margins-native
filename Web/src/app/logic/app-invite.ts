// The one invitation to the iPhone app after a friend's first reply leaves this browser (#4671). The web app is a taster:
// its job is to get the first Margin heard and answered, then hand the person to the app (onboarding direction,
// 2026-11-18). This is the decision alone, with no DOM, so `npm run test:web` covers it (app-invite.test.ts).
//
// It shows once per browser: the first time it shows counts as seen, so a reload or a second reply never brings it back,
// and dismissing it changes nothing further. Where storage is blocked it can only be once per page, which the screen keeps.
import { GET_APP_LINK } from './arrival.ts';

/** The slice of `localStorage` this needs, so a test can hand it a map. */
export interface InviteStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export const APP_INVITE_KEY = 'spokenMargins.appInviteSeen';

/** How a share ended, in the screen's words: the sheet finished, the file downloaded, the sheet closed, or the browser refused it. */
export type ShareEnd = 'shared' | 'saved' | 'cancelled' | 'refused';

export interface ShareEvent {
  /** The Share panel had a friend's Margins to answer, so what left is a reply. */
  readonly wasReply: boolean;
  readonly outcome: ShareEnd;
  /** Running inside the Android app (Capacitor), where an iPhone invitation makes no sense. */
  readonly inApp: boolean;
}

/** Industry-standard wording (owner, 2026-11-09); the app does not open the web's whole backup `.zip` in one step yet. */
export const APP_INVITE_WORDS = Object.freeze({
  heading: 'Get the iPhone app',
  adds: 'The app plays your podcasts and articles with Margins wherever you listen, and keeps every reply in one place.',
  tapAgain: 'After installing, tap your friend’s link again to open it in the app.',
  moveMargins: 'To move this browser’s Margins, use Back up all Margins in Settings, then open each file in the app. One file per item: the app doesn’t open the whole backup at once yet.',
  dismiss: 'Not now',
  button: GET_APP_LINK,
});

function seen(storage: InviteStorage | undefined): boolean {
  try {
    return storage?.getItem(APP_INVITE_KEY) != null;
  } catch {
    return false;
  }
}

/** Remembers that the invitation was shown or dismissed. Blocked storage is not an error: it just can't be remembered. */
export function markInviteSeen(storage: InviteStorage | undefined): void {
  try {
    storage?.setItem(APP_INVITE_KEY, '1');
  } catch {
    // Storage blocked or full: the screen still hides it for the rest of the page.
  }
}

/** Whether this share shows the invitation. When it does, it is marked seen at once, so it never shows twice. */
export function inviteAfterShare(storage: InviteStorage | undefined, event: ShareEvent): boolean {
  if (event.inApp || !event.wasReply) return false;
  if (event.outcome !== 'shared' && event.outcome !== 'saved') return false;
  if (seen(storage)) return false;
  markInviteSeen(storage);
  return true;
}
