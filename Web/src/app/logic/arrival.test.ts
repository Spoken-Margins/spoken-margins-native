import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Margin } from '../../shared/model.ts';
import {
  ARRIVAL_WORDS,
  LEAD_IN_SECONDS,
  arrivalFacts,
  countdownClock,
  countdownSpoken,
  friendMargins,
  cueFor,
  marginsSeconds,
  readsAloud,
  senderInitial,
  senderName,
  speakingLine,
  stopsPlayback,
  writtenIntro,
} from './arrival.ts';

const voice = (seconds: number) => ({ blob: new Blob(['x']), mimeType: 'audio/mp4', durationSeconds: seconds });
const margin = (id: string, atSeconds: number, opts: { spoken?: boolean; author?: string | null } = {}): Margin => ({
  id,
  episodeId: 'e',
  atSeconds,
  createdAt: '2026-11-02T10:00:00Z',
  text: `words ${id}`,
  ...(opts.spoken && { voice: voice(40) }),
  ...(opts.author !== null && { author: opts.author ?? 'Cole' }),
});

test('the sender leads; no name reads "your friend"; the initial is a letter, never the markup of a hostile name', () => {
  assert.equal(senderName('Cole'), 'Cole');
  assert.equal(senderName('  Cole  '), 'Cole');
  assert.equal(senderName(undefined), 'your friend');
  assert.equal(senderName('   '), 'your friend');
  assert.equal(senderInitial('cole'), 'C');
  assert.equal(senderInitial('École'), 'É');
  assert.equal(senderInitial('😀 Cole'), '😀');
  assert.equal(senderInitial(undefined), '•');
  // A name is data: it passes through untouched, for React to draw as text.
  assert.equal(senderName('<img src=x onerror=alert(1)>'), '<img src=x onerror=alert(1)>');
});

test('"Margin" is explained in two versions, by whether any is written (2026-11-02 call)', () => {
  const spoken = arrivalFacts('Cole', [margin('a', 760, { spoken: true }), margin('b', 900, { spoken: true })]);
  assert.equal(spoken.explanation, 'A Margin is a voice note Cole left at a moment in this episode.');
  const mixed = arrivalFacts('Cole', [margin('a', 760, { spoken: true }), margin('b', 900)]);
  assert.equal(mixed.explanation, 'A Margin is a note Cole left at a moment in this episode. You’ll hear each one there.');
  assert.equal(arrivalFacts(undefined, [margin('a', 1, { spoken: true })]).explanation, 'A Margin is a voice note your friend left at a moment in this episode.');
});

test('the count line says how many and about how long', () => {
  const three = [margin('a', 1, { spoken: true }), margin('b', 2), margin('c', 3, { spoken: true })];
  // 40 + 8 + 40 = 88 seconds
  assert.equal(arrivalFacts('Cole', three).countLine, '3 Margins · about 1 min');
  assert.equal(arrivalFacts('Cole', [margin('a', 1)]).countLine, '1 Margin · under a minute');
  const long = Array.from({ length: 5 }, (_, i) => margin(`m${i}`, i * 100, { spoken: true }));
  assert.equal(arrivalFacts('Cole', long).countLine, '5 Margins · about 3 min');
});

test('the countdown reads in minutes while far off and in clock seconds in the last minute', () => {
  assert.equal(countdownClock(11 * 60 + 28), '12 min');
  assert.equal(countdownClock(61), '2 min');
  assert.equal(countdownClock(60), '1 min');
  assert.equal(countdownClock(59), '0:59');
  assert.equal(countdownClock(20), '0:20');
  assert.equal(countdownClock(0.2), '0:01');
  assert.equal(countdownClock(-3), '0:00');
  assert.equal(countdownSpoken(11 * 60), '11 minutes');
  assert.equal(countdownSpoken(60), '1 minute');
  assert.equal(countdownSpoken(20), 'less than a minute');
});

test('far from the first Margin, Skip lands 20 seconds before it; inside the lead-in, Skip goes straight to it', () => {
  const m = [margin('a', 760), margin('b', 1500), margin('c', 2400)];
  const far = cueFor(m, 72, 'Cole');
  assert.equal(far?.kind, 'countdown');
  if (far?.kind !== 'countdown') return;
  assert.equal(far.label, 'Cole’s first Margin in');
  assert.equal(far.clock, '12 min');
  assert.equal(far.skip.label, 'Skip to just before Cole');
  assert.equal(far.skip.to, 760 - LEAD_IN_SECONDS);
  assert.equal(far.leadIn, false);

  const near = cueFor(m, 760 - LEAD_IN_SECONDS, 'Cole');
  if (near?.kind !== 'countdown') return assert.fail('no countdown');
  assert.equal(near.clock, '0:20');
  assert.equal(near.leadIn, true);
  assert.equal(near.skip.label, 'Skip to Cole now');
  // A hair before the moment, so playback crosses it and the Margin fires.
  assert.ok(near.skip.to < 760 && near.skip.to > 759);
});

test('the pair of Skips is reachable from the start: the first lands inside the lead-in, so the second shows', () => {
  const m = [margin('a', 760)];
  const first = cueFor(m, 0, 'Cole');
  if (first?.kind !== 'countdown') return assert.fail('no countdown');
  const second = cueFor(m, first.skip.to, 'Cole');
  if (second?.kind !== 'countdown') return assert.fail('no countdown');
  assert.equal(second.leadIn, true);
  assert.equal(second.skip.label, 'Skip to Cole now');
});

test('first, next, last, then a pointer at the player’s own Margin buttons', () => {
  const m = [margin('a', 100), margin('b', 400), margin('c', 800)];
  const label = (t: number) => {
    const cue = cueFor(m, t, 'Cole');
    return cue?.kind === 'countdown' ? cue.label : cue?.kind;
  };
  assert.equal(label(0), 'Cole’s first Margin in');
  assert.equal(label(150), 'Cole’s next Margin in');
  assert.equal(label(450), 'Cole’s last Margin in');
  assert.equal(label(801), 'after-last');
  assert.equal(label(100.2), 'Cole’s next Margin in', 'the one just crossed is no longer upcoming');
  const only = cueFor([margin('only', 100)], 0, 'Cole');
  assert.equal(only?.kind === 'countdown' ? only.label : '', 'Cole’s Margin in');
});

test('the listener’s own Margins get no countdown; only a friend’s do', () => {
  assert.equal(cueFor([margin('mine', 100, { author: null })], 0, 'Cole'), undefined);
  assert.equal(cueFor([], 0, 'Cole'), undefined);
  const mixed = [margin('mine', 50, { author: null }), margin('theirs', 100)];
  assert.equal(cueFor(mixed, 0, 'Cole')?.kind, 'countdown');
});

test('while a Margin is heard the card names who, which, and how many', () => {
  const m = [margin('a', 100, { spoken: true }), margin('b', 400), margin('c', 800, { spoken: true })];
  assert.deepEqual(speakingLine(m[0], m, 'Cole'), { title: 'Cole is speaking', position: '1 of 3' });
  assert.deepEqual(speakingLine(m[1], m, 'Cole'), { title: 'Cole wrote this', position: '2 of 3' });
  assert.equal(writtenIntro('Cole'), 'Cole wrote:');
  assert.equal(writtenIntro(undefined), 'Your friend wrote:');
  // An import with no sender name stores "Your friend"; it reads the same in the middle of a sentence.
  assert.equal(senderName('Your friend'), 'your friend');
  assert.deepEqual(speakingLine({ ...m[1], author: 'Your friend' }, m, undefined), { title: 'Your friend wrote this', position: '2 of 3' });
  const unnamed = cueFor([margin('a', 760, { author: 'Your friend' })], 0, 'Your friend');
  assert.ok(unnamed?.kind === 'countdown' && unnamed.label === 'Your friend’s Margin in' && unnamed.skip.label === 'Skip to just before your friend');
});

test('each failure says what happened and one thing to do, and none names a takedown or a server code', () => {
  for (const [name, words] of Object.entries(ARRIVAL_WORDS)) {
    const text = typeof words === 'function' ? words('Cole') : words;
    assert.doesNotMatch(text, /not_found|expired_or_removed|disabled|HTTP|\b40\d\b|\b50\d\b|taken down|removed/i, name);
  }
  assert.match(ARRIVAL_WORDS.off, /send the Margins as a file/);
  assert.doesNotMatch(ARRIVAL_WORDS.off, /try again/i, 'links switched off will not change in a minute');
});

test('with two friends on one episode, the countdown names whose Margin is next', () => {
  const m = [margin('a', 100, { author: 'Cole' }), margin('b', 400, { author: 'Dee' })];
  const cue = cueFor(m, 150, 'Cole');
  assert.ok(cue?.kind === 'countdown' && cue.label.startsWith('Dee’s') && cue.skip.label === 'Skip to just before Dee');
});

test('a written Margin is read aloud unless the sender asked it not to be; a voice Margin always plays (#3445)', () => {
  const written = margin('w', 10);
  const silent: Margin = { ...margin('s', 20), readAloud: false };
  assert.equal(readsAloud(written), true);
  assert.equal(readsAloud(silent), false);
  // A voice Margin is the sender's own audio; the key never silences it.
  assert.equal(readsAloud({ ...margin('v', 30, { spoken: true }), readAloud: false }), false, 'not read by the browser: it plays its clip');
  assert.equal(readsAloud(margin('v2', 30, { spoken: true })), false);
});

test('a Margin that is not read aloud adds no reading time, and still counts as a Margin (#3445)', () => {
  const read = margin('a', 10);
  const silent: Margin = { ...margin('b', 20), readAloud: false };
  assert.ok(marginsSeconds([read]) > 0);
  assert.equal(marginsSeconds([silent]), 0);
  assert.match(arrivalFacts('Cole', [read, silent]).countLine, /^2 Margins/);
  // The silent Margin is still a friend's Margin: it shows, and it counts in "N of M".
  assert.equal(friendMargins([read, silent]).length, 2);
});

test('the countdown and its Skip pass a Margin that is not read aloud (#3445)', () => {
  const silent: Margin = { ...margin('s', 300), readAloud: false };
  const spoken = margin('v', 600, { spoken: true });
  assert.equal(stopsPlayback(silent), false);
  assert.equal(stopsPlayback(spoken), true);
  assert.equal(stopsPlayback(margin('w', 10)), true);
  // At 0:00 the next stop is the voice Margin at 10:00, not the silent one at 5:00.
  const cue = cueFor([silent, spoken], 0, 'Cole');
  assert.ok(cue && cue.kind === 'countdown');
  assert.equal(cue.skip.to, 600 - LEAD_IN_SECONDS);
  assert.match(cue.label, /^Cole’s Margin in$/, 'one Margin to wait for, so no "first"');
  // Past the voice Margin, only the silent one is behind: nothing is left to count down to.
  assert.equal(cueFor([silent, spoken], 700, 'Cole')?.kind, 'after-last');
  // Only silent Margins: nothing to wait for, no card.
  assert.equal(cueFor([silent], 0, 'Cole'), undefined);
  assert.equal(cueFor([silent], 0, 'Cole', { failed: true, heardWithoutEpisode: false }), undefined);
  // The count in "3 of 3" still includes it.
  assert.equal(speakingLine(silent, [silent, spoken], 'Cole').position, '1 of 2');
});
