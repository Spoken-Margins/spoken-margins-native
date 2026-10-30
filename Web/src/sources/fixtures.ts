// Test helper: reads the repo's shared contract fixtures in place, so the web app is tested against the same
// captured feeds and search responses as the iPhone app.

import { readFileSync } from 'node:fs';

const fixtureRoot = new URL('../../../Contracts/fixtures/', import.meta.url);

export function readFixture(relativePath: string): string {
  return readFileSync(new URL(relativePath, fixtureRoot), 'utf8');
}

export function feedFixture(name: string): string {
  return readFixture(`feeds/${name}`);
}

/** A `fetch` stand-in that answers from a table of URL to response, and fails like a blocked browser read otherwise. */
export function stubFetch(
  routes: Record<string, { body: string; status?: number; url?: string; headers?: Record<string, string> }>,
  calls: string[] = [],
): (input: string, init?: RequestInit) => Promise<Response> {
  return async (input) => {
    calls.push(input);
    const route = routes[input];
    if (!route) throw new TypeError('Failed to fetch');
    const response = new Response(route.body, { status: route.status ?? 200, headers: route.headers ?? {} });
    if (route.url) Object.defineProperty(response, 'url', { value: route.url });
    return response;
  };
}
