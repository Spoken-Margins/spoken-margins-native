// The web-made packets in Contracts/fixtures/web-packets/, which SessionKit's WebPacketImportTests and
// WebReplyRoundTripTests import through the app's real reader. Regenerate with `node Web/src/packet/fixtures.ts` (from
// the repo root) after a writer change; the content digest stays the same unless what the packet says changes.
//
// app-parent.spokenmargins is the other way round: the packet Ana's app writes (a written Margin a-1 at 12:34), written
// by `SM_WRITE_FIXTURES=1` in WebReplyRoundTripTests. The two reply packets answer it, naming its digest, so they must be
// regenerated whenever that packet changes (WebReplyRoundTripTests fails until the committed one is current).

import { readFileSync, writeFileSync } from 'node:fs';

import { readPacket } from './read.ts';
import { writePacket } from './write.ts';
import type { WrittenPacket } from './write.ts';
import type { Episode, Margin, Show } from '../shared/model.ts';
import { packetShowFor, placeImport } from '../app/logic/import.ts';

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

/** Ana's packet, as her app wrote it. The web reads it to learn the episode and the digest a reply names. */
export async function appParent() {
  return readPacket(new Uint8Array(readFileSync(new URL('app-parent.spokenmargins', fixtures))));
}

/**
 * A web friend's two answers to Ana's Margin `a-1` (12:34): one written, one by voice. The episode is the one Ana's
 * packet names, so the reply binds to her copy. The caller names the sender or leaves the name out, as a friend who never
 * typed one does: the app then says "Shared Margin", not a name.
 */
export async function replyMargins(): Promise<{ episode: Episode; show: Show; margins: Margin[] }> {
  const parent = await appParent();
  const e = parent.episode;
  const replyShow: Show = {
    id: 'show-web-reply-fixture', kind: 'podcast', title: e.showTitle ?? 'Example Show', followedAt: '2026-10-30T12:00:00Z',
    ...(e.publisher && { author: e.publisher }),
  };
  const replyEpisode: Episode = {
    id: 'episode-web-reply-fixture', showId: replyShow.id, title: e.title,
    ...(e.guid && { guid: e.guid }), ...(e.pageUrl && { pageUrl: e.pageUrl }),
    ...(e.audioUrl && { audioUrl: e.audioUrl, audioOrigin: 'podcast-enclosure' as const }),
    ...(e.durationSeconds !== undefined && { durationSeconds: e.durationSeconds }),
    ...(e.publishedAt && { publishedAt: e.publishedAt }),
  };
  const replyToId = `packet:${parent.contentDigest}:a-1`;
  const [text, voice] = voiceMargins() as [Margin, Margin];
  return {
    episode: replyEpisode,
    show: replyShow,
    margins: [
      { ...text, id: 'r1', episodeId: replyEpisode.id, atSeconds: 755, text: 'A written reply from the web, a second after yours.', replyToId },
      { ...voice, id: 'r2', episodeId: replyEpisode.id, atSeconds: 790.5, replyToId },
    ],
  };
}

async function writeReply(name: string, sender?: string): Promise<WrittenPacket> {
  const { episode: e, show: s, margins } = await replyMargins();
  return writePacket(e, margins, {
    show: s, ...(sender && { sender }), packageId: `package-web-fixture-${name}`, createdAt: new Date('2026-10-30T12:00:00.000Z'),
  });
}

/**
 * A friend who opened Ana's link on the web, where her episode is not followed, so the web filed it under "Shared by Ana"
 * (#4689). `asShared` is what the web writes now: the show Ana's packet named. `holderTitled` is what earlier web builds
 * wrote: the holder's title as the show, which made the iPhone import a second copy of the episode beside Ana's own.
 */
async function writeReplyFromSharedHolder(name: string, holderTitled: boolean): Promise<WrittenPacket> {
  const parent = await appParent();
  const placed = placeImport(parent, [], [], '2026-10-30T12:00:00Z');
  const holder = placed.show as Show;
  const replyToId = placed.margins[0]?.id;
  const margins: Margin[] = [
    { id: 'h1', episodeId: placed.episode.id, atSeconds: 755, createdAt: '2026-10-30T12:00:00Z', text: 'A reply from a friend who does not follow the show.', ...(replyToId && { replyToId }) },
  ];
  const show = holderTitled ? holder : packetShowFor(holder, placed.episode);
  return writePacket(placed.episode, margins, {
    ...(show && { show }), sender: 'Web friend', packageId: `package-web-fixture-${name}`, createdAt: new Date('2026-10-30T12:00:00.000Z'),
  });
}

export const writeReplyFromShared = (): Promise<WrittenPacket> => writeReplyFromSharedHolder('reply-from-shared', false);
export const writeReplyHolderTitled = (): Promise<WrittenPacket> => writeReplyFromSharedHolder('reply-holder-titled', true);

export const writeReplyNamed = (): Promise<WrittenPacket> => writeReply('reply', 'Web fixture');
export const writeReplyUnnamed = (): Promise<WrittenPacket> => writeReply('reply-unnamed');

export const writeWritten = (): Promise<WrittenPacket> => writePacket(episode, writtenMargins(), options('written'));
export const writeVoice = (): Promise<WrittenPacket> => writePacket(episode, voiceMargins(), options('voice'));
export const writePlaceholder = (): Promise<WrittenPacket> => writePacket(episode, placeholderMargins(), options('voice-placeholder'));

if (import.meta.main) {
  writeFileSync(new URL('web-written.spokenmargins', fixtures), (await writeWritten()).bytes);
  writeFileSync(new URL('web-voice.spokenmargins', fixtures), (await writeVoice()).bytes);
  writeFileSync(new URL('web-voice-placeholder.spokenmargins', fixtures), (await writePlaceholder()).bytes);
  writeFileSync(new URL('web-reply.spokenmargins', fixtures), (await writeReplyNamed()).bytes);
  writeFileSync(new URL('web-reply-unnamed.spokenmargins', fixtures), (await writeReplyUnnamed()).bytes);
  writeFileSync(new URL('web-reply-from-shared.spokenmargins', fixtures), (await writeReplyFromShared()).bytes);
  writeFileSync(new URL('web-reply-holder-titled.spokenmargins', fixtures), (await writeReplyHolderTitled()).bytes);
  console.log('wrote web-written, web-voice, web-voice-placeholder, web-reply, web-reply-unnamed, web-reply-from-shared and web-reply-holder-titled (.spokenmargins)');
}
