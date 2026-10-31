// Real-browser check of recordVoiceMargin: does a voice Margin keep its start? (#2984)
//
// Each run launches a fresh browser, so every recording is the first in its process, when the microphone is
// slowest to warm up. The page taps a button (a user gesture, as on the phone), calls recordVoiceMargin, holds
// for 3 s after it resolves (that is when the app shows "Recording"), stops, and reports the .m4a's length.
// A file shorter than the hold means audio after "Recording" was lost.
//
//   node Web/src/packet/record-browser-check.mjs [--runs 5] [--browsers webkit,chrome] [--paths auto,webcodecs-aac]
//
// Needs Playwright (Web/package.json's devDependencies; set PLAYWRIGHT to its index.mjs to use another copy) and
// esbuild (the root package.json). Chrome runs as real Chrome (`channel: 'chrome'`) with its fake microphone;
// WebKit is Playwright's build with mock capture, a stand-in for Safari and not Safari itself. Neither tells us
// what a voice sounds like. Not part of `npm run test:web`: it needs real browsers.
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: {
    runs: { type: 'string', default: '5' },
    browsers: { type: 'string', default: 'webkit,chrome' },
    paths: { type: 'string', default: 'auto' },
    hold: { type: 'string', default: '3000' },
  },
});
const runs = Number(values.runs);
const holdMs = Number(values.hold);
// MediaRecorder's file can end up to one AAC frame (21-23 ms) short of the hold; anything more is lost audio.
const toleranceMs = 60;

const { chromium, webkit } = await import(process.env.PLAYWRIGHT ?? 'playwright');
const esbuild = await import('esbuild');
const entry = fileURLToPath(new URL('./record.ts', import.meta.url));
const bundle = (await esbuild.build({ entryPoints: [entry], bundle: true, format: 'esm', write: false, target: 'es2022' })).outputFiles[0].text;

const server = http.createServer((request, response) => {
  if (request.url === '/record.js') {
    response.setHeader('content-type', 'text/javascript');
    response.end(bundle);
    return;
  }
  response.setHeader('content-type', 'text/html');
  response.end('<!doctype html><title>record check</title><button id=go>Record</button>');
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const url = `http://localhost:${server.address().port}/`;

const launchers = {
  webkit: () => webkit.launch(),
  chrome: () => chromium.launch({ channel: 'chrome', args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] }),
};

let short = 0;
for (const name of values.browsers.split(',')) {
  for (const path of values.paths.split(',')) {
    const rows = [];
    let version = '';
    for (let i = 0; i < runs; i += 1) {
      const browser = await launchers[name]();
      version = browser.version();
      const context = await browser.newContext();
      await context.grantPermissions(['microphone']);
      const page = await context.newPage();
      await page.goto(url);
      await page.evaluate(() => {
        window.tapped = new Promise((resolve) => document.getElementById('go').addEventListener('click', resolve, { once: true }));
      });
      await page.click('#go');
      const row = await page.evaluate(async ({ forced, hold }) => {
        await window.tapped;
        const { recordVoiceMargin } = await import('/record.js');
        const begun = performance.now();
        const recording = await recordVoiceMargin(forced === 'auto' ? {} : { path: forced });
        const readyMs = Math.round(performance.now() - begun);
        await new Promise((resolve) => setTimeout(resolve, hold));
        const voice = await recording.stop();
        return { path: voice.path, seconds: voice.durationSeconds, readyMs, warmUp: recording.warmUp };
      }, { forced: path, hold: holdMs }).catch((error) => ({ error: String(error).slice(0, 300) }));
      rows.push(row);
      await browser.close();
    }
    for (const row of rows) if (row.error || row.seconds * 1000 < holdMs - toleranceMs) short += 1;
    console.log(JSON.stringify({ browser: name, version, path, holdMs, runs: rows }));
  }
}
server.close();
if (short) {
  console.error(`${short} recording(s) came out shorter than the ${holdMs} ms hold, or failed.`);
  process.exit(1);
}
