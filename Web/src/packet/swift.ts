// How the app's Swift code writes and counts things the packet digest and preview depend on. Each helper mirrors
// one Swift behaviour that `Contracts/tools/spoken_margins_format.py` (the format's reference reader, checked against
// the Swift reader) already pins down.

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

/**
 * JSONEncoder with `.sortedKeys` and `.withoutEscapingSlashes`: sorted keys, no spaces, `/` unescaped, absent
 * optionals (null here) left out. JSON.stringify escapes strings the way Swift does (`\"`, `\\`, `\b\f\n\r\t`, other
 * controls as lowercase `\u00xx`, everything else raw UTF-8).
 */
export function swiftJSON(value: unknown): string {
  return encode(dropNulls(value as Json));
}

function dropNulls(value: Json): Json {
  if (Array.isArray(value)) return value.map(dropNulls);
  if (value !== null && typeof value === 'object') {
    const out: { [key: string]: Json } = {};
    for (const [key, child] of Object.entries(value)) {
      if (child !== null && child !== undefined) out[key] = dropNulls(child);
    }
    return out;
  }
  return value;
}

function encode(value: Json): string {
  if (Array.isArray(value)) return `[${value.map(encode).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const keys = Object.keys(value).sort(byCodePoint);
    return `{${keys.map((key) => `${JSON.stringify(key)}:${encode(value[key])}`).join(',')}}`;
  }
  if (typeof value === 'number' && !Number.isSafeInteger(value)) {
    throw new TypeError('packet JSON carries integers only');
  }
  return JSON.stringify(value);
}

function byCodePoint(a: string, b: string): number {
  const left = [...a];
  const right = [...b];
  for (let i = 0; i < Math.min(left.length, right.length); i += 1) {
    const diff = (left[i].codePointAt(0) ?? 0) - (right[i].codePointAt(0) ?? 0);
    if (diff !== 0) return diff;
  }
  return left.length - right.length;
}

const ISO = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/;

/** True for a date string the app's packet decoder reads: ISO 8601 with a zone, with or without fractions. */
export function isSwiftDate(value: unknown): value is string {
  return typeof value === 'string' && ISO.test(value) && !Number.isNaN(Date.parse(value));
}

/** The manifest's createdAt as the Swift writer re-encodes it: UTC with exactly three fraction digits. */
export function swiftFractionalDate(value: string): string {
  const match = ISO.exec(value);
  if (!match) return value;
  const fraction = (match[7] ?? '.000').slice(1).padEnd(3, '0').slice(0, 3);
  const whole = new Date(Date.parse(`${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}${match[8]}`));
  return `${whole.toISOString().slice(0, 19)}.${fraction}Z`;
}

/** An artifact date as `encodeArtifact` writes it (`.iso8601`, whole seconds). */
export function swiftWholeSecondDate(date: Date): string {
  return `${date.toISOString().slice(0, 19)}Z`;
}

/** CharacterSet.whitespacesAndNewlines: category Z*, tab, U+000A to U+000D and U+0085. */
const SWIFT_SPACE = /[\t\n\v\f\r\u0085\p{Z}]/u;

export function isSwiftSpace(char: string): boolean {
  return SWIFT_SPACE.test(char);
}

/** `trimmingCharacters(in: .whitespacesAndNewlines)`. */
export function swiftTrim(text: string): string {
  const chars = [...text];
  let start = 0;
  let end = chars.length;
  while (start < end && isSwiftSpace(chars[start])) start += 1;
  while (end > start && isSwiftSpace(chars[end - 1])) end -= 1;
  return chars.slice(start, end).join('');
}

/** `components(separatedBy: .whitespacesAndNewlines)` without the empty parts, joined by one space. */
export function swiftCollapseSpaces(text: string): string {
  const parts: string[] = [];
  let current = '';
  for (const char of text) {
    if (isSwiftSpace(char)) {
      if (current) parts.push(current);
      current = '';
    } else {
      current += char;
    }
  }
  if (current) parts.push(current);
  return parts.join(' ');
}

const segmenter = new Intl.Segmenter('en', { granularity: 'grapheme' });

/** Swift's `String.count`: extended grapheme clusters. */
export function characterCount(text: string): number {
  let count = 0;
  for (const _ of segmenter.segment(text)) count += 1;
  return count;
}

const ESCAPABLE = new Set('\\`*_{}[]<>()#+-!|>');

/** The preview's Markdown escaping: a backslash before each of \`*_{}[]<>()#+-!| */
export function markdownEscaped(value: string): string {
  let out = '';
  for (const char of value) out += ESCAPABLE.has(char) ? `\\${char}` : char;
  return out;
}

/** CharacterSet.alphanumerics (letters, marks and numbers in any script) or one of `._-`. */
export function isPathCharacter(char: string): boolean {
  return '._-'.includes(char) || /^[\p{L}\p{M}\p{N}]$/u.test(char);
}
