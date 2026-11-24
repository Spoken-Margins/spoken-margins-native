// Whether an opened link is an introduction link (#4784, Design 2026-11-21, slice 1). The mark is `answers: "none"` in the
// link's sealed preview, put there by `make-share-link --intro`. It is a decision on what the page shows, never a
// permission: an unknown value, a wrong type, or a preview that can't be read all count as no mark, so the page shows
// today's words for a conversation link. The mark is never written into a packet. Plain TypeScript with no DOM.

/** True only for a preview whose `answers` is exactly the string `"none"`. */
export function isIntroPreview(preview: unknown): boolean {
  return typeof preview === 'object' && preview !== null && !Array.isArray(preview)
    && (preview as { answers?: unknown }).answers === 'none';
}
