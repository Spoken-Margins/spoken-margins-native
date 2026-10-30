// Stand-in for `src/packet/` (#2984). Opening a `.spokenmargins` file needs that module's reader; until it
// merges, a shared file gets a plain message instead of a half-right import.
import type { PacketPort } from '../ports.ts';

export const stubPackets: PacketPort = {
  async readPacket() {
    throw new Error('Opening Margin files arrives in the next update of the web app.');
  },
};
