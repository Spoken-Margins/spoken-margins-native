// The three web-made packets in Contracts/fixtures/web-packets/, which SessionKit's WebPacketImportTests imports
// through the app's real reader. Regenerate with `node Web/src/packet/fixtures.ts` (from the repo root) after a
// writer change; the content digest stays the same unless what the packet says changes.

import { readFileSync, writeFileSync } from 'node:fs';

import { writePacket } from './write.ts';
import type { WrittenPacket } from './write.ts';
import type { Episode, Margin, Show } from '../shared/model.ts';

const fixtures = new URL('../../../Contracts/fixtures/web-packets/', import.meta.url);

export const show: Show = {
  id: 'show-web-fixture',
  kind: 'podcast',
  title: 'Example Show',
  author: 'Example Publisher',
  feedUrl: 'https://example.com/podcast/feed.xml',
  followedAt: '2026-10-30T12:00:00Z',
};

export const episode: Episode = {
  id: 'episode-web-fixture',
  showId: show.id,
  title: 'Episode 1 (example episode)',
  guid: 'example-episode-guid-1',
  pageUrl: 'https://example.com/podcast/episode-1',
  audioUrl: 'https://example.com/podcast/episode-1.mp3',
  audioOrigin: 'podcast-enclosure',
  durationSeconds: 1800,
  publishedAt: '2026-08-20T12:00:00Z',
};

const options = (name: string) => ({
  show,
  sender: 'Web fixture',
  packageId: `package-web-fixture-${name}`,
  createdAt: new Date('2026-10-30T12:00:00.000Z'),
});

export function writtenMargins(): Margin[] {
  return [
    { id: 'w1', episodeId: episode.id, atSeconds: 65, createdAt: '2026-10-30T11:00:00Z', text: 'A written Margin from the web, 1:05 in.' },
    { id: 'w2', episodeId: episode.id, atSeconds: 600.4, createdAt: '2026-10-30T11:05:00Z', text: 'Another at ten minutes.' },
  ];
}

/** voice-fragmented.mp4 is the shape Chrome's MediaRecorder writes; the writer rewrites it as a plain m4a. */
export function voiceMargins(): Margin[] {
  const recorded = readFileSync(new URL('audio/voice-fragmented.mp4', fixtures));
  return [
    { id: 't1', episodeId: episode.id, atSeconds: 30, createdAt: '2026-10-30T11:00:00Z', text: 'A written Margin at half a minute.' },
    {
      id: 'v1', episodeId: episode.id, atSeconds: 125.25, createdAt: '2026-10-30T11:02:00Z',
      text: 'This is a web Margin, recorded for the packet test.',
      voice: { blob: new Blob([recorded], { type: 'audio/mp4' }), mimeType: 'audio/mp4', durationSeconds: 2.9 },
    },
  ];
}

/**
 * A voice Margin the listener left without words, which travels with placeholder words (#3025). Recorded at noon UTC,
 * so its placeholder names 30 Oct 2026 wherever the fixture is regenerated (UTC−11 to UTC+11).
 */
export function placeholderMargins(): Margin[] {
  const [, voice] = voiceMargins() as [Margin, Margin];
  return [{ ...voice, id: 'p1', atSeconds: 45, createdAt: '2026-10-30T12:00:00Z', text: undefined }];
}

export const writeWritten = (): Promise<WrittenPacket> => writePacket(episode, writtenMargins(), options('written'));
export const writeVoice = (): Promise<WrittenPacket> => writePacket(episode, voiceMargins(), options('voice'));
export const writePlaceholder = (): Promise<WrittenPacket> => writePacket(episode, placeholderMargins(), options('voice-placeholder'));

if (import.meta.main) {
  writeFileSync(new URL('web-written.spokenmargins', fixtures), (await writeWritten()).bytes);
  writeFileSync(new URL('web-voice.spokenmargins', fixtures), (await writeVoice()).bytes);
  writeFileSync(new URL('web-voice-placeholder.spokenmargins', fixtures), (await writePlaceholder()).bytes);
  console.log('wrote web-written.spokenmargins, web-voice.spokenmargins and web-voice-placeholder.spokenmargins');
}
