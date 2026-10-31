// Stand-in for the packet thread's `recordVoiceMargin()` (#2984). It records whatever the browser's
// MediaRecorder gives (often WebM/Opus in Chrome). Packets need AAC in `.m4a`, so wave 2 swaps in #2984's
// recorder in `services.ts`; voice Margins recorded with this stub play here but aren't packet-ready.
import type { RecorderPort, VoiceRecording } from '../ports.ts';

const PREFERRED = ['audio/mp4;codecs=mp4a.40.2', 'audio/mp4', 'audio/webm;codecs=opus', 'audio/webm'];

export const stubRecorder: RecorderPort = {
  async start(): Promise<VoiceRecording> {
    if (typeof MediaRecorder === 'undefined' || !navigator.mediaDevices?.getUserMedia) {
      throw new Error('This browser can’t record audio.');
    }
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    const mimeType = PREFERRED.find((type) => MediaRecorder.isTypeSupported(type));
    const recorder = new MediaRecorder(stream, mimeType ? { mimeType } : undefined);
    const chunks: Blob[] = [];
    recorder.ondataavailable = (event) => {
      if (event.data.size > 0) chunks.push(event.data);
    };
    const startedAt = performance.now();
    recorder.start(250);
    const release = () => stream.getTracks().forEach((track) => track.stop());
    return {
      stop() {
        return new Promise((resolve) => {
          recorder.onstop = () => {
            release();
            const type = recorder.mimeType || mimeType || 'audio/webm';
            resolve({ blob: new Blob(chunks, { type }), mimeType: type, durationSeconds: (performance.now() - startedAt) / 1000 });
          };
          recorder.stop();
        });
      },
      cancel() {
        recorder.onstop = release;
        if (recorder.state !== 'inactive') recorder.stop();
        else release();
      },
    };
  },
};
