// The web app wears the iPhone app's colours (#3040, owner 2026-10-31: "doesn't look much like the app in terms of
// style"). This reads both sources, the app's semantic colours in SessionKit and the web's tokens in styles.css, so
// a change to either that drifts them apart fails here. It also checks the contrast the app's own audit asks for,
// and that status stays blue and orange, never red and green (Design/brief.md rule 3).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

type RGB = [number, number, number];

const swift = readFileSync(new URL('../../../Packages/SessionKit/Sources/SessionKit/ExperienceColorContrast.swift', import.meta.url), 'utf8');
const css = readFileSync(new URL('./styles.css', import.meta.url), 'utf8');

function appColours(): Record<string, { light: RGB; dark: RGB }> {
  const colours: Record<string, { light: RGB; dark: RGB }> = {};
  const num = String.raw`([\d.]+)`;
  const rgb = String.raw`\.init\(red: ${num}, green: ${num}, blue: ${num}\)`;
  const pattern = new RegExp(String.raw`static let (\w+) = AppDynamicRGB\(\s*light: ${rgb},\s*dark: ${rgb}\s*\)`, 'g');
  for (const m of swift.matchAll(pattern)) {
    const n = m.slice(2).map(Number);
    colours[m[1]] = { light: [n[0], n[1], n[2]], dark: [n[3], n[4], n[5]] };
  }
  return colours;
}

function tokens(block: string): Record<string, string> {
  const found: Record<string, string> = {};
  for (const m of block.matchAll(/--([\w-]+):\s*(#[0-9a-f]{6})\s*;/gi)) found[m[1]] = m[2].toLowerCase();
  return found;
}

const lightBlock = /^:root \{([\s\S]*?)^\}/m.exec(css)?.[1] ?? '';
const darkBlock = /@media \(prefers-color-scheme: dark\) \{\s*:root \{([\s\S]*?)\}/.exec(css)?.[1] ?? '';
const web = { light: tokens(lightBlock), dark: tokens(darkBlock) };
const app = appColours();

const hex = (c: RGB) => `#${c.map((v) => Math.round(v * 255).toString(16).padStart(2, '0')).join('')}`;
const fromHex = (h: string): RGB => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255) as RGB;

function luminance([r, g, b]: RGB): number {
  const lin = (v: number) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
}

function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(fromHex(a)), luminance(fromHex(b))].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

function hue(h: string): number {
  const [r, g, b] = fromHex(h);
  const max = Math.max(r, g, b);
  const d = max - Math.min(r, g, b);
  if (d === 0) return 0;
  const raw = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return (raw * 60 + 360) % 360;
}

/** Web token → the app's semantic colour it copies. */
const SAME_AS_APP: Record<string, string> = {
  page: 'bone',
  surface: 'panel',
  ink: 'text',
  muted: 'secondaryText',
  rule: 'border',
  field: 'borderIncreased',
  tint: 'evergreen',
  'tint-soft': 'softGreen',
  'on-tint': 'onEvergreen',
};

test('the web tokens are the iPhone app’s colours, light and dark', () => {
  assert.ok(Object.keys(app).length > 10, 'read the app’s colours');
  for (const mode of ['light', 'dark'] as const) {
    for (const [token, name] of Object.entries(SAME_AS_APP)) {
      assert.ok(app[name], `the app has ${name}`);
      assert.equal(web[mode][token], hex(app[name][mode]), `${mode} --${token} is the app’s ${name}`);
    }
  }
  // A Margin's marks: the app's own ochre in dark mode (light mode needs a deeper one for 3:1, checked below).
  assert.equal(web.dark['orange-mark'], hex(app.ochre.dark));
});

test('text and controls keep the contrast the app’s audit asks for', () => {
  const pairs: Array<[string, string, number]> = [
    ['ink', 'page', 4.5],
    ['ink', 'surface', 4.5],
    ['muted', 'page', 4.5],
    ['muted', 'surface', 4.5],
    ['tint', 'page', 4.5],
    ['tint', 'surface', 4.5],
    ['tint', 'tint-soft', 4.5],
    ['on-tint', 'tint', 4.5],
    ['ink', 'tint-soft', 4.5],
    ['status', 'status-soft', 4.5],
    ['orange-ink', 'orange-soft', 4.5],
    ['orange-ink', 'surface', 4.5],
    // Edges and marks that are the only sign of a control or a Margin: 3:1.
    ['field', 'page', 3],
    ['field', 'surface', 3],
    ['orange-mark', 'page', 3],
    ['orange-mark', 'surface', 3],
  ];
  for (const mode of ['light', 'dark'] as const) {
    for (const [fg, bg, min] of pairs) {
      const ratio = contrast(web[mode][fg], web[mode][bg]);
      assert.ok(ratio >= min, `${mode}: --${fg} on --${bg} is ${ratio.toFixed(2)}:1, under ${min}:1`);
    }
  }
});

test('status is blue and Margins are orange, never red and green', () => {
  for (const mode of ['light', 'dark'] as const) {
    const status = hue(web[mode].status);
    assert.ok(status >= 190 && status <= 240, `${mode} status hue ${status.toFixed(0)} is blue`);
    for (const token of ['orange-mark', 'orange-ink']) {
      const h = hue(web[mode][token]);
      assert.ok(h >= 25 && h <= 50, `${mode} --${token} hue ${h.toFixed(0)} is orange`);
    }
  }
});
