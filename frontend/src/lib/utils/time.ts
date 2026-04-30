const SECOND = 1000;
const MINUTE = 60 * SECOND;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const WEEK = 7 * DAY;
const MONTH = 30 * DAY;
const YEAR = 365 * DAY;

export function relativeTime(dateStr: string): string {
  const date = new Date(dateStr);
  const now = Date.now();
  const diff = now - date.getTime();

  if (diff < MINUTE) return 'now';
  if (diff < HOUR) return `${Math.floor(diff / MINUTE)}m`;
  if (diff < DAY) return `${Math.floor(diff / HOUR)}h`;
  if (diff < WEEK) return `${Math.floor(diff / DAY)}d`;
  if (diff < MONTH) return `${Math.floor(diff / WEEK)}w`;
  if (diff < YEAR) return `${Math.floor(diff / MONTH)}mo`;
  return `${Math.floor(diff / YEAR)}y`;
}

// Future-relative formatter for things like poll deadlines: "in 3h",
// "in 2d". Returns "soon" while still in the same minute (the
// resolution we have on relativeTime), and falls through to the
// past formatter once the moment has passed so callers don't have
// to handle the sign themselves.
export function relativeTimeFuture(dateStr: string): string {
  const date = new Date(dateStr);
  const diff = date.getTime() - Date.now();
  if (diff <= 0) return relativeTime(dateStr);
  if (diff < MINUTE) return 'in <1m';
  if (diff < HOUR) return `in ${Math.floor(diff / MINUTE)}m`;
  if (diff < DAY) return `in ${Math.floor(diff / HOUR)}h`;
  if (diff < WEEK) return `in ${Math.floor(diff / DAY)}d`;
  if (diff < MONTH) return `in ${Math.floor(diff / WEEK)}w`;
  if (diff < YEAR) return `in ${Math.floor(diff / MONTH)}mo`;
  return `in ${Math.floor(diff / YEAR)}y`;
}

export function fullDateTime(dateStr: string): string {
  const date = new Date(dateStr);
  return date.toLocaleString(undefined, {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}
