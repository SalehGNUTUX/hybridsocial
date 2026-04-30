import { writable, get } from 'svelte/store';

// Tracks which PostCard the keyboard cursor is currently on. The home
// feed and other FeedList consumers register their visible posts via
// `setFeedPosts` so j/k can walk an ordered list independent of DOM
// iteration. When no card is focused, j picks the first visible one.
export const focusedPostId = writable<string | null>(null);

// Ordered list of post ids currently rendered in the active feed.
// FeedList overwrites this on every render; navigating away from a
// feed (route change, FeedList unmount) clears it via `clearFeedPosts`.
const feedPosts = writable<string[]>([]);

export function setFeedPosts(ids: string[]): void {
  feedPosts.set(ids);
}

export function clearFeedPosts(): void {
  feedPosts.set([]);
  focusedPostId.set(null);
}

export function focusPost(id: string | null): void {
  focusedPostId.set(id);
  if (id) scrollPostIntoView(id);
}

export function focusNextPost(): void {
  const ids = get(feedPosts);
  if (ids.length === 0) return;
  const current = get(focusedPostId);
  if (!current) {
    focusPost(firstVisibleId(ids) ?? ids[0]);
    return;
  }
  const idx = ids.indexOf(current);
  if (idx === -1 || idx === ids.length - 1) return;
  focusPost(ids[idx + 1]);
}

export function focusPrevPost(): void {
  const ids = get(feedPosts);
  if (ids.length === 0) return;
  const current = get(focusedPostId);
  if (!current) {
    focusPost(firstVisibleId(ids) ?? ids[0]);
    return;
  }
  const idx = ids.indexOf(current);
  if (idx <= 0) return;
  focusPost(ids[idx - 1]);
}

function firstVisibleId(ids: string[]): string | null {
  for (const id of ids) {
    const el = document.querySelector<HTMLElement>(`[data-post-anchor="${cssEscape(id)}"]`);
    if (!el) continue;
    const rect = el.getBoundingClientRect();
    if (rect.bottom > 0 && rect.top < window.innerHeight) return id;
  }
  return ids[0] ?? null;
}

function scrollPostIntoView(id: string): void {
  // Defer to next frame so a card that just rendered (e.g. after
  // route change) has a chance to mount before we measure it.
  requestAnimationFrame(() => {
    const el = document.querySelector<HTMLElement>(`[data-post-anchor="${cssEscape(id)}"]`);
    if (!el) return;
    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
  });
}

function cssEscape(s: string): string {
  return typeof CSS !== 'undefined' && CSS.escape ? CSS.escape(s) : s.replace(/"/g, '\\"');
}
