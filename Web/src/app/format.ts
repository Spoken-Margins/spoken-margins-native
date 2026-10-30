// Dates and durations the way the screens show them.
export function shortDate(iso: string | undefined): string {
  if (!iso) return '';
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  const sameYear = date.getFullYear() === new Date().getFullYear();
  return date.toLocaleDateString(undefined, sameYear ? { month: 'short', day: 'numeric' } : { month: 'short', day: 'numeric', year: 'numeric' });
}

export function minutes(seconds: number | undefined): string {
  if (!seconds || !Number.isFinite(seconds)) return '';
  const m = Math.round(seconds / 60);
  if (m < 60) return `${Math.max(1, m)} min`;
  return `${Math.floor(m / 60)} h ${m % 60} min`;
}

export function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
