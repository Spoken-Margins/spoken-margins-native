// Which links may travel in a packet: a port of the app's ShareableLinkPolicy
// (Packages/SessionKit/Sources/SessionKit/ShareableLinkPolicy.swift). A link that could hold an access secret
// (a private feed host, a "premium" path, a token-like query or fragment) is left out of the packet.

const PRIVATE_HOST_SUFFIXES = [
  'patreon.com', 'patreonusercontent.com', 'supercast.com', 'supercast.tech', 'supportingcast.fm', 'memberful.com',
  'memberfulcontent.com',
];
const PUBLIC_HEX_IDENTIFIER_FEED_HOSTS = ['rss.amperwave.net'];
const PRIVATE_PATH_MARKERS = new Set([
  'private', 'premium', 'paid', 'subscriber', 'subscribers', 'member', 'members', 'patron', 'patrons', 'supporter',
  'supporters',
]);
const CREDENTIAL_QUERY_FRAGMENTS = [
  'token', 'auth', 'key', 'secret', 'sig', 'hash', 'pass', 'pwd', 'session', 'credential', 'jwt', 'expire', 'policy',
  'hmac', 'access',
];

function decodedOnce(value: string): string {
  const input = new TextEncoder().encode(value);
  const out: number[] = [];
  const hexValue = (byte: number): number | null => {
    if (byte >= 0x30 && byte <= 0x39) return byte - 0x30;
    if (byte >= 0x61 && byte <= 0x66) return byte - 0x61 + 10;
    if (byte >= 0x41 && byte <= 0x46) return byte - 0x41 + 10;
    return null;
  };
  for (let i = 0; i < input.length; ) {
    const high = input[i] === 0x25 && i + 2 < input.length ? hexValue(input[i + 1]) : null;
    const low = high !== null ? hexValue(input[i + 2]) : null;
    if (high !== null && low !== null) {
      out.push((high << 4) | low);
      i += 3;
    } else {
      out.push(input[i]);
      i += 1;
    }
  }
  return new TextDecoder().decode(new Uint8Array(out));
}

function fullyDecoded(value: string): string {
  let current = value;
  for (let i = 0; i < 3; i += 1) {
    const next = decodedOnce(current);
    if (next === current) break;
    current = next;
  }
  return current;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function looksLikeSecret(value: string): boolean {
  const trimmed = value.replace(/%/g, '').replace(/^=+|=+$/g, '');
  if ([...trimmed].length < 32 || UUID.test(trimmed)) return false;
  if (!/^[A-Za-z0-9_-]+$/.test(trimmed)) return false;
  return /[A-Za-z]/.test(trimmed) && /[0-9]/.test(trimmed);
}

const stem = (segment: string): string => segment.split('.')[0] ?? segment;
const isHyphenlessUUID = (value: string): boolean => /^[0-9a-fA-F]{32}$/.test(value);

function pathSegmentHoldsCredential(segment: string, allowsHex: boolean): boolean {
  const decoded = fullyDecoded(segment);
  const parts = decoded.split('/').filter(Boolean);
  if (parts.some((part) => PRIVATE_PATH_MARKERS.has(stem(part).toLowerCase()))) return true;
  if (!decoded.includes('://')) {
    return parts.some((part) => {
      const partStem = stem(part);
      if (allowsHex && isHyphenlessUUID(partStem)) return false;
      return looksLikeSecret(partStem);
    });
  }
  const whole = stem(decoded);
  if (allowsHex && isHyphenlessUUID(whole)) return false;
  return looksLikeSecret(whole);
}

function queryItemHoldsCredential(item: string): boolean {
  const eq = item.indexOf('=');
  const name = (eq < 0 ? item : item.slice(0, eq)).toLowerCase();
  if (CREDENTIAL_QUERY_FRAGMENTS.some((fragment) => name.includes(fragment))) return true;
  return eq >= 0 && looksLikeSecret(item.slice(eq + 1));
}

function fragmentHoldsCredential(encoded: string): boolean {
  let fragment = fullyDecoded(encoded);
  const directive = fragment.indexOf(':~:');
  if (directive >= 0) fragment = fragment.slice(0, directive);
  if (fragment.startsWith('!')) fragment = fragment.slice(1);
  const question = fragment.indexOf('?');
  const head = question < 0 ? fragment : fragment.slice(0, question);
  const tail = question < 0 ? '' : fragment.slice(question + 1);
  const segments = head.split('/').filter(Boolean);
  if (head.includes('/') && segments.some((s) => PRIVATE_PATH_MARKERS.has(stem(s).toLowerCase()))) return true;
  if (segments.some((s) => looksLikeSecret(stem(s)))) return true;
  for (const item of head.split('&').filter(Boolean)) if (item.includes('=') && queryItemHoldsCredential(item)) return true;
  for (const item of tail.split('&').filter(Boolean)) if (queryItemHoldsCredential(item)) return true;
  return false;
}

/** The link unchanged when it is an http(s) link holding no access secret, else undefined. */
export function shareableLink(value: string | undefined): string | undefined {
  if (!value) return undefined;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return undefined;
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return undefined;
  const host = url.hostname.toLowerCase();
  if (!host || url.username || url.password) return undefined;
  if (PRIVATE_HOST_SUFFIXES.some((suffix) => host === suffix || host.endsWith(`.${suffix}`))) return undefined;
  const allowsHex = PUBLIC_HEX_IDENTIFIER_FEED_HOSTS.includes(host);
  for (const segment of url.pathname.split('/').filter(Boolean)) {
    if (pathSegmentHoldsCredential(segment, allowsHex)) return undefined;
  }
  for (const item of url.search.replace(/^\?/, '').split('&').filter(Boolean)) {
    const eq = item.indexOf('=');
    const name = fullyDecoded(eq < 0 ? item : item.slice(0, eq)).toLowerCase();
    if (CREDENTIAL_QUERY_FRAGMENTS.some((fragment) => name.includes(fragment))) return undefined;
    if (eq >= 0 && looksLikeSecret(fullyDecoded(item.slice(eq + 1)))) return undefined;
  }
  if (url.hash.length > 1 && fragmentHoldsCredential(url.hash.slice(1))) return undefined;
  return value;
}

/** A GUID unchanged unless it is a link that fails `shareableLink`; plain GUIDs are safe to share. */
export function shareableEpisodeGUID(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  if (!/^https?:/i.test(value)) return value;
  return shareableLink(value);
}
