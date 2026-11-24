import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Episode, Margin, PlaybackPosition, Show } from '../../shared/model.ts';
import {
  followingMatches,
  followingRows,
  libraryRowMatches,
  marginAuthors,
  libraryRows,
  marginGroups,
  marginMatches,
  newestFirst,
  newestMarginId,
  startsCollapsed,
  nextSpeed,
  stableId,
  timelineFraction,
  timelinePosts,
  FINISHED_WITHIN_SECONDS,
} from './library.ts';

const show = (id: string, title: string): Show => ({ id, kind: 'podcast', title, feedUrl: `https://e.test/${id}`, followedAt: '2026-10-01T00:00:00Z' });
const ep = (id: string, showId: string, publishedAt?: string, durationSeconds?: number): Episode => ({ id, showId, title: `Ep ${id}`, publishedAt, durationSeconds });
const pos = (episodeId: string, seconds: number): PlaybackPosition => ({ episodeId, seconds, updatedAt: '2026-10-30T00:00:00Z' });
const margin = (id: string, episodeId: string, atSeconds: number, createdAt: string): Margin => ({ id, episodeId, atSeconds, createdAt, text: id });

test('newestFirst puts the newest published first and undated last', () => {
  const list = newestFirst([
    ep('a', 's', '2026-09-24T10:00:00Z'),
    ep('undated', 's'),
    ep('c', 's', '2026-09-26T10:00:00Z'),
    ep('bad-date', 's', 'not a date'),
    ep('b', 's', '2026-09-25T10:00:00Z'),
  ]);
  assert.deepEqual(list.map((e) => e.id), ['c', 'b', 'a', 'bad-date', 'undated']);
});

test('libraryRows shows resume positions only for started episodes, and hides unfollowed shows', () => {
  const rows = libraryRows(
    [ep('new', 's1', '2026-10-03', 600), ep('half', 's1', '2026-10-02', 600), ep('done', 's1', '2026-10-01', 600), ep('orphan', 'gone', '2026-10-04')],
    [show('s1', 'One')],
    [pos('half', 300), pos('done', 595)],
  );
  assert.deepEqual(
    rows.map((r) => [r.episode.id, r.state, r.resumeAt, r.progress]),
    [
      ['new', 'new', undefined, undefined],
      ['half', 'started', 300, 0.5],
      ['done', 'finished', undefined, 595 / 600],
    ],
  );
});

test('followingRows sorts shows by their newest episode and counts unstarted ones', () => {
  const rows = followingRows(
    [show('quiet', 'Quiet'), show('busy', 'Busy'), show('empty', 'Empty')],
    [ep('q1', 'quiet', '2026-09-01'), ep('b1', 'busy', '2026-10-01'), ep('b2', 'busy', '2026-10-02'), ep('b3', 'busy', '2026-10-03')],
    [pos('b3', 10)],
  );
  assert.deepEqual(rows.map((r) => [r.show.id, r.newest?.id, r.newCount]), [
    ['busy', 'b3', 2],
    ['quiet', 'q1', 1],
    ['empty', undefined, 0],
  ]);
});

test('marginGroups puts the group with the newest Margin first, Margins in audio order', () => {
  const margins = [
    margin('old-late', 'e1', 900, '2026-10-01T00:00:00Z'),
    margin('newest', 'e2', 50, '2026-10-30T00:00:00Z'),
    margin('old-early', 'e1', 10, '2026-10-02T00:00:00Z'),
    margin('e2-early', 'e2', 5, '2026-09-01T00:00:00Z'),
  ];
  const groups = marginGroups(margins, [ep('e1', 's'), ep('e2', 's')]);
  assert.deepEqual(groups.map((g) => [g.episodeId, g.margins.map((m) => m.id)]), [
    ['e2', ['e2-early', 'newest']],
    ['e1', ['old-early', 'old-late']],
  ]);
  assert.equal(newestMarginId(margins), 'newest');
  assert.equal(newestMarginId([]), undefined);
});

test('nextSpeed cycles and resets unknown speeds to 1x', () => {
  assert.equal(nextSpeed(1), 1.25);
  assert.equal(nextSpeed(2), 0.8);
  assert.equal(nextSpeed(3.3), 1);
});

test('timelineFraction clamps and tolerates unknown durations', () => {
  assert.equal(timelineFraction(30, 60), 0.5);
  assert.equal(timelineFraction(90, 60), 1);
  assert.equal(timelineFraction(-5, 60), 0);
  assert.equal(timelineFraction(30, undefined), 0);
  assert.equal(timelineFraction(30, Number.NaN), 0);
});

test('stableId is stable and differs for different inputs', () => {
  assert.equal(stableId('https://e.test/feed'), stableId('https://e.test/feed'));
  assert.notEqual(stableId('https://e.test/feed'), stableId('https://e.test/feed2'));
  assert.match(stableId(''), /^[0-9a-f]{8}$/);
  // Pinned: ids are stored, so a change to the hash would orphan every saved show and episode.
  assert.equal(stableId(''), '811c9dc5');
  assert.equal(stableId('a'), 'e40c292c');
});

test('an episode counts as finished only within the last FINISHED_WITHIN_SECONDS', () => {
  assert.equal(FINISHED_WITHIN_SECONDS, 15);
  const shows = [show('s', 'Show')];
  const state = (seconds: number) => libraryRows([ep('e', 's', '2026-10-01T00:00:00Z', 600)], shows, [pos('e', seconds)])[0].state;
  assert.equal(state(584), 'started');
  assert.equal(state(585), 'finished');
  assert.equal(state(586), 'finished');
});

test('timelinePosts shares a post between Margins closer than the gap, and keeps the rest apart', () => {
  const ms = [margin('c', 'e', 300, 'x'), margin('a', 'e', 10, 'x'), margin('b', 'e', 12, 'x'), margin('d', 'e', 330, 'x')];
  assert.deepEqual(
    timelinePosts(ms, 600, 0.1).map((p) => [p.atSeconds, p.margins.map((m) => m.id)]),
    [
      [10, ['a', 'b']],
      [300, ['c', 'd']],
    ],
  );
  // Far enough apart, each Margin keeps its own post.
  assert.equal(timelinePosts(ms, 600, 0.001).length, 4);
  // Unknown duration: everything sits at the start, on one post.
  assert.equal(timelinePosts(ms, undefined, 0.1).length, 1);
});

test('a Library search finds an item by its title, its show, or the friend who left a Margin on it (#4422)', () => {
  const shows = [show('lemon', 'The Lemonade Stand'), show('shared:Priya', 'Shared by Priya')];
  const episodes = [ep('1', 'lemon'), { ...ep('2', 'shared:Priya'), title: 'A friend’s find' }];
  const margins: Margin[] = [{ ...margin('m', '2', 5, '2026-11-01T00:00:00Z'), author: 'Priya' }];
  const rows = libraryRows(episodes, shows, []);
  const authors = marginAuthors(margins);
  const found = (query: string) => rows.filter((r) => libraryRowMatches(query, r, authors)).map((r) => r.episode.id);
  assert.equal(found('').length, 2, 'no query shows everything');
  assert.deepEqual(found('lemonade'), ['1'], 'by show');
  assert.deepEqual(found('ep 1'), ['1'], 'by title');
  assert.deepEqual(found('FRIEND’S'), ['2'], 'by title, any case');
  assert.deepEqual(found('priya'), ['2'], 'by the sender, through the Margin or the shared show');
  assert.deepEqual(found('zzz'), []);
});

test('a few Margins groups all start open; a long list opens on the newest only (#4423)', () => {
  for (const total of [0, 1, 2, 3]) {
    for (let index = 0; index < total; index += 1) assert.equal(startsCollapsed(index, total), false, `${index} of ${total}`);
  }
  assert.equal(startsCollapsed(0, 4), false, 'the newest group is always open');
  for (const index of [1, 2, 3, 49]) assert.equal(startsCollapsed(index, 50), true, `group ${index} of 50`);
});

// #4427 PR 1: what a Following or Margins search keeps. Neighbouring inputs per the parsing-bug rule in AGENTS.md.
const named = (id: string, showId: string, title: string, publishedAt?: string): Episode => ({ id, showId, title, publishedAt });
const authored = (s: Show, author: string): Show => ({ ...s, author });

function followingFixture() {
  const shows = [authored(show('lemon', 'Lemonade Hour'), 'Ana Núñez'), show('turnip', 'Turnip Talk'), show('quiet', 'Ｑｕｉｅｔ Ｒｏｏｍ')];
  const episodes = [
    named('l1', 'lemon', 'Squeezing the first batch', '2026-10-01T00:00:00Z'),
    named('l2', 'lemon', 'Crème brûlée and citrus', '2026-10-05T00:00:00Z'),
    named('t1', 'turnip', 'Winter soup', '2026-10-03T00:00:00Z'),
    named('t2', 'turnip', 'Lemonade, but savoury', '2026-10-04T00:00:00Z'),
    named('q1', 'quiet', 'Nothing much', '2026-09-01T00:00:00Z'),
  ];
  return followingRows(shows, episodes, []);
}

test('a blank Following search keeps every show in order and lists no episodes (#4427)', () => {
  const rows = followingFixture();
  for (const query of ['', '   ', '\t\n']) {
    const found = followingMatches(query, rows);
    assert.deepEqual(found.shows.map((r) => r.show.id), rows.map((r) => r.show.id), JSON.stringify(query));
    assert.deepEqual(found.episodes, []);
  }
});

test('a Following search matches shows on title or author, and episodes on their own title only (#4427)', () => {
  const rows = followingFixture();
  const ids = (query: string) => {
    const found = followingMatches(query, rows);
    return { shows: found.shows.map((r) => r.show.id), episodes: found.episodes.map((e) => e.id) };
  };
  // A show's name lists the show, not its episodes; an episode titled with it is listed for its own title.
  assert.deepEqual(ids('lemonade'), { shows: ['lemon'], episodes: ['t2'] });
  // Case, white space and accents fold away.
  assert.deepEqual(ids('  LEMONADE   hour '), { shows: ['lemon'], episodes: [] });
  assert.deepEqual(ids('creme brulee'), { shows: [], episodes: ['l2'] });
  // Full-width letters match plain ones, both ways.
  assert.deepEqual(ids('quiet room'), { shows: ['quiet'], episodes: [] });
  assert.deepEqual(ids('ｗｉｎｔｅｒ'), { shows: [], episodes: ['t1'] });
  // A show matched by its author; an author never lists the show's episodes.
  assert.deepEqual(ids('ana nunez'), { shows: ['lemon'], episodes: [] });
  // An episode matched while its show isn't.
  assert.deepEqual(ids('soup'), { shows: [], episodes: ['t1'] });
  // Episodes from every show, newest first.
  assert.deepEqual(ids('e'), { shows: ['lemon', 'quiet'], episodes: ['l2', 't2', 't1', 'l1'] });
  assert.deepEqual(ids('zzzz'), { shows: [], episodes: [] });
});

test('an episode held by two Following rows is listed once (#4427)', () => {
  const one = named('dup', 'a', 'Shared episode', '2026-10-01T00:00:00Z');
  const rows = [
    { show: show('a', 'A'), newest: one, episodes: [one], newCount: 1 },
    { show: show('b', 'B'), newest: one, episodes: [one, named('other', 'b', 'Shared, again', '2026-09-01T00:00:00Z')], newCount: 2 },
  ];
  assert.deepEqual(followingMatches('shared', rows).episodes.map((e) => e.id), ['dup', 'other']);
});

function marginsFixture() {
  const shows = [show('s1', 'Garden Radio'), show('s2', 'Kitchen Notes')];
  const episodes = [named('e1', 's1', 'Planting in autumn'), named('e2', 's2', 'Stocks and broths'), named('e3', 's1', 'Seeds')];
  const m = (id: string, episodeId: string, at: number, createdAt: string, extra: Partial<Margin>): Margin => ({
    id, episodeId, atSeconds: at, createdAt, ...extra,
  });
  const margins = [
    m('a1', 'e1', 10, '2026-10-01T00:00:00Z', { text: 'Plant garlic now' }),
    m('a2', 'e1', 20, '2026-10-02T00:00:00Z', { text: 'Mulch', author: 'Sam Example' }),
    m('b1', 'e2', 5, '2026-10-05T00:00:00Z', { text: 'Turnip soup, roasted first' }),
    m('b2', 'e2', 15, '2026-10-04T00:00:00Z', { text: 'Salt late' }),
    // A voice Margin with no transcript: no text to match.
    m('b3', 'e2', 25, '2026-10-03T00:00:00Z', { voice: { blob: new Blob(), mimeType: 'audio/mp4', durationSeconds: 3 } }),
    m('c1', 'e3', 1, '2026-09-01T00:00:00Z', { text: 'Gone' }),
    // On an episode no longer stored: its group has no episode and no show.
    m('x1', 'missing', 1, '2026-09-02T00:00:00Z', { text: 'Orphan note' }),
  ];
  const groups = marginGroups(margins, episodes);
  const titleById = new Map(shows.map((s) => [s.id, s.title]));
  const showTitle = (id: string | undefined) => (id ? titleById.get(id) : undefined);
  return { groups, showTitle };
}

test('a blank Margins search keeps every group with all its Margins, not by title (#4427)', () => {
  const { groups, showTitle } = marginsFixture();
  for (const query of ['', '  ']) {
    const found = marginMatches(query, groups, showTitle);
    assert.deepEqual(found.map((f) => f.group.episodeId), groups.map((g) => g.episodeId));
    assert.ok(found.every((f, i) => f.margins === groups[i].margins && !f.byTitle));
  }
});

test('a Margins search keeps whole groups matched by title and only the matching Margins elsewhere (#4427)', () => {
  const { groups, showTitle } = marginsFixture();
  const shape = (query: string) =>
    marginMatches(query, groups, showTitle).map((f) => `${f.group.episodeId}${f.byTitle ? '*' : ''}:${f.margins.map((m) => m.id).join(',')}`);
  // By transcript or written text, case folded; the voice Margin with no text is left out.
  assert.deepEqual(shape('TURNIP'), ['e2:b1']);
  // By author.
  assert.deepEqual(shape('sam example'), ['e1:a2']);
  // Accents and full-width letters fold away, as in Following.
  assert.deepEqual(shape('sám ÉXAMPLE'), ['e1:a2']);
  assert.deepEqual(shape('ｇａｒｌｉｃ'), ['e1:a1']);
  // By episode title: the whole group, including the voice Margin with no text.
  assert.deepEqual(shape('stocks'), ['e2*:b1,b2,b3']);
  // By show title: every group of that show, whole, in the input's order (newest first).
  assert.deepEqual(shape('garden radio'), ['e1*:a1,a2', 'e3*:c1']);
  // Several groups by text, newest group first, Margins in audio order.
  assert.deepEqual(shape('l'), ['e2:b2', 'e1*:a1,a2']);
  // The screen's stand-in titles for a missing episode or show never match; the Margin's own text still does.
  assert.deepEqual(shape('unfollowed show'), []);
  assert.deepEqual(shape('no longer in your library'), []);
  assert.deepEqual(shape('orphan'), ['missing:x1']);
  assert.deepEqual(shape('zzzz'), []);
});

test('Following and Margins searches keep their counts and order on a long source (#4427)', () => {
  const shows = Array.from({ length: 40 }, (_, i) => show(`s${i}`, `Show ${i}${i % 10 === 0 ? ' harbour' : ''}`));
  const episodes: Episode[] = [];
  for (let i = 0; i < 20_000; i += 1) {
    const day = String(1 + (i % 28)).padStart(2, '0');
    episodes.push(named(`e${i}`, `s${i % 40}`, `Episode ${i}${i % 100 === 0 ? ' harbour' : ''}`, `2026-10-${day}T${String(i % 24).padStart(2, '0')}:00:00Z`));
  }
  const rows = followingRows(shows, episodes, []);
  const found = followingMatches('HARBOUR', rows);
  assert.equal(found.shows.length, 4);
  assert.equal(found.episodes.length, 200);
  for (let i = 1; i < found.episodes.length; i += 1) {
    assert.ok(Date.parse(found.episodes[i - 1].publishedAt!) >= Date.parse(found.episodes[i].publishedAt!), 'newest first');
  }

  const margins: Margin[] = [];
  for (let i = 0; i < 5_000; i += 1) {
    margins.push({ id: `m${i}`, episodeId: `e${i % 500}`, atSeconds: i, createdAt: new Date(Date.UTC(2026, 9, 1) + i * 60_000).toISOString(), text: i % 50 === 0 ? 'Harbour lights' : `Note ${i}` });
  }
  const groups = marginGroups(margins, episodes);
  const titleById = new Map(shows.map((s) => [s.id, s.title]));
  const matches = marginMatches('harbour lights', groups, (id) => (id ? titleById.get(id) : undefined));
  // Margins with "Harbour lights" sit on episodes e0, e50, … e450 (i % 50 === 0 → episode i % 500): 10 groups of 10.
  assert.equal(matches.length, 10);
  assert.ok(matches.every((f) => !f.byTitle && f.margins.length === 10));
  assert.deepEqual(matches.map((f) => f.group.episodeId), groups.map((g) => g.episodeId).filter((id) => matches.some((f) => f.group.episodeId === id)));
});
