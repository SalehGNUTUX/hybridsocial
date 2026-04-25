<script lang="ts">
  import { onMount } from 'svelte';
  import type { Post } from '$lib/api/types.js';
  import { getHomeTimeline } from '$lib/api/timelines.js';
  import FeedList from '$lib/components/feed/FeedList.svelte';
  import FeedToggle, { type FeedTab } from '$lib/components/feed/FeedToggle.svelte';
  import NewPostsBanner from '$lib/components/feed/NewPostsBanner.svelte';
  import StoriesCarousel from '$lib/components/stories/StoriesCarousel.svelte';
  import {
    queuedCount,
    flushQueue,
    setAtTop,
    connectTimelineStream,
    disconnectTimelineStream,
    maybeTruncate,
  } from '$lib/stores/timeline-stream.js';

  let posts: Post[] = $state([]);
  let loading = $state(true);
  let hasMore = $state(true);
  let cursor: string | null = $state(null);
  let feedType: FeedTab = $state('latest');

  async function loadTimeline(reset = false) {
    if (reset) {
      posts = [];
      cursor = null;
      hasMore = true;
      loading = true;
    }

    try {
      const params: Record<string, string> = {};
      if (cursor) params.max_id = cursor;
      if (feedType === 'foryou') params.algorithm = 'true';
      if (feedType === 'top') params.algorithm = 'trending';

      const result = await getHomeTimeline(params);
      const items: Post[] = Array.isArray(result) ? result : (result as any).data || [];
      if (reset) {
        posts = items;
      } else {
        // Older-posts pagination uses the last visible id as max_id,
        // and some backends (and our fallback paths) include that
        // boundary post in the next page. Without dedup the {#each
        // posts as p (p.id)} block sees the same id twice and Svelte
        // bails with each_key_duplicate. De-dupe by id while
        // preserving the original visible order.
        const seen = new Set(posts.map((p) => p.id));
        const fresh = items.filter((p) => !seen.has(p.id));
        posts = [...posts, ...fresh];
      }
      // Cursor must be a POST id — the chronological backend's
      // row-tuple WHERE looks the cursor up in `posts`, and a feed
      // entry can be either a Post or a Boost. Walking back from
      // the tail until we hit something that is unmistakably a post
      // (or the inner post of a boost entry) keeps the next page
      // anchored to a real row even when the last visible entry is
      // a boost.
      const lastEntry: any =
        items.length > 0 ? items[items.length - 1] : null;
      const lastPostId =
        lastEntry?.type === 'boost'
          ? lastEntry.post?.id ?? null
          : lastEntry?.id ?? null;
      cursor = lastPostId;
      hasMore = items.length >= 20;
    } catch {
      // Handle error silently
    } finally {
      loading = false;
    }
  }

  function handleFeedChange(tab: FeedTab) {
    feedType = tab;
    loadTimeline(true);
  }

  function mergeQueuedPosts() {
    const queued = flushQueue();
    if (queued.length > 0) {
      // Deduplicate
      const existingIds = new Set(posts.map(p => p.id));
      const newPosts = queued.filter(p => !existingIds.has(p.id));
      posts = maybeTruncate([...newPosts, ...posts]);
    }
    scrollToTop();
  }

  // Prefers `document.scrollingElement` which is what the browser
  // actually scrolls; `window.scrollTo` + smooth has shipped off-
  // behaviour in a couple browsers / extension setups. If smooth
  // fails or `prefers-reduced-motion` kicks in, the instant fallback
  // runs so the banner click always ends up at the top.
  function scrollToTop() {
    const el = (document.scrollingElement || document.documentElement) as HTMLElement;
    try {
      el.scrollTo({ top: 0, left: 0, behavior: 'smooth' });
    } catch {
      el.scrollTop = 0;
    }
    // Belt + suspenders: if after 400ms we're still scrolled, force it.
    setTimeout(() => {
      if (el.scrollTop > 0) el.scrollTop = 0;
    }, 400);
  }

  // Auto-merge the queue only on the TRANSITION from scrolled-down
  // to at-top. Watching $queuedCount directly would flush the queue
  // on every count tick as long as the user is at top, which would
  // swallow a pill that briefly appears mid-post (e.g., if optimistic
  // insert + scroll anchor briefly puts the viewport at scrollY=0
  // during a post). Transition-only keeps the pill's counter behaviour
  // sane while still dismissing it when the user scrolls back up.
  let atTopState = $state(true);
  let prevAtTop = true;
  function handleScroll() {
    atTopState = window.scrollY < 50;
    setAtTop(atTopState);
    if (atTopState && !prevAtTop) {
      mergeQueuedPosts();
    }
    prevAtTop = atTopState;
  }

  onMount(() => {
    loadTimeline(true);

    // Connect streaming (auth via httpOnly cookie)
    const apiBase = import.meta.env.VITE_API_URL || '';
    connectTimelineStream(apiBase);

    // Listen for real-time updates when at top
    function handleTimelineUpdate(e: Event) {
      const post = (e as CustomEvent<Post>).detail;
      if (post && !posts.some(p => p.id === post.id)) {
        posts = maybeTruncate([post, ...posts]);
      }
    }

    // Listen for status edits
    function handleStatusUpdate(e: Event) {
      const updated = (e as CustomEvent<Post>).detail;
      if (updated) {
        posts = posts.map(p => p.id === updated.id ? updated : p);
      }
    }

    // Listen for new posts from the composer
    function handleNewPost(e: Event) {
      const newPost = (e as CustomEvent).detail;
      if (!newPost || newPost.parent_id) return;
      // Dedup — the streaming broadcast now includes the author's
      // own posts, so if the server round-trip is fast enough we
      // could end up with the real post landing before the optimistic
      // one is placed. Don't insert twice.
      if (posts.some((p) => p.id === newPost.id)) return;
      posts = [newPost, ...posts];
    }

    // Replace optimistic post with real server response.
    //
    // The streaming broadcast can arrive BEFORE this event for local
    // posts — the backend fans out to the author's user:<id> topic
    // as soon as the insert hooks run. If the real post is already in
    // the array under its real id, naively `map`-ing optimistic → real
    // creates a duplicate key and Svelte's {#each .. (post.id)}
    // errors with `each_key_duplicate`. Detect the collision and drop
    // the optimistic entry instead.
    function handlePostReplace(e: Event) {
      const { oldId, post } = (e as CustomEvent).detail;
      if (!oldId || !post) return;

      const realAlreadyPresent = posts.some((p) => p.id === post.id && p.id !== oldId);
      if (realAlreadyPresent) {
        posts = posts.filter((p) => p.id !== oldId);
      } else {
        posts = posts.map((p) => (p.id === oldId ? post : p));
      }
    }

    window.addEventListener('scroll', handleScroll, { passive: true });
    window.addEventListener('timeline-update', handleTimelineUpdate);
    window.addEventListener('timeline-status-update', handleStatusUpdate);
    window.addEventListener('new-post', handleNewPost);
    window.addEventListener('post-replace', handlePostReplace);

    // Seed at-top state. Without this, the module-level `isAtTop`
    // defaults to `true` even when the page loads already scrolled
    // down (e.g. scroll restoration after a client-side nav), which
    // routes every stream event to the in-feed path instead of the
    // "N new posts" queue until the user happens to scroll.
    handleScroll();

    return () => {
      disconnectTimelineStream();
      window.removeEventListener('scroll', handleScroll);
      window.removeEventListener('timeline-update', handleTimelineUpdate);
      window.removeEventListener('timeline-status-update', handleStatusUpdate);
      window.removeEventListener('new-post', handleNewPost);
      window.removeEventListener('post-replace', handlePostReplace);
    };
  });
</script>

<svelte:head>
  <title>Home - HybridSocial</title>
</svelte:head>

<div class="home-page">
  <StoriesCarousel />

  <!-- Sticky feed-type tabs. Keeping them pinned so a user scrolling
       deep into "Latest" can switch to "For You" / "Top" without
       scrolling back to the top of the viewport. The `background`
       + slight blur makes the list behind it fade instead of
       showing through distractingly. -->
  <div class="home-sticky-bar">
    <FeedToggle active={feedType} onchange={handleFeedChange} />
  </div>

  <!-- Floater renders itself position:fixed so it sits at the top
       of the viewport regardless of scroll position. Outside the
       sticky bar so it can't be clipped by overflow rules. -->
  <NewPostsBanner count={$queuedCount} onclick={mergeQueuedPosts} />

  <FeedList
    {posts}
    {loading}
    {hasMore}
    onloadmore={() => loadTimeline(false)}
    emptyMessage="Your timeline is empty. Follow some people to see their posts here."
  />
</div>

<style>
  .home-page {
    max-width: var(--feed-max-width);
    margin: 0 auto;
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }

  .home-sticky-bar {
    position: sticky;
    /* Header is pinned at 0 with height --header-height. Stick the
       tabs right under it so they hug the bottom edge of the
       header as the user scrolls. */
    inset-block-start: var(--header-height);
    z-index: 20;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    /* Translucent surface + blur so the posts scrolling under the
       bar look dimmed rather than obscured by a hard edge. */
    background: color-mix(in oklab, var(--color-surface-base, #fff) 85%, transparent);
    backdrop-filter: saturate(1.4) blur(10px);
    -webkit-backdrop-filter: saturate(1.4) blur(10px);
    padding: var(--space-3) 0;
    margin-inline: calc(-1 * var(--space-2));
    padding-inline: var(--space-2);
  }

</style>
