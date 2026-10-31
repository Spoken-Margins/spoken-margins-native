import assert from 'node:assert/strict';
import { test } from 'node:test';
import { child, childrenNamed, decodeEntities, parseXml } from './xml.ts';

test('stopAfterClosing leaves the rest of the document unread', () => {
  const xml = `<rss><channel>${'<item><t>x</t></item>'.repeat(1000)}</channel></rss>`;
  const channel = child(child(parseXml(xml, { stopAfterClosing: { name: 'item', count: 3 } }), 'rss') as never, 'channel');
  assert.equal(childrenNamed(channel as never, 'item').length, 3);
});

test('a self-closing element counts toward the stop, and attributes with > inside quotes survive', () => {
  const xml = '<a><e v="1>2"/><e v="b"/><e v="c"/></a>';
  const a = child(parseXml(xml, { stopAfterClosing: { name: 'e', count: 2 } }), 'a');
  const items = childrenNamed(a as never, 'e');
  assert.deepEqual(items.map((e) => e.attrs.v), ['1>2', 'b']);
});

test('decodeEntities: named, decimal, hex; invalid code points and unknown names stay', () => {
  assert.equal(decodeEntities('&amp;&lt;&gt;&quot;&apos;&#65;&#x42;'), '&<>"\'AB');
  assert.equal(decodeEntities('&#0; &#xD800; &#1114112; &bogus; &'), '&#0; &#xD800; &#1114112; &bogus; &');
});

test('a lone < in text is kept as text', () => {
  const root = parseXml('<a>1 < 2</a>');
  assert.equal(child(root, 'a')?.text, '1 < 2');
});
