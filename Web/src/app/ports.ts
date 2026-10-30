// The UI's view of the logic modules: `src/sources/` (#2983: podcast search, feed reading, Substack voice, the
// relay path) and `src/packet/` (#2984: `.spokenmargins` read and write, voice recording to AAC). The UI talks only
// to these interfaces; `services.ts` binds them to the real modules (#2979).
import type { AudioOrigin, Episode, Margin, Show } from '../shared/model.ts';

/**
 * Thrown when a feed can't be read straight from the browser and the listener hasn't allowed the relay. It is the
 * sources module's own class, so `instanceof` works on what the real module throws.
 */
export { NeedsRelayConsent } from '../sources/read.ts';

export interface FeedRead {
  show: Show;
  episodes: Episode[];
}

export interface PostVoice {
  audioUrl: string;
  audioOrigin: AudioOrigin;
  durationSeconds?: number;
}

export interface SourcesPort {
  /** Shows matching a name, newest-followed state not included. */
  searchPodcasts(term: string): Promise<Show[]>;
  /** Reads a feed. Throws `NeedsRelayConsent` when the browser can't and `relayAllowed` is false. */
  readFeed(feedUrl: string, options: { relayAllowed: boolean }): Promise<FeedRead>;
  /**
   * Finds a Substack post's own voice. Called only when the listener taps the post (owner, 2026-10-21),
   * which is why the reason is part of the call.
   */
  findPostVoice(pageUrl: string, options: { relayAllowed: boolean; reason: 'listener-tap' }): Promise<PostVoice | null>;
}

export interface RecordedVoice {
  blob: Blob;
  mimeType: string;
  durationSeconds: number;
}

export interface VoiceRecording {
  /** Stops and returns what was recorded. */
  stop(): Promise<RecordedVoice>;
  /** Stops and throws the recording away. */
  cancel(): void;
}

export interface RecorderPort {
  /** Asks for the microphone and starts recording. Rejects when the browser or the listener says no. */
  start(): Promise<VoiceRecording>;
}

/** The episode a packet is about, as far as the packet says. */
export type PacketEpisode = Omit<Episode, 'id' | 'showId'> & { showTitle?: string; publisher?: string };

export interface PacketRead {
  contentDigest: string;
  /** The sender's name, when they gave one. */
  sender?: string;
  episode: PacketEpisode;
  /** Margins placed by time. Their `episodeId` is a placeholder until the importer places them. */
  margins: Margin[];
  /** Margins on an article's text, which the web app can't place yet. */
  textMarginCount: number;
}

export interface PacketWritten {
  bytes: Uint8Array;
  fileName: string;
  mimeType: string;
  /** Ids of the Margins in the file. */
  included: string[];
  /** The app's words for Margins left out (no words to share), when any were. */
  notice?: string;
}

export interface PacketPort {
  /** Opens a `.spokenmargins` file. Throws a `PacketError` with a plain message when it can't. */
  readPacket(bytes: Uint8Array, fileName?: string): Promise<PacketRead>;
  /** Writes one episode's Margins as a `.spokenmargins` file the iPhone app imports. */
  writePacket(episode: Episode, margins: readonly Margin[], show?: Show): Promise<PacketWritten>;
}

export interface Services {
  sources: SourcesPort;
  recorder: RecorderPort;
  packets: PacketPort;
}
