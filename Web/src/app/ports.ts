// The UI's view of the logic modules other threads are building (#2977, wave 1):
// - `src/sources/` (#2983): podcast search, feed reading, Substack voice, the relay path;
// - `src/packet/` (#2984): `.spokenmargins` read and write, and voice recording to AAC.
// The UI talks only to these interfaces. Until those modules merge, `stubs/` implements them well enough
// to use the app; wave 2 (#2979) swaps in the real ones in `services.ts` and nothing else changes.
import type { AudioOrigin, Episode, Margin, Show } from '../shared/model.ts';

/** Thrown when a feed can't be read straight from the browser and the listener hasn't allowed the relay. */
export class NeedsRelayConsent extends Error {
  readonly url: string;
  constructor(url: string) {
    super('This feed needs the Spoken Margins server to read it.');
    this.name = 'NeedsRelayConsent';
    this.url = url;
  }
}

export interface FeedRead {
  show: Show;
  episodes: Episode[];
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
  findPostVoice(
    pageUrl: string,
    options: { relayAllowed: boolean; reason: 'listener-tap' },
  ): Promise<{ audioUrl: string; audioOrigin: AudioOrigin } | null>;
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

export interface PacketRead {
  /** What the packet says about the episode it belongs to, for matching against the Library. */
  episode: Partial<Episode> & { title?: string };
  margins: Margin[];
}

export interface PacketPort {
  readPacket(bytes: Uint8Array): Promise<PacketRead>;
}

export interface Services {
  sources: SourcesPort;
  recorder: RecorderPort;
  packets: PacketPort;
}
