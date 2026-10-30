// Every refusal is one error type with one plain message, as the iPhone app tells a listener
// (SpokenMarginsPackageArchiveError.ListenerOutcome, #1968). `detail` keeps the technical reason for bug reports.

export type PacketOutcome = 'notAPacket' | 'needsNewerApp' | 'tooLarge' | 'damaged' | 'doesNotMatch' | 'cannotShare';

export const PACKET_MESSAGES: Readonly<Record<PacketOutcome, string>> = Object.freeze({
  notAPacket: "This isn't a Spoken Margins file. Margins arrive as a file ending in .spokenmargins.",
  needsNewerApp: 'These Margins need a newer Spoken Margins. Update the app, then open them again.',
  tooLarge: 'This file is bigger than Spoken Margins can open. Ask your friend to send fewer Margins at a time.',
  damaged: 'This file looks damaged. Ask your friend to send it again.',
  doesNotMatch:
    "These Margins don't match what is in your Library. Check you have the same item and edition, then open them again. If it still fails, ask your friend to send them again.",
  cannotShare: "These Margins can't be shared yet.",
});

export class PacketError extends Error {
  readonly outcome: PacketOutcome;
  readonly detail: string;

  constructor(outcome: PacketOutcome, detail: string, message: string = PACKET_MESSAGES[outcome]) {
    super(message);
    this.name = 'PacketError';
    this.outcome = outcome;
    this.detail = detail;
  }
}

export const damaged = (detail: string): PacketError => new PacketError('damaged', detail);
export const tooLarge = (detail: string): PacketError => new PacketError('tooLarge', detail);
export const newerApp = (detail: string): PacketError => new PacketError('needsNewerApp', detail);
export const mismatch = (detail: string): PacketError => new PacketError('doesNotMatch', detail);
