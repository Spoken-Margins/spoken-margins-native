// The real link server (research/B4/server) on 8899 for the recipient capture, with links on and one sealed link
// seeded under the test vector's key: the page a friend's browser opens first. Built into a temp folder each run.
// Run by capture/playwright.config.ts; the seeded link's address goes to `sm-landing-seeded-link.txt` in the temp folder.
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { keyFromFragment, sealPart, PART } from '../../src/packet/share-link.ts';

const repo = fileURLToPath(new URL('../../../', import.meta.url));
const port = Number(process.env.SM_LANDING_PORT ?? 8899);
const origin = `http://127.0.0.1:${port}`;
const work = mkdtempSync(join(tmpdir(), 'sm-landing-'));
const seeded = join(tmpdir(), 'sm-landing-seeded-link.txt');
rmSync(seeded, { force: true });
const binary = join(work, 'smserver');

execFileSync('go', ['build', '-o', binary, './cmd/smserver'], { cwd: join(repo, 'research/B4/server'), stdio: 'inherit' });
execFileSync(binary, ['switch', '-public', join(work, 'public'), 'links', 'on'], { stdio: 'inherit' });
const server = spawn(
  binary,
  ['serve', '-listen', `127.0.0.1:${port}`, '-state', join(work, 'state'), '-public', join(work, 'public'),
    '-links-install-url', 'https://testflight.apple.com/join/EXAMPLE'],
  { stdio: 'inherit' },
);
process.on('SIGTERM', () => server.kill());
process.on('SIGINT', () => server.kill());

for (let tries = 0; ; tries += 1) {
  try {
    if ((await fetch(`${origin}/api/v1/health`)).ok) break;
  } catch {
    if (tries > 50) throw new Error('the link server did not start');
  }
  await new Promise((resolve) => setTimeout(resolve, 200));
}

// What the phone seals today: a podcast episode and three Margins, the shape of link-preview.v1.
const vector = JSON.parse(readFileSync(join(repo, 'research/B4/contracts/fixtures/share-link-sealing-vector.json'), 'utf8'));
const key = keyFromFragment(vector.keyFragment) as Uint8Array;
const preview = {
  schema: 'spokenmargins.link-preview.v1',
  source: { title: 'Episode 1 (example episode)', show: 'Example Podcast', url: 'https://example.com/podcast/episode-1' },
  margins: [
    { text: 'This is the part I wanted you to hear.', before: 'and that is why most people get the first step wrong', after: 'so let me explain' },
    { text: 'This reminded me of our camping trip.' },
    { text: 'Do you agree with this? I am not sure I do.', before: 'the evidence points one way' },
  ],
};
const packet = new Uint8Array(readFileSync(join(repo, 'Contracts/fixtures/web-packets/web-voice.spokenmargins')));
const form = new FormData();
form.append('preview', new Blob([await sealPart(new TextEncoder().encode(JSON.stringify(preview)), PART.preview, key)]), 'preview');
form.append('packet', new Blob([await sealPart(packet, PART.packet, key)]), 'packet');
const made = await fetch(`${origin}/api/v1/links`, { method: 'POST', body: form });
if (made.status !== 201) throw new Error(`seeding the link answered ${made.status}`);
const link = `${origin}${(await made.json()).path}#${vector.keyFragment}`;
writeFileSync(seeded, link);
console.log(`landing server on ${origin}, seeded ${link}`);
