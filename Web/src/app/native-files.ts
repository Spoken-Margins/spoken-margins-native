// Inside the Android app (#3009): a `.spokenmargins` file another app opens or shares with Spoken Margins arrives
// from Android as a file URI. This hook reads each one and opens it like a picked file. In a browser it does nothing;
// there the service worker's share target (`shared-files.ts`) does this job.
import { useEffect } from 'react';
import { capacitorBridge } from '../sources/native-http.ts';
import { useData } from './data.tsx';
import type { OpenMarginFile } from './import.tsx';
import { listenForOpenedFiles, readNativeFile } from './logic/native-packets.ts';
import { plainError } from './logic/messages.ts';
import { useUi } from './ui.tsx';

export function useNativeOpenedFiles(open: OpenMarginFile): void {
  const data = useData();
  const { toast } = useUi();

  useEffect(() => {
    const bridge = capacitorBridge();
    // Wait for the Library: the App plugin keeps the launch file until a listener attaches.
    if (!bridge || !data.ready) return;
    return listenForOpenedFiles(bridge, (uri) => {
      void (async () => {
        try {
          const { bytes, fileName } = await readNativeFile(bridge, uri);
          await open(bytes, fileName);
        } catch (error) {
          toast(`Couldn’t open the file. ${plainError(error)}`, 'problem');
        }
      })();
    });
  }, [data.ready, open, toast]);
}
