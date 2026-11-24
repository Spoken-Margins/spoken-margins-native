// When a feed read may go through our server, and what the consent pop-up says (#2977, #4176).
//
// The owner's call on #4176 (2026-11-21, recorded in docs/decisions.md): a listener's own private feed link (a Patreon
// or Supercast RSS link, or one with a token in it) may go through the relay, and the consent step names it. So a
// private-looking link never goes through the server silently, even when the relay is already on: the browser tries it
// directly, and only if that is blocked does the pop-up ask, with the private line. Plain TypeScript, so
// `npm run test:web` covers every row (relay-consent.test.ts).
import { shareableLink } from '../../packet/links.ts';

export interface RelaySettings {
  relayAllowed: boolean;
  relayAsked: boolean;
}

/** The extra line the consent pop-up shows for a private-looking link (#4176 Design, option B). */
export const RELAY_PRIVATE_LINE = 'This link looks private. Reading it through our server sends the link to us; we keep nothing.';

/**
 * True for an http(s) link that may hold an access secret: the same test that keeps a link out of a packet
 * (`shareableLink`, a port of the app's ShareableLinkPolicy). Anything that isn't an http(s) link is not a feed link.
 */
export function looksPrivateFeedLink(url: string): boolean {
  if (!/^https?:\/\//i.test(url.trim())) return false;
  return shareableLink(url.trim()) === undefined;
}

/** Whether the first read may use the server without asking. Never for a private-looking link. */
export function relayOnFirstRead(settings: RelaySettings, privateLink: boolean): boolean {
  return settings.relayAllowed && !privateLink;
}

/**
 * What to do when the browser couldn't read the feed: `off` when the listener switched the server off (in Settings or
 * with an earlier "Not now"), else `ask`. A private link with the server on is asked about, with the private line.
 */
export function whenBlocked(settings: RelaySettings): 'off' | 'ask' {
  return settings.relayAsked && !settings.relayAllowed ? 'off' : 'ask';
}

/**
 * The settings to save after the pop-up's answer. The first answer is remembered, as before. When the server was
 * already on, the question was only about this private link: neither answer changes the setting, so "Not now" on one
 * Patreon link doesn't switch the server off for every other feed.
 */
export function settingsAfterAnswer(settings: RelaySettings, yes: boolean): Partial<RelaySettings> {
  if (settings.relayAllowed) return {};
  return { relayAsked: true, relayAllowed: yes };
}
