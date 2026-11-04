// Guard for #3375: a web test run must never reach the Mac's speakers. Fails for a new Playwright config, project or spec
// that could play or speak out loud, and for a production build that carries the test-only silence code.
// The checks read the config files as text (the fast plan has no Playwright installed), so they look for the settings
// by their names; a new way of setting them needs this file changed with it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SILENT_ENV, SILENT_TAG_ID, e2eSilence } from '../../e2e/silence/silence-plugin.ts';

const web = fileURLToPath(new URL('../../', import.meta.url));
const SILENCE_SPEC = 'silence.spec.ts';

function walk(dir: string, found: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name.startsWith('dist')) continue;
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path, found);
    else found.push(path);
  }
  return found;
}

/** Every Playwright config under Web/ (not node_modules or a build). */
export const configs = (): string[] => walk(web).filter((path) => /playwright\.config\.ts$/.test(path));

const NOT_CHROMIUM = /devices\['(iPhone|iPad|Desktop Safari|Desktop Firefox|Mobile Safari)|browserName:\s*'(webkit|firefox)'/;

/** The regex literal after `key:` in a block, or undefined. */
function regexAfter(block: string, key: string): RegExp | undefined {
  const found = new RegExp(`${key}:\\s*/((?:\\\\.|[^/\\\\\\n])+)/(\\w*)`).exec(block);
  return found ? new RegExp(found[1]!, found[2]) : undefined;
}

/** What is wrong with one Playwright config's text: anything that lets a run reach real audio output. */
export function configProblems(source: string, hasSilenceSpec: boolean): string[] {
  const problems: string[] = [];
  // A comment that names a setting does not set it.
  const text = source.replace(/(^|\s)\/\/.*$/gm, '$1');
  const projectsAt = text.indexOf('projects:');
  const serversAt = text.indexOf('webServer:');
  const top = projectsAt >= 0 ? text.slice(0, projectsAt) : serversAt >= 0 ? text.slice(0, serversAt) : text;
  const projectsText = projectsAt >= 0 ? text.slice(projectsAt, serversAt > projectsAt ? serversAt : undefined) : '';
  const serversText = serversAt >= 0 ? text.slice(serversAt) : '';

  // Every web server that builds the app sets the variable that puts the silence script in the page.
  const entries = serversText.split(/(?=\bcommand:)/).slice(1);
  for (const entry of entries) {
    if (!/vite\s+(build|preview)/.test(entry)) continue;
    if (!new RegExp(`${SILENT_ENV}:\\s*'1'`).test(entry)) problems.push(`a webServer that builds the app does not set ${SILENT_ENV}: '1'`);
  }

  // Every Chromium-family project mutes the browser (WebKit refuses the switch and relies on the script).
  const blocks = projectsAt >= 0 ? projectsText.split(/(?=\bname:\s*')/).slice(1) : [text];
  for (const block of blocks) {
    const name = /name:\s*'([^']+)'/.exec(block)?.[1] ?? 'default project';
    if (!NOT_CHROMIUM.test(block)) {
      const muted = block.includes('--mute-audio') || (!block.includes('launchOptions') && top.includes('--mute-audio'));
      if (!muted) problems.push(`Chromium-family project "${name}" does not launch with --mute-audio`);
    }
    if (hasSilenceSpec) {
      const match = regexAfter(block, 'testMatch') ?? regexAfter(top, 'testMatch');
      const ignore = regexAfter(block, 'testIgnore') ?? regexAfter(top, 'testIgnore');
      if ((match && !match.test(SILENCE_SPEC)) || ignore?.test(SILENCE_SPEC)) problems.push(`project "${name}" does not run ${SILENCE_SPEC}`);
    }
  }
  return problems;
}

/** What is wrong with one spec's text: a way to make sound that skips the silence script, or speaks for itself. */
export function specProblems(text: string): string[] {
  const rules: Array<[RegExp, string]> = [
    [/new\s+Audio\s*\(/, 'new Audio( (an element made in the spec plays out loud; use the page)'],
    [/speechSynthesis\s*\.\s*speak\b/, 'speechSynthesis.speak (speak through the page, which has the stub)'],
    [/\.setContent\s*\(/, 'setContent (a page made this way has no silence script)'],
    [/goto\(\s*[`'"](data|about):/, 'goto of a data: or about: page (it has no silence script)'],
  ];
  return rules.filter(([pattern]) => pattern.test(text)).map(([, label]) => label);
}

test('every Playwright config mutes Chromium, builds with the silence script, and runs the silence spec', () => {
  const found = configs();
  assert.ok(found.length >= 2, 'expected the e2e and capture configs');
  const problems = found.flatMap((path) => {
    const hasSilenceSpec = existsSync(join(dirname(path), SILENCE_SPEC));
    return configProblems(readFileSync(path, 'utf8'), hasSilenceSpec).map((problem) => `${relative(web, path)}: ${problem}`);
  });
  assert.deepEqual(problems, []);
  assert.ok(existsSync(join(web, 'e2e', SILENCE_SPEC)));
});

test('the config check fails for each way a project or server could reach the speakers', () => {
  const good = readFileSync(join(web, 'e2e/playwright.config.ts'), 'utf8');
  assert.deepEqual(configProblems(good, true), []);
  const broken = [
    good.replace("'--use-fake-device-for-media-stream', '--mute-audio'", "'--use-fake-device-for-media-stream'"),
    good.replace(/'--use-fake-device-for-media-stream',\n\s*'--mute-audio',/, "'--use-fake-device-for-media-stream',"),
    good.replace("VITE_E2E_SILENT: '1' }", ' }'),
    good.replace('/(phone-[\\w-]+|silence)\\.spec', '/phone-[\\w-]+\\.spec'),
  ];
  for (const text of broken) assert.notDeepEqual(configProblems(text, true), [], 'a broken config passed');
  const added = good.replace("name: 'laptop',", "name: 'tablet',\n      use: { ...devices['Desktop Chrome'], launchOptions: { args: [] } },\n    },\n    {\n      name: 'laptop',");
  assert.deepEqual(configProblems(added, true), ['Chromium-family project "tablet" does not launch with --mute-audio']);
});

test('no spec makes its own sound or builds a page without the silence script', () => {
  const specs = walk(join(web, 'e2e')).filter((path) => /\.ts$/.test(path) && !/playwright\.config\.ts$/.test(path) && !path.includes(`${join(web, 'e2e', 'silence')}/`) && !path.endsWith(`/${SILENCE_SPEC}`));
  assert.ok(specs.length > 5);
  const problems = specs.flatMap((path) => specProblems(readFileSync(path, 'utf8')).map((problem) => `${relative(web, path)}: ${problem}`));
  assert.deepEqual(problems, []);
  assert.deepEqual(specProblems("await page.setContent('<audio autoplay src=x>')"), ['setContent (a page made this way has no silence script)']);
  assert.equal(specProblems("const a = new Audio('x')").length, 1);
  assert.equal(specProblems('await page.evaluate(() => speechSynthesis.speak(u))').length, 1);
  assert.equal(specProblems("await page.goto('data:text/html,<audio>')").length, 1);
});

test('the plugin adds the script only when VITE_E2E_SILENT=1', () => {
  const handler = (e2eSilence().transformIndexHtml as { handler: () => Array<{ attrs: { id: string }; children: string; injectTo: string }> | undefined }).handler;
  const saved = process.env[SILENT_ENV];
  try {
    delete process.env[SILENT_ENV];
    assert.equal(handler(), undefined);
    process.env[SILENT_ENV] = '0';
    assert.equal(handler(), undefined);
    process.env[SILENT_ENV] = '1';
    const [tag] = handler()!;
    assert.equal(tag!.attrs.id, SILENT_TAG_ID);
    assert.equal(tag!.injectTo, 'head-prepend');
    assert.match(tag!.children, /__smSilent/);
  } finally {
    if (saved === undefined) delete process.env[SILENT_ENV];
    else process.env[SILENT_ENV] = saved;
  }
});

// The build the deploy runs (research/B4/deploy/deploy-web.sh: `npm run build -- --outDir ... --emptyOutDir`, without the variable).
test('a normal production build has no silence code', { skip: !existsSync(join(web, 'node_modules/.bin/vite')) && 'Web/node_modules is not installed here; the hosted web job installs it' }, () => {
  const out = mkdtempSync(join(tmpdir(), 'sm-web-prod-'));
  try {
    const env = { ...process.env, VITE_RELAY_ORIGIN: 'https://relay.test' };
    delete env[SILENT_ENV];
    execFileSync(join(web, 'node_modules/.bin/vite'), ['build', '--outDir', out, '--emptyOutDir', '--logLevel', 'warn'], { cwd: web, env, stdio: 'pipe' });
    const built = walk(out).filter((path) => /\.(html|js|mjs)$/.test(path));
    assert.ok(built.some((path) => path.endsWith('index.html')));
    const leaks = built.filter((path) => /__smSilent|sm-e2e-silent/.test(readFileSync(path, 'utf8'))).map((path) => relative(out, path));
    assert.deepEqual(leaks, []);
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});
