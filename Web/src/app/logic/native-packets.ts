// `.spokenmargins` files inside the Android app (#3009). The Android WebView has no Web Share and ignores a blob
// `<a download>`, so in the app a packet is written with Capacitor's Filesystem plugin and offered through the
// Android share sheet (Share plugin), where the listener can send it or save it to Files or Drive. A packet another
// app opens or shares with Spoken Margins arrives as `appUrlOpen` (App plugin; `MainActivity` turns a share into a
// view) and is read with Filesystem. In a browser none of this runs: the download link and Web Share stay.
//
// Like `src/sources/native-http.ts`, this calls the bridge Capacitor injects into the WebView, so it imports no
// package and runs in node tests with a stand-in bridge. The native plugins come from `@capacitor/filesystem`,
// `@capacitor/share` and `@capacitor/app`, which `cap sync` adds to the Android project.

import { capacitorBridge } from '../../sources/native-http.ts';
import type { CapacitorBridge } from '../../sources/native-http.ts';

export type PacketRoute = 'native' | 'browser';

/** The file picker's filter in a browser. */
export const BROWSER_PACKET_ACCEPT = '.spokenmargins,application/vnd.spokenmargins.package+zip';

/** Where this page saves and opens packets: the Android app's own path inside Capacitor, the browser's elsewhere. */
export function packetRoute(host: unknown = globalThis): PacketRoute {
  return capacitorBridge(host) ? 'native' : 'browser';
}

/**
 * The file picker's filter. Android knows no `.spokenmargins` type, so a document provider reports such a file as
 * `application/octet-stream` and a filter would grey it out. In the app the picker shows every file, and a file that
 * isn't a packet gets the usual plain message when it is read.
 */
export function packetPickerAccept(route: PacketRoute): string | undefined {
  return route === 'native' ? undefined : BROWSER_PACKET_ACCEPT;
}

const BASE64_CHUNK = 0x8000;

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  for (let start = 0; start < bytes.length; start += BASE64_CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(start, start + BASE64_CHUNK));
  }
  return btoa(binary);
}

export function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64.replace(/\s+/g, ''));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** A name safe to write in the app's cache folder; the share sheet shows it as the file's name. */
export function cacheFileName(fileName: string): string {
  const base = fileName.split(/[\\/]/).pop() ?? '';
  const cleaned = base.replace(/[\u0000-\u001f\u007f:*?"<>|]+/g, ' ').replace(/\s+/g, ' ').replace(/^\.+/, '').trim();
  const named = cleaned || 'Margins';
  return named.toLowerCase().endsWith('.spokenmargins') ? named : `${named}.spokenmargins`;
}

/** Packets waiting in the share sheet live here, inside the app's cache folder, which Android may clear. */
export const NATIVE_PACKET_FOLDER = 'packets';

function messageOf(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (error && typeof error === 'object' && typeof (error as { message?: unknown }).message === 'string') return (error as { message: string }).message;
  return String(error);
}

/**
 * Writes the packet to the app's cache and opens the Android share sheet with it. Resolves `'shared'` when the
 * listener picked a target and `'cancelled'` when they closed the sheet.
 */
export async function shareNativePacket(
  bridge: CapacitorBridge,
  bytes: Uint8Array,
  fileName: string,
  title: string,
): Promise<'shared' | 'cancelled'> {
  const written = (await bridge.nativePromise('Filesystem', 'writeFile', {
    path: `${NATIVE_PACKET_FOLDER}/${cacheFileName(fileName)}`,
    data: bytesToBase64(bytes),
    directory: 'CACHE',
    recursive: true,
  })) as { uri?: unknown } | null;
  const uri = written?.uri;
  if (typeof uri !== 'string' || !uri) throw new Error('The file couldn’t be written on this phone.');
  try {
    await bridge.nativePromise('Share', 'share', { title, files: [uri], dialogTitle: 'Share these Margins' });
  } catch (error) {
    // The Share plugin rejects with "Share canceled" when the sheet is closed.
    if (/cancel/i.test(messageOf(error))) return 'cancelled';
    throw error;
  }
  return 'shared';
}

/** The file's name when a URI carries one, so the import message can name it. Opaque content URIs give none. */
export function fileNameFromUri(uri: string): string | undefined {
  let path: string;
  try {
    path = new URL(uri).pathname;
  } catch {
    return undefined;
  }
  const last = path.split('/').pop() ?? '';
  let name: string;
  try {
    name = decodeURIComponent(last);
  } catch {
    name = last;
  }
  name = name.split(/[\\/:]/).pop() ?? '';
  return /\.spokenmargins$/i.test(name) ? name : undefined;
}

/** Reads a file another app opened or shared with Spoken Margins (`content://` or `file://`). */
export async function readNativeFile(bridge: CapacitorBridge, uri: string): Promise<{ bytes: Uint8Array; fileName: string | undefined }> {
  const read = (await bridge.nativePromise('Filesystem', 'readFile', { path: uri })) as { data?: unknown } | null;
  const data = read?.data;
  if (typeof data !== 'string') throw new Error('The file couldn’t be read on this phone.');
  return { bytes: base64ToBytes(data), fileName: fileNameFromUri(uri) };
}

/** The bridge's event hook (`window.Capacitor.addListener` from native-bridge.js). */
interface BridgeWithListeners {
  addListener?: (pluginName: string, eventName: string, callback: (data: unknown) => void) => { remove: () => unknown } | undefined;
}

/**
 * Calls `onFile` with each file URI Android opens the app with: the launch one (the App plugin keeps it until a
 * listener attaches) and any later one. Web addresses are ignored; only files are packets. Returns a stop function.
 */
export function listenForOpenedFiles(bridge: CapacitorBridge, onFile: (uri: string) => void): () => void {
  const addListener = (bridge as CapacitorBridge & BridgeWithListeners).addListener;
  if (typeof addListener !== 'function') return () => {};
  const handle = addListener.call(bridge, 'App', 'appUrlOpen', (data) => {
    const url = (data as { url?: unknown } | null)?.url;
    if (typeof url === 'string' && /^(content|file):/i.test(url)) onFile(url);
  });
  return () => {
    void handle?.remove();
  };
}
