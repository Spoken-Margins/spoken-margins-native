import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isIntroPreview } from './intro-link.ts';

const base = { schema: 'spokenmargins.link-preview.v1', source: { title: 'T' }, margins: [{ text: 'x' }] };

test('#4784 only answers "none" marks an introduction link; anything else is no mark', () => {
  const rows: [string, unknown, boolean][] = [
    ['the mark', { ...base, answers: 'none' }, true],
    ['no field: a conversation link', base, false],
    ['a later build\'s value', { ...base, answers: 'box' }, false],
    ['case differs', { ...base, answers: 'None' }, false],
    ['padded', { ...base, answers: ' none' }, false],
    ['a boolean', { ...base, answers: true }, false],
    ['an array', { ...base, answers: ['none'] }, false],
    ['null field', { ...base, answers: null }, false],
    ['empty string', { ...base, answers: '' }, false],
    ['null preview', null, false],
    ['undefined preview (fetch failed or slow)', undefined, false],
    ['a string', 'none', false],
    ['an array preview', ['none'], false],
  ];
  for (const [label, preview, expected] of rows) assert.equal(isIntroPreview(preview), expected, label);
});
