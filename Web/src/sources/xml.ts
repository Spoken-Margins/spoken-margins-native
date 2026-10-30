// A small, careful XML reader for RSS. DOM-free and package-free, so it runs in Node tests and in a browser
// alike. It reads data only: DOCTYPE declarations are skipped and never expanded, so entity-expansion attacks
// have nothing to work on. It is lenient on purpose (feeds in the wild are often slightly broken) but never
// loops forever and never throws on malformed input: it returns whatever tree it could build.
//
// Names are kept as written, prefix included (`itunes:duration`), and matched exactly. Namespaces are not resolved.

export interface XmlElement {
  name: string;
  attrs: Record<string, string>;
  children: XmlElement[];
  /** Text directly inside this element (entities decoded, CDATA included), concatenated in order. */
  text: string;
}

export interface ParseXmlOptions {
  /** Stop reading once this many elements named `name` have closed. The tree built so far is returned. */
  stopAfterClosing?: { name: string; count: number };
  /** Nesting deeper than this is not descended into (a guard against pathological input). Default 64. */
  maxDepth?: number;
}

const NAMED_ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };

/** Decodes the five XML entities and numeric references. Anything else (`&nbsp;`, a stray `&`) stays as written. */
export function decodeEntities(text: string): string {
  if (!text.includes('&')) return text;
  return text.replace(/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/g, (whole, body: string) => {
    if (body[0] === '#') {
      const code = body[1] === 'x' ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
      if (!Number.isFinite(code) || code < 1 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return whole;
      return String.fromCodePoint(code);
    }
    return NAMED_ENTITIES[body] ?? whole;
  });
}

function parseAttributes(source: string): Record<string, string> {
  const attrs: Record<string, string> = {};
  const pattern = /([^\s=/>"']+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/g;
  for (let match = pattern.exec(source); match; match = pattern.exec(source)) {
    const name = match[1] as string;
    if (!(name in attrs)) attrs[name] = decodeEntities(match[2] ?? match[3] ?? match[4] ?? '');
  }
  return attrs;
}

/** Finds the `>` that ends a tag starting at `from`, skipping over quoted attribute values. */
function tagEnd(xml: string, from: number): number {
  let quote = '';
  for (let i = from; i < xml.length; i += 1) {
    const ch = xml[i] as string;
    if (quote) {
      if (ch === quote) quote = '';
    } else if (ch === '"' || ch === "'") {
      quote = ch;
    } else if (ch === '>') {
      return i;
    }
  }
  return -1;
}

/** Parses `xml` and returns a synthetic root whose children are the document's top-level elements. */
export function parseXml(xml: string, options: ParseXmlOptions = {}): XmlElement {
  const maxDepth = options.maxDepth ?? 64;
  const stop = options.stopAfterClosing;
  const root: XmlElement = { name: '#document', attrs: {}, children: [], text: '' };
  const stack: XmlElement[] = [root];
  let closedCount = 0;
  let pos = 0;

  const top = (): XmlElement => stack[stack.length - 1] as XmlElement;

  while (pos < xml.length) {
    const lt = xml.indexOf('<', pos);
    if (lt === -1) {
      top().text += decodeEntities(xml.slice(pos));
      break;
    }
    if (lt > pos) top().text += decodeEntities(xml.slice(pos, lt));

    if (xml.startsWith('<!--', lt)) {
      const end = xml.indexOf('-->', lt + 4);
      pos = end === -1 ? xml.length : end + 3;
    } else if (xml.startsWith('<![CDATA[', lt)) {
      const end = xml.indexOf(']]>', lt + 9);
      top().text += xml.slice(lt + 9, end === -1 ? xml.length : end);
      pos = end === -1 ? xml.length : end + 3;
    } else if (xml.startsWith('<?', lt)) {
      const end = xml.indexOf('?>', lt + 2);
      pos = end === -1 ? xml.length : end + 2;
    } else if (xml.startsWith('<!', lt)) {
      // DOCTYPE and the like. An internal subset ([ ... ]) can hold `>`, so skip to the matching `]>`.
      const bracket = xml.indexOf('[', lt);
      const plainEnd = xml.indexOf('>', lt);
      if (bracket !== -1 && (plainEnd === -1 || bracket < plainEnd)) {
        const end = xml.indexOf(']', bracket);
        const close = end === -1 ? -1 : xml.indexOf('>', end);
        pos = close === -1 ? xml.length : close + 1;
      } else {
        pos = plainEnd === -1 ? xml.length : plainEnd + 1;
      }
    } else if (xml[lt + 1] === '/') {
      const end = xml.indexOf('>', lt);
      const name = xml.slice(lt + 2, end === -1 ? xml.length : end).trim();
      pos = end === -1 ? xml.length : end + 1;
      // Close the nearest open element of that name; a stray close tag with no match is ignored.
      let index = stack.length - 1;
      while (index > 0 && (stack[index] as XmlElement).name !== name) index -= 1;
      if (index > 0) {
        const closed = stack[index] as XmlElement;
        stack.length = index;
        if (stop && closed.name === stop.name) {
          closedCount += 1;
          if (closedCount >= stop.count) return root;
        }
      }
    } else {
      const end = tagEnd(xml, lt + 1);
      if (end === -1) break; // an unterminated tag: nothing more to read
      let inner = xml.slice(lt + 1, end);
      const selfClosing = inner.endsWith('/');
      if (selfClosing) inner = inner.slice(0, -1);
      const nameMatch = /^[^\s/>]+/.exec(inner);
      if (!nameMatch) {
        // `<` followed by something that isn't a tag, such as "a < b": keep it as text.
        top().text += '<';
        pos = lt + 1;
        continue;
      }
      pos = end + 1;
      const element: XmlElement = {
        name: nameMatch[0],
        attrs: parseAttributes(inner.slice(nameMatch[0].length)),
        children: [],
        text: '',
      };
      top().children.push(element);
      if (selfClosing) {
        if (stop && element.name === stop.name) {
          closedCount += 1;
          if (closedCount >= stop.count) return root;
        }
      } else if (stack.length <= maxDepth) {
        stack.push(element);
      }
    }
  }
  return root;
}

/** The first direct child named `name`. */
export function child(element: XmlElement, name: string): XmlElement | undefined {
  return element.children.find((c) => c.name === name);
}

/** All direct children named `name`. */
export function childrenNamed(element: XmlElement, name: string): XmlElement[] {
  return element.children.filter((c) => c.name === name);
}

/** The trimmed text of the first direct child named `name`, or undefined when it's missing or blank. */
export function childText(element: XmlElement, name: string): string | undefined {
  const text = child(element, name)?.text.trim();
  return text ? text : undefined;
}
