import { capacitorBridge } from '../sources/native-http.ts';
import { shareNativePacket } from './logic/native-packets.ts';

// Hands a file to the browser's own download, the one way to save a file that works in every browser.
export function downloadFile(file: File): void {
  const url = URL.createObjectURL(file);
  const link = document.createElement('a');
  link.href = url;
  link.download = file.name;
  document.body.append(link);
  link.click();
  link.remove();
  // Long enough for a slow phone to start the download; then the memory goes back.
  window.setTimeout(() => URL.revokeObjectURL(url), 30_000);
}

/**
 * Saves a file the listener asked for, the way this page can. Inside the Android app (#3009) the WebView ignores a
 * blob download, so the file goes to the app's cache and Android's share sheet, which can save it to Files or Drive;
 * everywhere else it is the browser's download. `'cancelled'` means the listener closed the share sheet, so nothing
 * was saved and nothing should say it was.
 */
export async function saveFile(file: File, title: string): Promise<'saved' | 'cancelled'> {
  const bridge = capacitorBridge();
  if (!bridge) {
    downloadFile(file);
    return 'saved';
  }
  const bytes = new Uint8Array(await file.arrayBuffer());
  return (await shareNativePacket(bridge, bytes, file.name, title)) === 'cancelled' ? 'cancelled' : 'saved';
}
