// The web app's shared data model. Every module (`app`, `sources`, `packet`) imports these types and no
// module redefines them, so threads working in parallel agree on shapes. Field names follow the app's
// contracts where one exists (`Contracts/schemas/`); `packet` maps between these and the packet format.
//
// Logic modules are plain TypeScript run by Node 24's type stripping: erasable syntax only (no `enum`,
// no `namespace`, no parameter properties), and relative imports carry their `.ts` extension.

/** A podcast or Substack publication the listener follows. */
export interface Show {
  id: string;
  kind: 'podcast' | 'substack';
  title: string;
  author?: string;
  /** The RSS feed. A Substack's is `https://<name>.substack.com/feed`. */
  feedUrl: string;
  /** The show's own web page, when the feed names one. */
  siteUrl?: string;
  artworkUrl?: string;
  /** iTunes collection id, when the show came from search. */
  itunesId?: number;
  followedAt: string;
  /** When the feed was last read successfully by a refresh (#2977). Unset until the first refresh after following. */
  refreshedAt?: string;
}

/** Where an episode's audio comes from. Substack posts play the publisher's or Substack's own voice. */
export type AudioOrigin = 'podcast-enclosure' | 'substack-voiceover' | 'substack-generated-voice';

/** One playable episode or Substack post. */
export interface Episode {
  id: string;
  showId: string;
  title: string;
  /** The feed item's guid, the strongest identity when packets are matched across devices. */
  guid?: string;
  /** The episode's or post's public page. */
  pageUrl?: string;
  /** Unset for a Substack post whose voice is found only when the listener taps it. */
  audioUrl?: string;
  audioOrigin?: AudioOrigin;
  durationSeconds?: number;
  publishedAt?: string;
}

/** A Margin, anchored by time in its episode's audio. */
export interface Margin {
  id: string;
  episodeId: string;
  /** Seconds into the episode's audio where the Margin sits. */
  atSeconds: number;
  createdAt: string;
  /** Written text, or the transcript of a voice Margin when one exists. */
  text?: string;
  /** A voice Margin's audio. Packets carry only AAC in an `.m4a` container. */
  voice?: { blob: Blob; mimeType: string; durationSeconds: number };
  /** Set on Margins imported from someone else's packet. */
  author?: string;
  /** The Margin this one answers (2026-10-25 call: recorded during a friend's Margin = a reply). */
  replyToId?: string;
}

/** Where the listener left off in an episode. */
export interface PlaybackPosition {
  episodeId: string;
  seconds: number;
  updatedAt: string;
}
