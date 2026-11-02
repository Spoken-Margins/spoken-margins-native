// Makes a share link on the Mac from a .spokenmargins file, so the owner can open real links on his phone before the
// iPhone can make one (#3239, then #487). It reads the packet with the web importer, builds the preview the web app
// would, seals both with the shared sealing code and uploads them. The key stays in the link's `#` part.
//
//   scripts/make-share-link <file.spokenmargins> [--server https://spokenmargins.com]
//
// This runs only from a checkout on the Mac. The web app's own upload stays behind SHARE_LINKS_ENABLED, which every
// hosted build leaves off; nothing here is bundled into it.

import { readFileSync } from 'node:fs';
import { basename } from 'node:path';

import { shareableLink } from '../packet/links.ts';
import { readPacket, type ReadPacketResult } from '../packet/read.ts';
import { postSealedLink, sealPacket, type LinkPreview } from '../packet/share-link.ts';

export const DEFAULT_SERVER = 'https://spokenmargins.com';
/** The link server's cap on a sealed packet (research/B4/server/internal/links/store.go, MaxPacketBytes). */
export const MAX_SEALED_PACKET_BYTES = 20 << 20;

export class MakeShareLinkError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'MakeShareLinkError';
  }
}

export interface MadeLink {
  url: string;
  expiresAt?: string;
  preview: LinkPreview;
  sealedPacketBytes: number;
}

/**
 * The preview sealed next to the packet, as the web app's linkPreview builds it, plus the words of text Margins, since
 * the iPhone exports article packets too. Words only: no quoted source text, as for a podcast.
 */
export function previewOf(read: ReadPacketResult): LinkPreview {
  const margins = [...read.margins, ...read.textMargins]
    .map((m) => (m.text ?? '').trim())
    .filter((text) => text !== '')
    .map((text) => ({ text }));
  if (margins.length === 0) throw new MakeShareLinkError('None of these Margins have words, so there is nothing to put in a link.');
  const url = shareableLink(read.episode.pageUrl);
  const show = read.episode.showTitle?.trim();
  return { schema: 'spokenmargins.link-preview.v1', source: { title: read.episode.title, ...(show && { show }), ...(url && { url }) }, margins };
}

const megabytes = (n: number): string => (n < 1 << 20 ? `${Math.ceil(n / 1024)} KB` : `${(n / (1 << 20)).toFixed(1)} MB`);

/** Reads, seals and uploads one packet. Refuses an oversized packet before anything is sent. */
export async function makeShareLink(
  packet: Uint8Array,
  options: { fileName: string; server?: string; fetch?: typeof fetch },
): Promise<MadeLink> {
  const read = await readPacket(packet, { fileName: options.fileName });
  const preview = previewOf(read);
  const sealed = await sealPacket(packet, preview);
  if (sealed.packet.length > MAX_SEALED_PACKET_BYTES) {
    throw new MakeShareLinkError(
      `This packet is ${megabytes(sealed.packet.length)} sealed; the link server takes at most ${megabytes(MAX_SEALED_PACKET_BYTES)}. ` +
        'Share fewer voice Margins, or wait for smaller packets (#3218).',
    );
  }
  const made = await postSealedLink(sealed, { server: options.server ?? DEFAULT_SERVER, fetch: options.fetch });
  return { ...made, preview, sealedPacketBytes: sealed.packet.length };
}

const USAGE = 'usage: scripts/make-share-link <file.spokenmargins> [--server https://spokenmargins.com]';

async function main(args: string[]): Promise<number> {
  let server = DEFAULT_SERVER;
  const files: string[] = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--server') server = args[++i] ?? '';
    else if (args[i] === '-h' || args[i] === '--help') {
      console.log(USAGE);
      return 0;
    } else files.push(args[i] as string);
  }
  if (files.length !== 1 || !server) {
    console.error(USAGE);
    return 2;
  }
  const path = files[0] as string;
  try {
    const made = await makeShareLink(new Uint8Array(readFileSync(path)), { fileName: basename(path), server });
    console.error(`${made.preview.source.title}: ${made.preview.margins.length} Margins with words, ${megabytes(made.sealedPacketBytes)} sealed`);
    if (made.expiresAt) console.error(`expires ${made.expiresAt}`);
    console.log(made.url);
    return 0;
  } catch (error) {
    const status = (error as { status?: number }).status;
    if (status === 503) console.error('The server has share links switched off. See the PR for #3239 for the steps to turn them on.');
    else if (status === 413) console.error('The server refused the packet as too large.');
    else if (status === 429) console.error('The server is rate-limiting uploads from this address. Try again later.');
    else console.error((error as Error).message);
    return 1;
  }
}

if (import.meta.main) process.exitCode = await main(process.argv.slice(2));
