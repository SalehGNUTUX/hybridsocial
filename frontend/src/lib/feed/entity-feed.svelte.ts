import type { Post } from '$lib/api/types.js';

/**
 * Reactive state + logic for a paginated, entity-scoped post feed
 * (a profile, group, or page timeline). Extracts the load → dedupe →
 * cursor → paginate dance that those routes each hand-rolled, so it
 * lives in exactly one place.
 *
 * Usage (in a .svelte component):
 *   const feed = createEntityFeed((cursor) => getGroupTimeline(id, cursor ?? undefined));
 *   onMount(() => feed.reset());
 *   <FeedList posts={feed.posts} loading={feed.loading}
 *             hasMore={feed.hasMore} onloadmore={feed.loadMore} />
 *
 * The optimistic mutators (prepend / replaceById / updateById / set)
 * let callers layer composer-driven and streamed updates on top — the
 * profile route uses them for its own posts + DM handling.
 */
export interface EntityFeed {
  readonly posts: Post[];
  readonly loading: boolean;
  readonly hasMore: boolean;
  /** Fetch the first page (clears any existing posts). */
  reset: () => Promise<void>;
  /** Append the next page. No-op while loading or when exhausted. */
  loadMore: () => Promise<void>;
  /** Replace the whole array (e.g. merging pinned posts). */
  set: (posts: Post[]) => void;
  /** Prepend an optimistic post (deduped). */
  prepend: (post: Post) => void;
  /** Swap an optimistic post id for the confirmed post (dedupe-safe). */
  replaceById: (oldId: string, post: Post) => void;
  /** Replace an already-present post in place (edits). */
  updateById: (post: Post) => void;
}

export function createEntityFeed(
  fetchPage: (cursor: string | null) => Promise<Post[]>,
  pageSize = 20,
): EntityFeed {
  let posts = $state<Post[]>([]);
  let loading = $state(false);
  let hasMore = $state(true);
  // Internal only — no reactivity needed, it's read/written inside load().
  let cursor: string | null = null;

  async function load(reset: boolean) {
    // Guard paginated loads against overlap / exhaustion; a reset always
    // proceeds (it re-establishes state from scratch).
    if (!reset && (loading || !hasMore)) return;
    if (reset) {
      posts = [];
      cursor = null;
      hasMore = true;
    }
    loading = true;
    try {
      const items = await fetchPage(cursor);
      if (reset) {
        posts = items;
      } else {
        // The boundary post can repeat across pages — dedupe on append.
        const seen = new Set(posts.map((p) => p.id));
        posts = [...posts, ...items.filter((p) => !seen.has(p.id))];
      }
      // Cursor must be a POST id — reach through a boost entry at the tail
      // so the next page's row-tuple WHERE anchors to a real row.
      const last: any = items.length > 0 ? items[items.length - 1] : null;
      cursor = last?.type === 'boost' ? (last.post?.id ?? null) : (last?.id ?? null);
      hasMore = items.length >= pageSize;
    } catch {
      // Handle silently — leave the existing posts in place.
    } finally {
      loading = false;
    }
  }

  return {
    get posts() {
      return posts;
    },
    get loading() {
      return loading;
    },
    get hasMore() {
      return hasMore;
    },
    reset: () => load(true),
    loadMore: () => load(false),
    set: (v: Post[]) => {
      posts = v;
    },
    prepend: (post: Post) => {
      if (!posts.some((p) => p.id === post.id)) posts = [post, ...posts];
    },
    replaceById: (oldId: string, post: Post) => {
      const realPresent = posts.some((p) => p.id === post.id && p.id !== oldId);
      if (realPresent) posts = posts.filter((p) => p.id !== oldId);
      else posts = posts.map((p) => (p.id === oldId ? post : p));
    },
    updateById: (post: Post) => {
      posts = posts.map((p) => (p.id === post.id ? post : p));
    },
  };
}
