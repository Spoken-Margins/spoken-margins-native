// The shows suggested to a new listener (#3610): one tap follows one, with nothing to look up or paste.
//
// A hand-picked list, written out here, never read from the network or from Apple's charts: Apple's terms for
// showing a chart-derived list on a public page are unchecked, so none of the iPhone app's catalog is used
// (`Contracts/schemas/source-catalog.schema.json`). These four are the owner's call (2026-11-06, #3610). A name
// beyond them goes back to him; one that stops playing for a new listener is taken out and said on the issue.
//
// No artwork on purpose: showing the list must not make the browser contact any publisher before the listener taps
// (Settings → Privacy says episodes and feeds are fetched only on the listener's action, #2842). A row without
// `artworkUrl` draws the show's letter, as the Following list does for a show with none.

export interface SuggestedShow {
  /** Shown as the row's title. */
  title: string;
  /** One short line on what the show is, not a claim about its episodes. */
  about: string;
  kind: 'podcast' | 'substack';
  /** The feed the follow reads, the same address the Follow sheet takes. Always https. */
  feedUrl: string;
}

export const SUGGESTED_SHOWS: readonly SuggestedShow[] = [
  {
    title: 'Dwarkesh Podcast',
    about: 'Long interviews on AI, history and how the world works.',
    kind: 'podcast',
    feedUrl: 'https://dwarkesh.com/feed',
  },
  {
    title: 'Lenny’s Newsletter',
    about: 'Product, growth and careers, with interviews.',
    kind: 'substack',
    feedUrl: 'https://lennysnewsletter.com/feed',
  },
  {
    title: 'Letters from an American',
    about: 'A daily letter on US politics, read through its history.',
    kind: 'substack',
    feedUrl: 'https://heathercoxrichardson.substack.com/feed',
  },
  {
    title: 'The Pragmatic Engineer',
    about: 'How software is built at big and small companies.',
    kind: 'substack',
    feedUrl: 'https://newsletter.pragmaticengineer.com/feed',
  },
];

/** The suggestions the listener doesn't follow yet, in list order. */
export function suggestionsToShow(followedFeedUrls: Iterable<string>): SuggestedShow[] {
  const followed = new Set([...followedFeedUrls].map(normalize));
  return SUGGESTED_SHOWS.filter((show) => !followed.has(normalize(show.feedUrl)));
}

/**
 * Two spellings of one feed address compare equal: the host's case, `www.`, a trailing slash and the scheme don't
 * tell feeds apart. `dwarkesh.com/feed` redirects to `www.dwarkesh.com/feed`, and a feed followed from a search
 * result may carry either.
 */
function normalize(feedUrl: string): string {
  try {
    const url = new URL(feedUrl);
    const host = url.hostname.toLowerCase().replace(/^www\./, '');
    return `${host}${url.pathname.replace(/\/+$/, '')}${url.search}`;
  } catch {
    return feedUrl.trim().toLowerCase();
  }
}
