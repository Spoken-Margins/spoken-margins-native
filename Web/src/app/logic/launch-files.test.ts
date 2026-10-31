import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { consumeLaunchQueue, launchedFiles, type LaunchParamsLike } from './launch-files.ts';

const file = (name: string) => new File([new Uint8Array([80, 75, 3, 4])], name);
const handle = (f: File) => ({ kind: 'file', getFile: async () => f });

test('a launch hands over its files in order, leaving out folders and files that are gone', async () => {
  const a = file('a.spokenmargins');
  const b = file('b.spokenmargins');
  const params: LaunchParamsLike = {
    files: [handle(a), { kind: 'directory', getFile: async () => file('nope') }, { kind: 'file', getFile: async () => Promise.reject(new Error('gone')) }, handle(b)],
  };
  assert.deepEqual(
    (await launchedFiles(params)).map((f) => f.name),
    ['a.spokenmargins', 'b.spokenmargins'],
  );
  assert.deepEqual(await launchedFiles({}), []);
});

test('the launch queue is used where the browser has one, and only files that arrive are passed on', async () => {
  let consumer: ((params: LaunchParamsLike) => void) | undefined;
  const host = { launchQueue: { setConsumer: (c: (params: LaunchParamsLike) => void) => (consumer = c) } };
  const received: string[][] = [];
  assert.equal(consumeLaunchQueue(host, (files) => received.push(files.map((f) => f.name))), true);
  consumer?.({ files: [] });
  consumer?.({ files: [handle(file('sam.spokenmargins'))] });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(received, [['sam.spokenmargins']]);
  // Safari and Firefox: no queue, nothing set up.
  assert.equal(consumeLaunchQueue({}, () => undefined), false);
  assert.equal(consumeLaunchQueue(undefined, () => undefined), false);
});

const manifest = JSON.parse(readFileSync(new URL('../../../public/manifest.webmanifest', import.meta.url), 'utf8')) as {
  scope: string;
  file_handlers?: Array<{ action: string; accept: Record<string, string[]>; launch_type?: string }>;
  share_target?: { params: { files: Array<{ accept: string[] }> } };
};

test('the installed app is an opener for .spokenmargins files, and keeps its share target', () => {
  const handlers = manifest.file_handlers ?? [];
  const handler = handlers.find((h) => Object.values(h.accept).some((extensions) => extensions.includes('.spokenmargins')));
  assert.ok(handler, 'a file handler accepts .spokenmargins');
  // Within the app's scope, so the browser launches this app, and one window takes every file.
  assert.ok(handler.action.startsWith(manifest.scope), `${handler.action} is within ${manifest.scope}`);
  assert.equal(handler.launch_type, 'single-client');
  assert.deepEqual(handler.accept['application/vnd.spokenmargins.package+zip'], ['.spokenmargins']);
  // Not an opener for every .zip on the computer: a Settings backup opens from the picker or a drop.
  assert.equal(Object.values(handler.accept).flat().includes('.zip'), false);
  // Android's share sheet still sends packets to the installed app.
  assert.ok(manifest.share_target?.params.files.some((f) => f.accept.includes('.spokenmargins')));
});
