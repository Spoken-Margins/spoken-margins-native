// An Apple Podcasts episode's audio, found in the show's own feed (#4783). Apple's public lookup lists a show's newest 200
// episodes, so an older episode (the owner's 2026-11-22 share was from 2019) is not in it, though the show's feed still holds it.
// The iPhone app falls back to the feed the same way (`PublicPodcastLinkResolver.resolveAppleLookup`).
//
// The match is by title, and only when it is certain: a title that names exactly one feed item. Two items with the same title
// (a rebroadcast, a re-upload) are never told apart by a guess, so neither is played. Plain TypeScript, no DOM.
import type { Episode } from '../shared/model.ts';

/**
 * What two spellings of one title share: accents folded, lower case, apostrophes and quotes dropped (`RFF's`, `RFF’s` and
 * `RFFs` are one word), dash variants made one, and commas, colons, brackets and the like read as a space, so the comma Apple's
 * page leaves out doesn't matter. Everything else stays, because it tells titles apart: the dot and slash in `Episode 1.5` and
 * `Mailbag 1/12`, the plus in `C++`, the ampersand, the spaces between words and numbers (`Part 1 2` is not `Part 12`), an emoji.
 */
export function titleKey(title: string): string {
  return title
    .normalize('NFKD')
    .replace(/\p{M}+/gu, '')
    .toLowerCase()
    .replace(/['`\u00b4\u2018\u2019\u201b\u02bc]/gu, '')
    .replace(/[\u2010-\u2015\u2212]/gu, '-')
    .replace(/[,;:!?()[\]{}"\u201c\u201d\u00ab\u00bb]/gu, ' ')
    .replace(/\s+/gu, ' ')
    .trim();
}

/**
 * The feed item whose title is `title`, or undefined when none is, or when more than one is (never a guess between them).
 * An item with no audio address can't be the answer, but it still counts toward "more than one": a twin with no audio makes
 * the title ambiguous all the same. The caller must pass items with no audio too (`keepWithoutAudio`), or a twin is not seen.
 */
export function episodeInFeed(episodes: readonly Episode[], title: string): Episode | undefined {
  const key = titleKey(title);
  if (key === '' || !/[\p{L}\p{N}]/u.test(key)) return undefined;
  const same = episodes.filter((episode) => titleKey(episode.title) === key);
  return same.length === 1 && same[0]?.audioUrl ? same[0] : undefined;
}
