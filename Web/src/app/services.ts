// The one place the UI's ports are bound to implementations: `src/sources/` (#2983) and `src/packet/` (#2984).
// No component imports those modules directly, so a test or a later swap changes only this file.
import { readPacket } from '../packet/read.ts';
import { recordVoiceMargin } from '../packet/record.ts';
import { writePacket } from '../packet/write.ts';
import { readFeed, readSubstackVoice, searchPodcasts } from '../sources/index.ts';
import type { PacketPort, RecorderPort, Services, SourcesPort } from './ports.ts';

/**
 * The share-link server's origin, whose `/api/v1/relay` reads feeds a browser may not (#2985). Set at build time
 * (`VITE_RELAY_ORIGIN`); empty means this build has no relay, and a blocked feed says so after asking.
 */
export const RELAY_ORIGIN: string = ((import.meta.env.VITE_RELAY_ORIGIN as string | undefined) ?? '').trim();

const relayBase = (): { relayBase?: string } => (RELAY_ORIGIN ? { relayBase: RELAY_ORIGIN } : {});

const sources: SourcesPort = {
  searchPodcasts: (term) => searchPodcasts(term),
  async readFeed(feedUrl, { relayAllowed }) {
    const { show, episodes } = await readFeed(feedUrl, { consent: relayAllowed, ...relayBase(), reason: 'feed-refresh' });
    return { show, episodes };
  },
  async findPostVoice(pageUrl, { relayAllowed }) {
    const voice = await readSubstackVoice(pageUrl, { consent: relayAllowed, ...relayBase() });
    if (!voice) return null;
    return {
      audioUrl: voice.audioUrl,
      audioOrigin: voice.origin,
      ...(voice.durationSeconds !== undefined && { durationSeconds: voice.durationSeconds }),
    };
  },
};

const recorder: RecorderPort = {
  start: () => recordVoiceMargin(),
};

const packets: PacketPort = {
  async readPacket(bytes, fileName) {
    const read = await readPacket(bytes, fileName === undefined ? {} : { fileName });
    const { itemType: _itemType, ...episode } = read.episode;
    return {
      contentDigest: read.contentDigest,
      ...(read.sender && { sender: read.sender }),
      episode,
      margins: read.margins,
      textMarginCount: read.textMargins.length,
    };
  },
  async writePacket(episode, margins, show) {
    const written = await writePacket(episode, margins, show ? { show } : {});
    return {
      bytes: written.bytes,
      fileName: written.fileName,
      mimeType: written.mimeType,
      included: written.included,
      ...(written.notice && { notice: written.notice }),
    };
  },
};

export const services: Services = { sources, recorder, packets };
