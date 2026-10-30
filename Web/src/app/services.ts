// The one place the UI's ports are bound to implementations. Wave 2 (#2979) replaces the stubs here with
// `src/sources/` (#2983) and `src/packet/` (#2984); no component imports a stub directly.
import type { Services } from './ports.ts';
import { stubPackets } from './stubs/packets.ts';
import { stubRecorder } from './stubs/recorder.ts';
import { stubSources } from './stubs/sources.ts';

export const services: Services = {
  sources: stubSources,
  recorder: stubRecorder,
  packets: stubPackets,
};
