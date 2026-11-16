// What a search box on the web matches (#4422). The iPhone app's Library folds case and accents on each field and asks
// whether any contains the whole trimmed query (`LibraryQueryEngine.visibleLibraryItems`); this does the same, plus the
// fold that makes full-width letters match plain ones, so the two stay consistent (#4018). Plain TypeScript with no DOM,
// so `npm run test:web` covers it (search.test.ts).

/** Case, accents and width folded away, runs of white space made one space, ends trimmed. */
export function foldForSearch(text: string): string {
  return text
    .normalize('NFKD')
    .replace(/\p{M}+/gu, '')
    .toLowerCase()
    .replace(/\s+/gu, ' ')
    .trim();
}

/** Whether the query is in any of the fields. An empty (or blank) query matches everything. */
export function matchesSearch(query: string, fields: readonly (string | undefined)[]): boolean {
  const wanted = foldForSearch(query);
  if (wanted === '') return true;
  return fields.some((field) => field !== undefined && foldForSearch(field).includes(wanted));
}
