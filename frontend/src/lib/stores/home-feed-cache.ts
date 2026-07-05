// In-memory snapshot of the home feed for the current session. The
// home page re-mounts whenever the user navigates away and back
// (e.g. opens a post detail). Without this cache, the page clears
// `posts` and re-fetches, so SvelteKit's scroll restoration finds a
// nearly-empty document and can't restore the previous position.
//
// Hydrating from the cache on mount preserves the same DOM heights,
// which lets the browser/SvelteKit restore scroll cleanly. We don't
// persist this — it's session-scoped, dropped on full reload.

import type { Post } from '$lib/api/types.js';

export interface HomeFeedSnapshot {
  posts: Post[];
  cursor: string | null;
  hasMore: boolean;
  tabId: string;
}

let snapshot: HomeFeedSnapshot | null = null;

export function readHomeFeed(): HomeFeedSnapshot | null {
  return snapshot;
}

export function writeHomeFeed(snap: HomeFeedSnapshot): void {
  snapshot = snap;
}

export function clearHomeFeed(): void {
  snapshot = null;
}
