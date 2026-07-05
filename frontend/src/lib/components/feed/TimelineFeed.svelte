<script lang="ts" module>
  import type { Post } from '$lib/api/types.js';

  export interface TimelineTab {
    id: string;
    label: string;
    /** Optional Material Symbols glyph shown in the tab. */
    icon?: string;
    /** Fetch a page of entries for the given cursor (null = first page). */
    load: (cursor: string | null) => Promise<Post[]>;
    /**
     * Live-stream wiring for this tab, or null for no streaming (e.g.
     * algorithmic feeds where a brand-new post shouldn't jump in).
     */
    stream?: { kind: 'home' | 'public'; filter?: (p: Post) => boolean } | null;
    /**
     * Whether an optimistic new post (from the composer) belongs on this
     * tab. Defaults to yes. Used e.g. to keep local-only posts off the
     * Global tab and everything off Trending.
     */
    accepts?: (p: Post) => boolean;
    emptyMessage: string;
  }

  export interface TimelineSnapshot {
    posts: Post[];
    cursor: string | null;
    hasMore: boolean;
    tabId: string;
  }

  /**
   * Optional session cache for scroll restoration. The home feed provides
   * one so a back-nav from a post detail lands on the same posts in the
   * same DOM positions; explore doesn't need it.
   */
  export interface TimelineCache {
    read: () => TimelineSnapshot | null;
    write: (snap: TimelineSnapshot) => void;
  }
</script>

<script lang="ts">
  import { onMount } from 'svelte';
  import FeedList from './FeedList.svelte';
  import FeedTabs from './FeedTabs.svelte';
  import NewPostsBanner from './NewPostsBanner.svelte';
  import {
    queuedCount,
    flushQueue,
    setAtTop,
    connectStream,
    disconnectStream,
    maybeTruncate,
  } from '$lib/stores/timeline-stream.js';

  let {
    tabs,
    filterContext = 'home',
    cache = null,
  }: {
    tabs: TimelineTab[];
    filterContext?: string;
    cache?: TimelineCache | null;
  } = $props();

  // Hydrate synchronously from the cache (if any) so the DOM keeps its
  // heights for scroll restoration and we can skip the initial fetch.
  const cached = cache?.read() ?? null;
  let posts: Post[] = $state(cached?.posts ?? []);
  let loading = $state(cached === null);
  let hasMore = $state(cached?.hasMore ?? true);
  let cursor: string | null = $state(cached?.cursor ?? null);
  let activeId = $state<string>(cached?.tabId ?? tabs[0]?.id);

  let activeTab = $derived(tabs.find((t) => t.id === activeId) ?? tabs[0]);

  function persist() {
    cache?.write({ posts, cursor, hasMore, tabId: activeId });
  }

  async function loadFeed(reset = false) {
    if (reset) {
      posts = [];
      cursor = null;
      hasMore = true;
    }
    loading = true;
    try {
      const items = await activeTab.load(cursor);
      if (reset) {
        posts = items;
      } else {
        // Dedupe on append — the boundary post can repeat across pages.
        const seen = new Set(posts.map((p) => p.id));
        posts = [...posts, ...items.filter((p) => !seen.has(p.id))];
      }
      // Cursor must be a POST id — reach through a boost entry at the
      // tail so the next page's row-tuple WHERE anchors to a real row.
      const last: any = items.length > 0 ? items[items.length - 1] : null;
      cursor = last?.type === 'boost' ? (last.post?.id ?? null) : (last?.id ?? null);
      hasMore = items.length >= 20;
      persist();
    } catch {
      // Handle silently
    } finally {
      loading = false;
    }
  }

  function switchTab(id: string) {
    if (id === activeId) return;
    activeId = id;
    loadFeed(true);
    wireStream();
  }

  function wireStream() {
    const apiBase = import.meta.env.VITE_API_URL || '';
    const s = activeTab.stream;
    if (!s) {
      disconnectStream();
      return;
    }
    connectStream(s.kind, apiBase, s.filter ? { filter: s.filter } : {});
  }

  function mergeQueued() {
    const queued = flushQueue();
    if (queued.length > 0) {
      const existing = new Set(posts.map((p) => p.id));
      const fresh = queued.filter((p) => !existing.has(p.id));
      posts = maybeTruncate([...fresh, ...posts]);
      persist();
    }
    scrollToTop();
  }

  function scrollToTop() {
    const el = (document.scrollingElement || document.documentElement) as HTMLElement;
    try {
      el.scrollTo({ top: 0, left: 0, behavior: 'smooth' });
    } catch {
      el.scrollTop = 0;
    }
    // Belt + suspenders: force it if smooth scroll stalled.
    setTimeout(() => {
      if (el.scrollTop > 0) el.scrollTop = 0;
    }, 400);
  }

  // Auto-merge the queue only on the transition from scrolled-down → at
  // top (not on every count tick — see the note this replaced).
  let prevAtTop = true;
  function handleScroll() {
    const atTop = window.scrollY < 50;
    setAtTop(atTop);
    if (atTop && !prevAtTop) mergeQueued();
    prevAtTop = atTop;
  }

  // Optimistic post from the composer. `accepts` gates which tab it
  // belongs on (e.g. local-only, or never on Trending).
  function handleNewPost(e: Event) {
    const p = (e as CustomEvent<Post>).detail;
    if (!p || p.parent_id) return;
    if (activeTab.accepts && !activeTab.accepts(p)) return;
    if (posts.some((x) => x.id === p.id)) return;
    posts = [p, ...posts];
    persist();
  }

  // Swap an optimistic post for the real server response. Guard against
  // the stream broadcast arriving first (real post already present).
  function handlePostReplace(e: Event) {
    const { oldId, post } = (e as CustomEvent<{ oldId: string; post: Post }>).detail;
    if (!oldId || !post) return;
    const realPresent = posts.some((p) => p.id === post.id && p.id !== oldId);
    if (realPresent) posts = posts.filter((p) => p.id !== oldId);
    else posts = posts.map((p) => (p.id === oldId ? post : p));
    persist();
  }

  // Live post from the stream (already audience-filtered by the store).
  function handleTimelineUpdate(e: Event) {
    const post = (e as CustomEvent<Post>).detail;
    if (!post || post.parent_id) return;
    if (posts.some((p) => p.id === post.id)) return;
    posts = maybeTruncate([post, ...posts]);
    persist();
  }

  // In-place edit of an already-visible post.
  function handleStatusUpdate(e: Event) {
    const updated = (e as CustomEvent<Post>).detail;
    if (!updated) return;
    posts = posts.map((p) => (p.id === updated.id ? updated : p));
    persist();
  }

  onMount(() => {
    // Skip the initial fetch when hydrated from cache — refetching would
    // wipe the posts and break scroll restoration.
    if (cached === null) loadFeed(true);
    wireStream();

    window.addEventListener('scroll', handleScroll, { passive: true });
    window.addEventListener('new-post', handleNewPost);
    window.addEventListener('post-replace', handlePostReplace);
    window.addEventListener('timeline-update', handleTimelineUpdate);
    window.addEventListener('timeline-status-update', handleStatusUpdate);

    // Seed at-top state so early stream events route correctly even when
    // the page loads already scrolled (scroll restoration).
    handleScroll();

    return () => {
      disconnectStream();
      window.removeEventListener('scroll', handleScroll);
      window.removeEventListener('new-post', handleNewPost);
      window.removeEventListener('post-replace', handlePostReplace);
      window.removeEventListener('timeline-update', handleTimelineUpdate);
      window.removeEventListener('timeline-status-update', handleStatusUpdate);
    };
  });
</script>

<div class="timeline-feed">
  {#if tabs.length > 1}
    <!-- Sticky feed switcher: pinned under the header so switching feeds
         deep in a long timeline doesn't force a scroll to top. -->
    <div class="timeline-sticky-bar">
      <FeedTabs {tabs} active={activeId} onchange={switchTab} />
    </div>
  {/if}

  {#if activeTab?.stream}
    <NewPostsBanner count={$queuedCount} onclick={mergeQueued} />
  {/if}

  <FeedList
    {posts}
    {loading}
    {hasMore}
    onloadmore={() => loadFeed(false)}
    emptyMessage={activeTab?.emptyMessage ?? 'Nothing here yet'}
    {filterContext}
  />
</div>

<style>
  .timeline-feed {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }

  .timeline-sticky-bar {
    position: sticky;
    inset-block-start: var(--header-height);
    z-index: 20;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    /* Translucent + blur so posts scrolling under the bar fade rather
       than being hard-clipped. */
    background: color-mix(in oklab, var(--color-surface-base, #fff) 85%, transparent);
    backdrop-filter: saturate(1.4) blur(10px);
    -webkit-backdrop-filter: saturate(1.4) blur(10px);
    padding: var(--space-3) 0;
    margin-inline: calc(-1 * var(--space-2));
    padding-inline: var(--space-2);
  }
</style>
