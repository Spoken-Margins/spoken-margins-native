import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Episode, Show } from '../../shared/model.ts';
import type { Dismissals } from '../store/schema.ts';
import {
  broughtBackRow,
  dismissedRow,
  findStoredShow,
  followedAgainRecord,
  followedShows,
  isDismissed,
  isFollowed,
  onShowList,
  refollowWrites,
  refreshable,
  restoredDismissal,
  unfollowedRecord,
  unfollowToast,
} from './follow-state.ts';

const NOW = '2026-11-25T18:00:00.000Z';
const EARLIER = '2026-11-01T00:00:00.000Z';
const FEED_ID = 'feed:https://feeds.test/show.rss';

function show(extra: Partial<Show> = {}): Show {
  return { id: FEED_ID, kind: 'podcast', title: 'Show', feedUrl: 'https://feeds.test/show.rss', followedAt: EARLIER, ...extra };
}
function ep(id: string, extra: Partial<Episode> = {}): Episode {
  return { id: `${FEED_ID}#${id}`, showId: FEED_ID, title: id, guid: id, audioUrl: `https://media.test/${id}.mp3`, ...extra };
}

test('isFollowed: a record with no mark is followed; one with the mark is not, and refresh skips it', () => {
  assert.equal(isFollowed(show()), true);
  assert.equal(refreshable(show()), true);
  const gone = show({ unfollowedAt: NOW });
  assert.equal(isFollowed(gone), false);
  assert.equal(refreshable(gone), false);
  assert.deepEqual(followedShows([show({ id: 'a' }), gone, show({ id: 'b' })]).map((s) => s.id), ['a', 'b']);
});

test('unfollow then follow again round-trips the record, and the key is deleted, never set to undefined', () => {
  const original = show({ author: 'A', refreshedAt: EARLIER });
  const marked = unfollowedRecord(original, NOW);
  assert.equal(marked.unfollowedAt, NOW);
  const back = followedAgainRecord(marked);
  assert.equal('unfollowedAt' in back, false);
  assert.deepEqual(back, original);
});

test('findStoredShow matches by id, then by the same feed address however it is spelled', () => {
  const stored = show({ feedUrl: 'http://www.feeds.test/show.rss/' });
  assert.equal(findStoredShow([stored], show({ id: FEED_ID })), stored);
  const other = { ...show({ id: 'feed:other', feedUrl: 'https://feeds.test/show.rss' }) };
  assert.equal(findStoredShow([stored], other), stored, 'http://www. and a trailing slash name the same feed');
  assert.equal(findStoredShow([stored], show({ id: 'feed:x', feedUrl: 'https://feeds.test/other.rss' })), undefined, 'a different path is another feed');
});

test('findStoredShow never matches two senders’ "Shared by" holders, nor any show with an empty address', () => {
  const ada: Show = show({ id: 'shared:Ada', title: 'Shared by Ada', feedUrl: '' });
  const nameless: Show = show({ id: 'shared:', title: 'Shared with you', feedUrl: '' });
  const bob: Show = show({ id: 'shared:Bob', title: 'Shared by Bob', feedUrl: '' });
  assert.equal(findStoredShow([ada, nameless], bob), undefined);
  assert.equal(findStoredShow([ada], nameless), undefined);
  assert.equal(findStoredShow([ada, bob], ada), ada, 'by id');
  // A feed show read with an empty address doesn't match a stored show that also has none.
  const emptyStored = show({ id: 'feed:empty', feedUrl: '' });
  assert.equal(findStoredShow([emptyStored], show({ id: 'feed:new', feedUrl: '' })), undefined);
  // Nor is a feed matched to a holder.
  assert.equal(findStoredShow([ada], show({ id: 'feed:y', feedUrl: '' })), undefined);
});

test('refollowWrites keeps stored ids, a found Substack voice, and resets followedAt only after an unfollow', () => {
  const voiced = ep('post', { audioUrl: 'https://substack.test/voice.mp3', audioOrigin: 'substack-voiceover' });
  const plain = ep('plain');
  const stored = show({ unfollowedAt: EARLIER });
  const readShow = show({ id: 'feed:read-id', feedUrl: 'https://feeds.test/show.rss' });
  const read = {
    show: readShow,
    episodes: [
      { id: 'feed:read-id#post', showId: readShow.id, title: 'post', guid: 'post' },
      { id: 'feed:read-id#plain', showId: readShow.id, title: 'plain', guid: 'plain', audioUrl: plain.audioUrl },
      { id: 'feed:read-id#fresh', showId: readShow.id, title: 'fresh', guid: 'fresh', audioUrl: 'https://media.test/fresh.mp3' },
    ],
  };
  const out = refollowWrites(stored, [voiced, plain], read, NOW);
  assert.equal(out.show.id, FEED_ID, 'the stored record is the one written');
  assert.equal('unfollowedAt' in out.show, false);
  assert.equal(out.show.followedAt, NOW);
  assert.equal(out.show.refreshedAt, NOW);
  const storedIds = new Set([voiced.id, plain.id]);
  for (const episode of out.episodes) {
    assert.ok(storedIds.has(episode.id) || episode.id.startsWith(`${FEED_ID}#`), episode.id);
    assert.equal(episode.showId, FEED_ID);
  }
  const post = out.episodes.find((e) => e.id === voiced.id);
  assert.ok(post === undefined || post.audioUrl === voiced.audioUrl, 'the voice found on an earlier tap is kept');
  assert.ok(out.episodes.some((e) => e.id === `${FEED_ID}#fresh`), 'a new episode takes the stored show’s id');

  const stillFollowed = refollowWrites(show(), [plain], read, NOW);
  assert.equal(stillFollowed.show.followedAt, EARLIER, 'a followed show keeps when it was first followed');
});

test('refollowWrites, a show an earlier build unfollowed: the read’s show stands in for the missing record', () => {
  const kept = ep('margined', { audioUrl: 'https://substack.test/found.mp3' });
  const readShow = show({ followedAt: NOW });
  const out = refollowWrites(readShow, [kept], { show: readShow, episodes: [{ id: kept.id, showId: FEED_ID, title: 'margined', guid: 'margined' }] }, NOW);
  assert.equal(out.show.id, FEED_ID);
  const written = out.episodes.find((e) => e.id === kept.id);
  assert.ok(written === undefined || written.audioUrl === kept.audioUrl);
});

test('restoredDismissal gives back what Dismiss replaced, or "not dismissed" when nothing was there', () => {
  const earlier = { dismissed: false, at: EARLIER };
  assert.deepEqual(restoredDismissal(earlier, NOW), earlier);
  assert.deepEqual(restoredDismissal(undefined, NOW), { dismissed: false, at: NOW });
  assert.deepEqual(dismissedRow(NOW), { dismissed: true, at: NOW });
  assert.deepEqual(broughtBackRow(NOW), { dismissed: false, at: NOW });
  // The same row each time, so a second tap writes the same thing.
  assert.deepEqual(dismissedRow(NOW), dismissedRow(NOW));
});

test('onShowList: listed unless dismissed, and always when in the Library (a finished one too)', () => {
  const dismissed: Dismissals = { [ep('d').id]: { dismissed: true, at: NOW }, [ep('back').id]: { dismissed: false, at: NOW } };
  const lib = new Set([ep('d-in').id]);
  const inLibrary = (id: string) => lib.has(id);
  const withD: Dismissals = { ...dismissed, [ep('d-in').id]: { dismissed: true, at: NOW } };
  assert.equal(onShowList(ep('plain'), withD, inLibrary), true, 'not dismissed, not in');
  assert.equal(onShowList(ep('d'), withD, inLibrary), false, 'dismissed, not in');
  assert.equal(onShowList(ep('d-in'), withD, inLibrary), true, 'dismissed, then added');
  assert.equal(onShowList(ep('back'), withD, inLibrary), true, 'brought back');
  assert.equal(onShowList(ep('finished', { durationSeconds: 60 }), withD, inLibrary), true);
  assert.equal(isDismissed('constructor', Object.create(null) as Dismissals), false, 'no inherited value');
});

test('unfollowToast: one row per string', () => {
  const base = { title: 'Show', shared: false, migrated: true, inLibrary: 0, leaving: 0, hasMargins: false };
  assert.equal(unfollowToast({ ...base, migrated: false }), 'Unfollowed Show. Its Margins stay in the Margins tab.');
  assert.equal(unfollowToast({ ...base, migrated: false, leaving: 1 }), 'Unfollowed Show. 1 episode leaves your Library. Its Margins stay in the Margins tab.');
  assert.equal(unfollowToast({ ...base, migrated: false, leaving: 3 }), 'Unfollowed Show. 3 episodes leave your Library. Its Margins stay in the Margins tab.');
  assert.equal(unfollowToast({ ...base, shared: true, inLibrary: 1 }), 'Unfollowed Show. Its items stay in your Library.');
  assert.equal(unfollowToast({ ...base, inLibrary: 2 }), 'Unfollowed Show. What you added to your Library stays there.');
  assert.equal(unfollowToast({ ...base, hasMargins: true }), 'Unfollowed Show. Its Margins stay in the Margins tab.');
  assert.equal(unfollowToast(base), 'Unfollowed Show.');
});
