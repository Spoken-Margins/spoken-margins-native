import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Margin, PageMargin } from '../../shared/model.ts';
import type { PacketRead } from '../ports.ts';
import {
  CONTEXT_CHARACTERS,
  cardMargins,
  contextLine,
  contextText,
  cutAtWord,
  finishedLine,
  hearButton,
  hearOneLabel,
  hintLine,
  kindNoun,
  kindWords,
  noMarginsLine,
  oneDoneLine,
  opensListenCard,
  rowPlace,
  rowWords,
  runSteps,
  showIphoneStep,
  statusLine,
  waitingLine,
  welcomeLine,
  type CardMargin,
} from './arrival-card.ts';
import { arrivalFacts } from './arrival.ts';
import type { ItemKind } from './playability.ts';

const voice = (seconds: number) => ({ blob: new Blob([]), mimeType: 'audio/mp4', durationSeconds: seconds });
const margin = (id: string, extra: Partial<Margin> = {}): Margin => ({ id, episodeId: 'packet:d', atSeconds: 0, createdAt: '2026-11-25T10:00:00Z', text: `words ${id}`, ...extra });
const page = (id: string, extra: Partial<PageMargin> = {}, m: Partial<Margin> = {}): PageMargin => ({ margin: margin(id, m), ...extra });

type Read = Pick<PacketRead, 'margins' | 'pageMargins'>;
const read = (margins: Margin[], pageMargins: PageMargin[]): Read => ({ margins, pageMargins });

test('order: timed by time, then on the words by percent, then the rest in packet order', () => {
  const r = read(
    [margin('t2', { atSeconds: 90 }), margin('t1', { atSeconds: 30 })],
    [page('plain1'), page('p60', { percent: 60 }), page('p10', { percent: 10 }), page('plain2'), page('p60b', { percent: 60 })],
  );
  assert.deepEqual(cardMargins(r, 'link').map((c) => c.margin.id), ['t1', 't2', 'p10', 'p60', 'p60b', 'plain1', 'plain2']);
});

test('an unnamed sender is “Your friend”, never the listener: the voice says “Your friend wrote:”', () => {
  const [card] = cardMargins(read([], [page('a', { percent: 5 })]), 'link');
  assert.equal(card.margin.author, 'Your friend');
  assert.equal(cardMargins(read([], [page('a')]), 'file')[0].margin.author, 'Your friend');
  const named = cardMargins(read([], [page('a', {}, { author: 'Cole' })]), 'link')[0];
  assert.equal(named.margin.author, 'Cole');
});

test('two authors: each row and each line names its own', () => {
  const cards = cardMargins(read([], [page('a', { percent: 1, quote: 'Q' }, { author: 'Cole' }), page('b', { percent: 2, quote: 'R' }, { author: 'Ana' })]), 'link');
  const words = kindWords('article', 'Cole', 'link', true);
  assert.match(contextLine(cards[0], words, 'T', 'Cole') ?? '', /Cole’s Margin/);
  assert.match(contextLine(cards[1], words, 'T', 'Cole') ?? '', /Ana’s Margin/);
  assert.equal(statusLine('voice', cards[1], 1, 2, words, 'Cole'), 'Ana is speaking · 2 of 2');
  assert.equal(finishedLine(cards[1], 'Cole', true), 'That was Ana’s last Margin. To answer Ana, add a Margin of your own in Spoken Margins on iPhone.');
});

test('every row of the kinds table, for a link and a file', () => {
  const rows: Array<[ItemKind, boolean, string | undefined, string]> = [
    ['article', true, 'Open the article', 'To hear them in place while the article is read aloud, open Cole’s link in Spoken Margins on iPhone.'],
    ['text', true, undefined, 'To hear them in place while the text is read aloud, open Cole’s link in Spoken Margins on iPhone.'],
    ['pdf', false, undefined, 'To hear them in place while the PDF is read aloud, open Cole’s link in Spoken Margins on iPhone, with your own copy of the same PDF.'],
    ['pdf', true, 'Open the PDF', 'To hear them in place while the PDF is read aloud, open Cole’s link in Spoken Margins on iPhone, with your own copy of the same PDF.'],
    ['book', false, undefined, 'To hear them in place while the book is read aloud, open Cole’s link in Spoken Margins on iPhone, with your own copy of the same book.'],
    ['book', true, 'Open the book', 'To hear them in place while the book is read aloud, open Cole’s link in Spoken Margins on iPhone, with your own copy of the same book.'],
    ['episode', true, 'Open the episode’s page', 'To hear them in place in the episode, open Cole’s link in Spoken Margins on iPhone.'],
    ['episode', false, undefined, 'To hear them in place in the episode, open Cole’s link in Spoken Margins on iPhone.'],
    ['recording', true, 'Open the page', 'To hear them in place in the recording, open Cole’s link in Spoken Margins on iPhone, with your own copy of the same recording.'],
  ];
  for (const [kind, address, source, next] of rows) {
    const link = kindWords(kind, 'Cole', 'link', address);
    assert.equal(link.sourceLabel, source, `${kind} ${address}`);
    assert.equal(link.nextStep, next, kind);
    assert.equal(link.again, 'After installing, tap your friend’s link again to open it in the app.');
    const file = kindWords(kind, 'Cole', 'file', address);
    assert.equal(file.nextStep, next.replace('Cole’s link', 'Cole’s file'), kind);
    assert.equal(file.again, 'After installing, open the file again in the app.');
  }
  assert.equal(kindWords('episode', 'Cole', 'link', false).place, 'moment');
  assert.equal(kindWords('pdf', 'Cole', 'link', false).place, 'place');
  assert.equal(kindNoun({ itemType: 'epub', episode: { title: 'T' }, margins: [] }), 'book');
});

test('no line on the card says what the browser can’t do', () => {
  const kinds: ItemKind[] = ['article', 'text', 'pdf', 'book', 'episode', 'recording'];
  for (const kind of kinds) {
    for (const origin of ['link', 'file'] as const) {
      const w = kindWords(kind, 'Cole', origin, true);
      for (const line of [w.nextStep, w.again, w.sourceLabel ?? '', noMarginsLine(origin), welcomeLine('Cole')]) assert.doesNotMatch(line, /can’t|can't|cannot/, `${kind} ${origin}`);
    }
  }
});

test('contextLine: the quote, the words before only, the place only, and neither', () => {
  const article = kindWords('article', 'Cole', 'link', true);
  const quoted: CardMargin = { margin: margin('a', { author: 'Cole' }), percent: 37, context: 'The quoted words.' };
  assert.equal(contextLine(quoted, article, 'Essay', 'Cole'), 'Here are the article’s words just before Cole’s Margin: The quoted words.');
  const [prefixOnly] = cardMargins(read([], [page('b', { percent: 37 }, { author: 'Cole', leadIn: '  Some words   before. ' })]), 'link');
  assert.equal(prefixOnly.context, 'Some words before.');
  assert.equal(contextLine(prefixOnly, article, 'Essay', 'Cole'), 'Here are the article’s words just before Cole’s Margin: Some words before.');
  const placeOnly: CardMargin = { margin: margin('c', { author: 'Cole' }), percent: 37.4 };
  assert.equal(contextLine(placeOnly, article, 'Essay', 'Cole'), 'Cole’s Margin is about 37% of the way through “Essay”.');
  const timed: CardMargin = { margin: margin('d', { author: 'Cole', atSeconds: 754 }), time: 754 };
  assert.equal(contextLine(timed, kindWords('episode', 'Cole', 'link', false), 'Ep', 'Cole'), 'Cole’s Margin is at 12:34 in “Ep”.');
  assert.equal(contextLine({ margin: margin('e', { author: 'Cole' }) }, article, 'Essay', 'Cole'), undefined);
  // Generic words for a pasted text and a recording.
  assert.equal(contextLine(quoted, kindWords('text', 'Cole', 'link', false), 'Note', 'Cole'), 'Here are the words just before Cole’s Margin: The quoted words.');
  // A written Margin the sender asked not to be read aloud has nothing read before it.
  assert.equal(contextLine({ ...quoted, margin: { ...quoted.margin, readAloud: false } }, article, 'Essay', 'Cole'), undefined);
  // A voice Margin is the sender's own voice: its context is read.
  assert.ok(contextLine({ ...quoted, margin: { ...quoted.margin, voice: voice(3) } }, article, 'Essay', 'Cole'));
  // "your friend" at the start of a sentence.
  assert.equal(contextLine({ ...placeOnly, margin: margin('f') }, article, 'Essay', undefined), 'Your friend’s Margin is about 37% of the way through “Essay”.');
});

test('the quote is cut at 300 characters at a whole word, with “…”', () => {
  const long = Array.from({ length: 120 }, (_, i) => `word${i}`).join(' ');
  const cut = cutAtWord(long);
  assert.ok(Array.from(cut).length <= CONTEXT_CHARACTERS + 1);
  assert.ok(cut.endsWith('…'));
  assert.ok(long.startsWith(cut.slice(0, -1)), 'cut at a whole word');
  assert.equal(cutAtWord('short words'), 'short words');
  assert.equal(contextText('  spaced\n quote ', 'prefix'), 'spaced quote');
  assert.equal(contextText('   ', 'the prefix'), 'the prefix');
  assert.equal(contextText(undefined, undefined), undefined);
  // Characters as a person sees them: an emoji is one.
  assert.equal(cutAtWord('é'.repeat(300)), 'é'.repeat(300));
});

test('row place and words: clock, percent, nothing; “Voice Margin · 0:42”', () => {
  assert.equal(rowPlace({ margin: margin('a'), time: 754 }), '12:34');
  assert.equal(rowPlace({ margin: margin('a'), percent: 36.6 }), 'About 37% in');
  assert.equal(rowPlace({ margin: margin('a') }), '');
  assert.deepEqual(rowWords(margin('a', { text: '', voice: voice(42) })), { words: null, voiceLine: 'Voice Margin · 0:42' });
  assert.deepEqual(rowWords(margin('a', { text: 'Spoken words', voice: voice(42.4) })), { words: 'Spoken words', voiceLine: 'Voice · 0:42' });
  assert.deepEqual(rowWords(margin('a', { text: 'Written' })), { words: 'Written' });
  assert.equal(hearOneLabel({ margin: margin('a', { author: 'Cole' }), percent: 37 }, 'Cole'), 'Hear Cole’s Margin About 37% in');
  assert.equal(hearOneLabel({ margin: margin('a', { author: 'Cole' }) }, 'Cole'), 'Hear Cole’s Margin');
});

test('status lines by phase, with no “1 of 1”', () => {
  const card: CardMargin = { margin: margin('a', { author: 'Cole' }), percent: 5 };
  const article = kindWords('article', 'Cole', 'link', true);
  assert.equal(statusLine('context', card, 0, 3, article, 'Cole'), 'The article’s words before Cole’s Margin · 1 of 3');
  assert.equal(statusLine('context', card, 0, 3, kindWords('recording', 'Cole', 'link', false), 'Cole'), 'The words before Cole’s Margin · 1 of 3');
  assert.equal(statusLine('voice', card, 1, 3, article, 'Cole'), 'Cole is speaking · 2 of 3');
  assert.equal(statusLine('written', card, 2, 3, article, 'Cole'), 'Cole wrote this · 3 of 3');
  assert.equal(statusLine('shown', card, 0, 1, article, 'Cole'), 'Cole wrote this');
  assert.equal(statusLine('context', card, 0, 1, article, 'Cole'), 'The article’s words before Cole’s Margin');
  assert.equal(oneDoneLine(1, 3, card, 'Cole', true), 'That was 2 of 3.');
  assert.equal(oneDoneLine(0, 1, card, 'Cole', true), finishedLine(card, 'Cole', true));
  assert.equal(waitingLine('Cole'), 'Tap Hear Cole’s Margins to go on.');
  assert.equal(hearButton('Cole', 'ready'), 'Hear Cole’s Margins');
  assert.equal(hearButton('Cole', 'playing'), 'Stop');
  assert.equal(hearButton('Cole', 'finished'), 'Hear them again');
});

test('with no iPhone step (Android), the finished line drops “To answer…”', () => {
  const card: CardMargin = { margin: margin('a', { author: 'Cole' }) };
  assert.equal(finishedLine(card, 'Cole', false), 'That was Cole’s last Margin.');
  assert.equal(showIphoneStep(false, 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X)'), true);
  assert.equal(showIphoneStep(false, 'Mozilla/5.0 (Linux; Android 15; Pixel 9)'), false);
  assert.equal(showIphoneStep(true, 'Mozilla/5.0 (iPhone)'), false);
});

test('the hint and the zero-Margins line', () => {
  assert.equal(hintLine([{ margin: margin('a'), context: 'x' }]), 'Each Margin plays after the words just before it.');
  assert.equal(hintLine([{ margin: margin('a') }]), 'They play one after another.');
  assert.equal(noMarginsLine('link'), 'This link has no Margins in it. Ask your friend to share it again.');
  assert.equal(noMarginsLine('file'), 'This file has no Margins in it. Ask your friend to share it again.');
  assert.deepEqual(cardMargins(read([], []), 'link'), []);
});

test('row 7: the explanation names the place and the noun for every kind; the Play card’s is unchanged', () => {
  const kinds: ItemKind[] = ['article', 'text', 'pdf', 'book', 'episode', 'recording'];
  for (const kind of kinds) {
    const w = kindWords(kind, 'Cole', 'link', true);
    const spoken = arrivalFacts('Cole', [margin('a', { voice: voice(3) })], w);
    assert.equal(spoken.explanation, `A Margin is a voice note Cole left at a ${w.place} in this ${w.noun}.`);
    const written = arrivalFacts('Cole', [margin('a')], w);
    assert.equal(written.explanation, `A Margin is a note Cole left at a ${w.place} in this ${w.noun}. You’ll hear each one here, after the words before it.`);
  }
  assert.equal(arrivalFacts('Cole', [margin('a')]).explanation, 'A Margin is a note Cole left at a moment in this episode. You’ll hear each one there.');
});

test('200 Margins with long words and quotes: order, the count line and the cut', () => {
  const many = Array.from({ length: 200 }, (_, i) => page(`m${i}`, { percent: 200 - i, quote: `${'long quote '.repeat(60)}${i}` }, { text: 'w'.repeat(2000), author: 'Cole' }));
  const cards = cardMargins(read([], many), 'link');
  assert.equal(cards.length, 200);
  assert.equal(cards[0].margin.id, 'm199');
  assert.equal(cards[199].margin.id, 'm0');
  assert.ok(cards.every((c) => Array.from(c.context ?? '').length <= CONTEXT_CHARACTERS + 1));
  assert.match(arrivalFacts('Cole', cards.map((c) => c.margin)).countLine, /^200 Margins · about 27 min$/);
  const steps = runSteps(cards, kindWords('article', 'Cole', 'link', true), 'T', 'Cole');
  assert.equal(steps.length, 200);
  assert.ok(steps.every((s) => s.context?.startsWith('Here are the article’s words')));
});

test('a single, non-backup text file opens the card and writes nothing; every other file keeps today’s import', () => {
  const text = { episode: { title: 'T' }, margins: [], percentMargins: [] } as Pick<PacketRead, 'episode' | 'margins' | 'percentMargins'>;
  const episode = { episode: { title: 'E' }, margins: [margin('t', { atSeconds: 5 })], percentMargins: [] } as Pick<PacketRead, 'episode' | 'margins' | 'percentMargins'>;
  assert.equal(opensListenCard(text, 'file', true), true);
  assert.equal(opensListenCard(text, 'file', false), false, 'several at once');
  assert.equal(opensListenCard(text, 'backup', true), false, 'a backup');
  assert.equal(opensListenCard(text, 'link', true), false, 'a link opened inside the app keeps its own path');
  assert.equal(opensListenCard(episode, 'file', true), false, 'an episode with no audio is stored as before');
});
