// An Apple Podcasts episode's audio, found in the show's own feed (#4783). Apple's public lookup lists a show's newest 200
// episodes, so an older episode (the owner's 2026-11-22 share was from 2019) is not in it, though the show's feed still holds it.
// The iPhone app falls back to the feed the same way (`PublicPodcastLinkResolver.resolveAppleLookup`).
//
// The match is by title, and only when it is certain: a title that names exactly one feed item. Two items with the same title
// (a rebroadcast, a re-upload) are never told apart by a guess, so neither is played. Plain TypeScript, no DOM.
import type { Episode } from '../shared/model.ts';

/**
 * A title with everything that is not a letter or a number taken out, lower-cased, accents folded. Apple's page, a feed and the
 * packet word one title with different commas, apostrophes (' and ’), dashes and spacing; none of those names another episode.
 */
export function titleKey(title: string): string {
  return title
    .normalize('NFKD')
    .replace(/\p{M}+/gu, '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, '');
}

/**
 * The feed item whose title is `title`, or undefined when none is, or when more than one is (never a guess between them).
 * An item with no audio address can't be the answer, but it still counts toward "more than one": a twin with no audio makes
 * the title ambiguous all the same.
 */
export function episodeInFeed(episodes: readonly Episode[], title: string): Episode | undefined {
  const key = titleKey(title);
  if (key === '') return undefined;
  const same = episodes.filter((episode) => titleKey(episode.title) === key);
  return same.length === 1 && same[0]?.audioUrl ? same[0] : undefined;
}
