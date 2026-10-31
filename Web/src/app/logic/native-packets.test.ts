import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { CapacitorBridge } from '../../sources/native-http.ts';
import {
  BROWSER_PACKET_ACCEPT,
  base64ToBytes,
  bytesToBase64,
  cacheFileName,
  fileNameFromUri,
  listenForOpenedFiles,
  packetPickerAccept,
  packetRoute,
  readNativeFile,
  shareNativePacket,
} from './native-packets.ts';

interface Call {
  plugin: string;
  method: string;
  options: Record<string, unknown>;
}

type Handler = (options: Record<string, unknown>) => unknown;

/** A stand-in for Capacitor's injected bridge: plugin methods answer from `handlers`, listeners are kept for `emit`. */
function fakeBridge(handlers: Record<string, Handler> = {}, calls: Call[] = []) {
  const listeners: { plugin: string; event: string; callback: (data: unknown) => void; removed: boolean }[] = [];
  const bridge = {
    isNativePlatform: () => true,
    nativePromise: async (plugin: string, method: string, options: Record<string, unknown>) => {
      calls.push({ plugin, method, options });
      const handler = handlers[`${plugin}.${method}`];
      if (!handler) throw new Error(`${plugin}.${method} is not implemented`);
      return handler(options);
    },
    addListener: (plugin: string, event: string, callback: (data: unknown) => void) => {
      const entry = { plugin, event, callback, removed: false };
      listeners.push(entry);
      return { remove: () => { entry.removed = true; } };
    },
  };
  const emit = (plugin: string, event: string, data: unknown) => {
    for (const entry of listeners) if (!entry.removed && entry.plugin === plugin && entry.event === event) entry.callback(data);
  };
  return { bridge: bridge as CapacitorBridge, emit, listeners };
}

test('the choice: a browser (or node) uses the browser path and its picker filter', () => {
  assert.equal(packetRoute({}), 'browser');
  assert.equal(packetRoute(), 'browser');
  assert.equal(packetRoute({ Capacitor: { isNativePlatform: () => false, nativePromise: async () => ({}) } }), 'browser');
  assert.equal(packetPickerAccept('browser'), BROWSER_PACKET_ACCEPT);
});

test('the choice: inside the Android app, the native path, and a picker that doesn\'t grey out the file', () => {
  assert.equal(packetRoute({ Capacitor: fakeBridge().bridge }), 'native');
  // Android reports a `.spokenmargins` file as application/octet-stream, so any filter would hide it.
  assert.equal(packetPickerAccept('native'), undefined);
});

test('base64 round-trips every byte value, across the chunk boundary', () => {
  const bytes = new Uint8Array(0x8000 * 2 + 3);
  for (let i = 0; i < bytes.length; i++) bytes[i] = (i * 7) & 0xff;
  assert.deepEqual(base64ToBytes(bytesToBase64(bytes)), bytes);
  assert.deepEqual(base64ToBytes(bytesToBase64(new Uint8Array())), new Uint8Array());
  assert.equal(bytesToBase64(new Uint8Array([0, 255, 128])), Buffer.from([0, 255, 128]).toString('base64'));
});

test('the cache file name keeps the packet name and stays inside the folder', () => {
  assert.equal(cacheFileName('Show - Episode.spokenmargins'), 'Show - Episode.spokenmargins');
  assert.equal(cacheFileName('../../etc/passwd'), 'passwd.spokenmargins');
  assert.equal(cacheFileName('a\\b.SPOKENMARGINS'), 'b.SPOKENMARGINS');
  assert.equal(cacheFileName('..hidden'), 'hidden.spokenmargins');
  assert.equal(cacheFileName('Q: "why?" <x>|.spokenmargins'), 'Q why x .spokenmargins');
  assert.equal(cacheFileName(''), 'Margins.spokenmargins');
  assert.equal(cacheFileName('/'), 'Margins.spokenmargins');
});

test('saving in the app writes the bytes to the cache, then opens the share sheet with that file', async () => {
  const calls: Call[] = [];
  const { bridge } = fakeBridge(
    {
      'Filesystem.writeFile': () => ({ uri: 'file:///data/user/0/com.spokenmargins.android/cache/packets/x.spokenmargins' }),
      'Share.share': () => ({ activityType: 'com.google.android.apps.docs' }),
    },
    calls,
  );
  const bytes = new Uint8Array([0x50, 0x4b, 3, 4, 0, 255]);
  assert.equal(await shareNativePacket(bridge, bytes, 'x.spokenmargins', 'Episode'), 'shared');
  assert.deepEqual(calls, [
    {
      plugin: 'Filesystem',
      method: 'writeFile',
      options: { path: 'packets/x.spokenmargins', data: bytesToBase64(bytes), directory: 'CACHE', recursive: true },
    },
    {
      plugin: 'Share',
      method: 'share',
      options: {
        title: 'Episode',
        files: ['file:///data/user/0/com.spokenmargins.android/cache/packets/x.spokenmargins'],
        dialogTitle: 'Share these Margins',
      },
    },
  ]);
  assert.deepEqual(base64ToBytes(String(calls[0]!.options.data)), bytes, 'the bytes written are the packet\'s');
});

test('closing the share sheet is a cancel, not a failure; other share errors are failures', async () => {
  const write = () => ({ uri: 'file:///cache/packets/x.spokenmargins' });
  const cancelled = fakeBridge({ 'Filesystem.writeFile': write, 'Share.share': () => { throw { message: 'Share canceled' }; } });
  assert.equal(await shareNativePacket(cancelled.bridge, new Uint8Array([1]), 'x.spokenmargins', 't'), 'cancelled');
  const broken = fakeBridge({ 'Filesystem.writeFile': write, 'Share.share': () => { throw new Error('only file urls are supported'); } });
  await assert.rejects(shareNativePacket(broken.bridge, new Uint8Array([1]), 'x.spokenmargins', 't'), /file urls/);
});

test('a write that returns no file address fails before any share sheet', async () => {
  const calls: Call[] = [];
  const { bridge } = fakeBridge({ 'Filesystem.writeFile': () => ({}) }, calls);
  await assert.rejects(shareNativePacket(bridge, new Uint8Array([1]), 'x.spokenmargins', 't'), /couldn’t be written/);
  assert.deepEqual(calls.map((c) => c.method), ['writeFile']);
});

test('a file another app opens is read from its content address', async () => {
  const calls: Call[] = [];
  const bytes = new Uint8Array([0x50, 0x4b, 3, 4]);
  const { bridge } = fakeBridge({ 'Filesystem.readFile': () => ({ data: bytesToBase64(bytes) }) }, calls);
  const uri = 'content://com.android.providers.downloads.documents/document/msf%3A42';
  const read = await readNativeFile(bridge, uri);
  assert.deepEqual(read.bytes, bytes);
  assert.equal(read.fileName, undefined, 'an opaque content address names no file');
  assert.deepEqual(calls, [{ plugin: 'Filesystem', method: 'readFile', options: { path: uri } }]);
  const missing = fakeBridge({ 'Filesystem.readFile': () => ({}) });
  await assert.rejects(readNativeFile(missing.bridge, uri), /couldn’t be read/);
});

test('the file name comes from the address only when it names a packet', () => {
  assert.equal(fileNameFromUri('content://x.provider/root/Download%2FWeekly%20show.spokenmargins'), 'Weekly show.spokenmargins');
  assert.equal(fileNameFromUri('file:///storage/emulated/0/Download/a.spokenmargins'), 'a.spokenmargins');
  assert.equal(fileNameFromUri('content://x.provider/document/primary%3ADownload%2Fb.SpokenMargins'), 'b.SpokenMargins');
  assert.equal(fileNameFromUri('content://x.provider/document/1234'), undefined);
  assert.equal(fileNameFromUri('content://x.provider/bad%E0%A4%A'), undefined);
  assert.equal(fileNameFromUri('not a url'), undefined);
});

test('opened files: content and file addresses are passed on, web addresses ignored, and the listener stops', () => {
  const { bridge, emit, listeners } = fakeBridge();
  const seen: string[] = [];
  const stop = listenForOpenedFiles(bridge, (uri) => seen.push(uri));
  assert.deepEqual(listeners.map((l) => `${l.plugin}.${l.event}`), ['App.appUrlOpen']);
  emit('App', 'appUrlOpen', { url: 'content://x.provider/document/1' });
  emit('App', 'appUrlOpen', { url: 'file:///sdcard/a.spokenmargins' });
  emit('App', 'appUrlOpen', { url: 'https://example.com/p/post' });
  emit('App', 'appUrlOpen', null);
  assert.deepEqual(seen, ['content://x.provider/document/1', 'file:///sdcard/a.spokenmargins']);
  stop();
  emit('App', 'appUrlOpen', { url: 'content://x.provider/document/2' });
  assert.equal(seen.length, 2);
});

test('opened files: a bridge with no listener support is a no-op', () => {
  const bridge: CapacitorBridge = { isNativePlatform: () => true, nativePromise: async () => ({}) };
  const stop = listenForOpenedFiles(bridge, () => assert.fail('no file should arrive'));
  stop();
});
