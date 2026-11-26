// Help for someone a friend sent Margins to (#5268): the site's `friends/` page, opened in a new tab from the card
// where a link got stuck, at the question that card raises. The page's anchors are the app's `FriendHelpTopic` ids.
import type { ShareLinkFailure } from './share-link.ts';

export type FriendHelpTopic = 'wont-open' | 'cant-hear';

export const FRIEND_HELP_URL = 'https://spokenmargins.com/friends/';

export const FRIEND_HELP_WORDS = { get: 'Get help', footer: 'Help' } as const;

export function friendHelpHref(topic?: FriendHelpTopic): string {
  return topic ? `${FRIEND_HELP_URL}#${topic}` : FRIEND_HELP_URL;
}

/** The question a link that wouldn't open raises. Offline gets none: the page can't load, and the card says what to do. */
export function friendHelpForFailure(reason: ShareLinkFailure): FriendHelpTopic | null {
  return reason === 'offline' ? null : 'wont-open';
}
