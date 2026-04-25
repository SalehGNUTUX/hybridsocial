<script lang="ts">
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import type { Post, Identity, TrendingTag } from '$lib/api/types.js';
  import { search } from '$lib/api/search.js';
  import { getTrending } from '$lib/api/instance.js';
  import { getPublicTimeline } from '$lib/api/timelines.js';
  import { api } from '$lib/api/client.js';
  import Tabs from '$lib/components/ui/Tabs.svelte';
  import FeedList from '$lib/components/feed/FeedList.svelte';
  import Avatar from '$lib/components/ui/Avatar.svelte';
  import Skeleton from '$lib/components/ui/Skeleton.svelte';
  import NewPostsBanner from '$lib/components/feed/NewPostsBanner.svelte';
  import {
    queuedCount,
    flushQueue,
    setAtTop,
    connectStream,
    disconnectStream,
    maybeTruncate,
  } from '$lib/stores/timeline-stream.js';

  type ExploreTab = 'local' | 'global' | 'trending';

  let query = $state('');
  let exploreTab = $state<ExploreTab>('local');
  let searchTab = $state('posts');
  let searching = $state(false);
  let hasSearched = $state(false);

  // Search results
  let searchPosts: Post[] = $state([]);
  let searchAccounts: Identity[] = $state([]);
  let searchHashtags: TrendingTag[] = $state([]);

  // Feed state per tab
  let feedPosts: Post[] = $state([]);
  let feedLoading = $state(true);
  let feedHasMore = $state(true);
  let feedCursor: string | null = $state(null);

  const searchTabs = [
    { id: 'posts', label: 'Posts' },
    { id: 'accounts', label: 'Accounts' },
    { id: 'hashtags', label: 'Hashtags' },
  ];

  async function handleSearch() {
    const q = query.trim();
    if (!q) {
      hasSearched = false;
      return;
    }

    searching = true;
    hasSearched = true;
    try {
      const results = await search(q, { resolve: true });
      searchPosts = results.posts || (results as any).statuses || [];
      searchAccounts = results.accounts || [];
      searchHashtags = results.hashtags || [];

      if (searchAccounts.length > 0 && searchPosts.length === 0) {
        searchTab = 'accounts';
      } else if (searchHashtags.length > 0 && searchPosts.length === 0 && searchAccounts.length === 0) {
        searchTab = 'hashtags';
      } else {
        searchTab = 'posts';
      }
    } catch {
      // Handle silently
    } finally {
      searching = false;
    }
  }

  async function loadFeed(reset = false) {
    if (reset) {
      feedPosts = [];
      feedCursor = null;
      feedHasMore = true;
    }
    feedLoading = true;
    try {
      const params: Record<string, string> = {};
      if (feedCursor) params.max_id = feedCursor;

      let endpoint: string;
      if (exploreTab === 'local') {
        endpoint = '/api/v1/timelines/public?local=true';
      } else if (exploreTab === 'global') {
        endpoint = '/api/v1/timelines/global';
      } else {
        endpoint = '/api/v1/timelines/public?algorithm=trending';
      }

      if (feedCursor) endpoint += (endpoint.includes('?') ? '&' : '?') + `max_id=${feedCursor}`;

      const items: Post[] = await api.get(endpoint);
      const result = Array.isArray(items) ? items : [];

      if (reset) {
        feedPosts = result;
      } else {
        const seen = new Set(feedPosts.map((p) => p.id));
        feedPosts = [...feedPosts, ...result.filter((p) => !seen.has(p.id))];
      }
      // Same boost-vs-post cursor-id concern as the home feed: the
      // backend's row-tuple WHERE expects a posts.id, but feed
      // entries can be boosts. Reach through to the inner post id
      // when the tail entry is a boost.
      const lastEntry: any =
        result.length > 0 ? result[result.length - 1] : null;
      feedCursor =
        lastEntry?.type === 'boost'
          ? lastEntry.post?.id ?? null
          : lastEntry?.id ?? null;
      feedHasMore = result.length >= 20;
    } catch {
      // Handle silently
    } finally {
      feedLoading = false;
    }
  }

  function switchTab(tab: ExploreTab) {
    if (tab !== exploreTab) {
      exploreTab = tab;
      loadFeed(true);
      wireStreamForTab();
    }
  }

  // The public stream includes both local and federated posts. When
  // the Local tab is active we want to drop remote authors; on
  // Global we want everything; on Trending we don't stream at all
  // (algorithmic feed — a fresh post shouldn't jump onto the trending
  // list just because it was published).
  function wireStreamForTab() {
    const apiBase = import.meta.env.VITE_API_URL || '';
    if (exploreTab === 'trending') {
      disconnectStream();
      return;
    }

    const filter =
      exploreTab === 'local'
        ? (p: Post) => {
            const acct = (p.account as any)?.acct ?? '';
            return !acct.includes('@');
          }
        : undefined;

    connectStream('public', apiBase, { filter });
  }

  function mergeQueuedPosts() {
    const queued = flushQueue();
    if (queued.length > 0) {
      const existingIds = new Set(feedPosts.map((p) => p.id));
      const fresh = queued.filter((p) => !existingIds.has(p.id));
      feedPosts = maybeTruncate([...fresh, ...feedPosts]);
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
    setTimeout(() => {
      if (el.scrollTop > 0) el.scrollTop = 0;
    }, 400);
  }

  // Auto-merge only on transition from scrolled-down → at-top. See
  // the home page for why this isn't a plain `$effect` on count.
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

  // Mirror the home-timeline / profile-page pattern so submitting a
  // post appears on the Local/Global tab immediately (as a washed-out
  // optimistic card) and swaps to the real server post on confirm —
  // no refresh needed.
  function handleNewPost(e: Event) {
    const newPost = (e as CustomEvent<Post>).detail;
    if (!newPost) return;

    // Replies never belong on Explore — those are thread-scoped.
    if (newPost.parent_id) return;

    // Local tab: only show posts authored on this instance (remote
    // federated posts land on Global, not Local).
    if (exploreTab === 'local') {
      const host = typeof window !== 'undefined' ? window.location.host : '';
      const authorAcct = (newPost.account as any)?.acct ?? '';
      const isLocal = !authorAcct.includes('@');
      const authorHost = (newPost.account as any)?.url
        ? new URL((newPost.account as any).url).host
        : host;
      if (!isLocal && authorHost !== host) return;
    }

    // Trending is algorithmic — a brand-new post doesn't belong on
    // it until the algorithm picks it up later.
    if (exploreTab === 'trending') return;

    if (feedPosts.some((p) => p.id === newPost.id)) return;
    feedPosts = [newPost, ...feedPosts];
  }

  function handlePostReplace(e: Event) {
    const { oldId, post } = (e as CustomEvent<{ oldId: string; post: Post }>).detail;
    if (!oldId || !post) return;

    // Guard against the streaming broadcast arriving before the
    // composer's optimistic-replace — if the real post is already in
    // the feed under its real id, naively mapping oldId → post
    // duplicates keys and crashes the {#each}. Drop the optimistic
    // entry instead.
    const realAlreadyPresent = feedPosts.some((p) => p.id === post.id && p.id !== oldId);
    if (realAlreadyPresent) {
      feedPosts = feedPosts.filter((p) => p.id !== oldId);
      return;
    }

    feedPosts = feedPosts.map((p) => (p.id === oldId ? post : p));
  }

  function handleTimelineUpdate(e: Event) {
    const post = (e as CustomEvent<Post>).detail;
    if (!post) return;
    // Live updates only replace the top of the feed when the user
    // is actually at the top. The filter in the stream module
    // already discarded remote posts on the Local tab.
    if (post.parent_id) return;
    if (feedPosts.some((p) => p.id === post.id)) return;
    feedPosts = maybeTruncate([post, ...feedPosts]);
  }

  onMount(() => {
    loadFeed(true);
    wireStreamForTab();
    window.addEventListener('new-post', handleNewPost);
    window.addEventListener('post-replace', handlePostReplace);
    window.addEventListener('timeline-update', handleTimelineUpdate);
    window.addEventListener('scroll', handleScroll, { passive: true });
    handleScroll();
    return () => {
      disconnectStream();
      window.removeEventListener('new-post', handleNewPost);
      window.removeEventListener('post-replace', handlePostReplace);
      window.removeEventListener('timeline-update', handleTimelineUpdate);
      window.removeEventListener('scroll', handleScroll);
    };
  });

  // React to URL query param changes
  let lastUrlQuery = '';

  $effect(() => {
    const urlQuery = page.url.searchParams.get('q') || '';
    if (urlQuery && urlQuery !== lastUrlQuery) {
      lastUrlQuery = urlQuery;
      query = urlQuery;
      handleSearch();
    }
  });
</script>

<svelte:head>
  <title>Explore - HybridSocial</title>
</svelte:head>

<div class="explore-page">
  {#if hasSearched}
    <Tabs tabs={searchTabs} bind:active={searchTab}>
      {#if searching}
        <div class="search-loading">
          <div class="search-spinner">
            <svg class="spinner-svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="var(--color-primary)" stroke-width="2.5">
              <circle cx="12" cy="12" r="10" stroke-opacity="0.2" />
              <path d="M12 2a10 10 0 0 1 10 10" stroke-linecap="round" />
            </svg>
            <span>Searching...</span>
          </div>
          <div class="search-skeleton">
            <Skeleton width="100%" height="56px" />
            <Skeleton width="100%" height="56px" />
            <Skeleton width="100%" height="56px" />
          </div>
        </div>
      {:else if searchTab === 'posts'}
        {#if searchPosts.length === 0}
          <div class="empty-results">
            <p>No posts found for "{query}"</p>
          </div>
        {:else}
          <FeedList posts={searchPosts} loading={false} hasMore={false} filterContext="public" />
        {/if}
      {:else if searchTab === 'accounts'}
        {#if searchAccounts.length === 0}
          <div class="empty-results">
            <p>No accounts found for "{query}"</p>
          </div>
        {:else}
          <div class="accounts-list">
            {#each searchAccounts as account (account.id)}
              <a href="/{account.acct || account.handle}" class="account-item">
                <Avatar src={account.avatar_url} name={account.display_name || account.acct || account.handle} size="md" />
                <div class="account-info">
                  <span class="account-name">{account.display_name || account.acct || account.handle}</span>
                  <span class="account-handle">@{account.acct || account.handle}</span>
                  {#if account.bio}
                    <p class="account-bio">{@html account.bio}</p>
                  {/if}
                </div>
              </a>
            {/each}
          </div>
        {/if}
      {:else if searchTab === 'hashtags'}
        {#if searchHashtags.length === 0}
          <div class="empty-results">
            <p>No hashtags found for "{query}"</p>
          </div>
        {:else}
          <div class="hashtags-list">
            {#each searchHashtags as tag (tag.name)}
              <a href="/tags/{tag.name}" class="hashtag-item">
                <span class="hashtag-name">#{tag.name}</span>
                {#if (tag.history || []).length > 0}
                  <span class="hashtag-count">{(tag.history || [])[0].uses} posts today</span>
                {/if}
              </a>
            {/each}
          </div>
        {/if}
      {/if}
    </Tabs>
  {:else}
    <!-- Explore tabs: Local / Global / Trending. Sticky so users
         deep-scrolling a long timeline can switch feeds without
         scrolling back up. -->
    <div class="explore-tabs explore-tabs-sticky" role="tablist" aria-label="Explore feeds">
      <button
        type="button"
        role="tab"
        class="explore-tab"
        class:explore-tab-active={exploreTab === 'local'}
        aria-selected={exploreTab === 'local'}
        onclick={() => switchTab('local')}
      >
        <span class="material-symbols-outlined tab-icon">home</span>
        Local
      </button>
      <button
        type="button"
        role="tab"
        class="explore-tab"
        class:explore-tab-active={exploreTab === 'global'}
        aria-selected={exploreTab === 'global'}
        onclick={() => switchTab('global')}
      >
        <span class="material-symbols-outlined tab-icon">public</span>
        Global
      </button>
      <button
        type="button"
        role="tab"
        class="explore-tab"
        class:explore-tab-active={exploreTab === 'trending'}
        aria-selected={exploreTab === 'trending'}
        onclick={() => switchTab('trending')}
      >
        <span class="material-symbols-outlined tab-icon">trending_up</span>
        Trending
      </button>
    </div>

    {#if exploreTab !== 'trending'}
      <NewPostsBanner count={$queuedCount} onclick={mergeQueuedPosts} />
    {/if}

    <FeedList
      posts={feedPosts}
      loading={feedLoading}
      hasMore={feedHasMore}
      onloadmore={() => loadFeed(false)}
      emptyMessage={exploreTab === 'local' ? 'No local posts yet' : exploreTab === 'global' ? 'No posts from the fediverse yet' : 'Nothing trending right now'}
      filterContext="public"
    />
  {/if}
</div>

<style>
  .explore-page {
    max-width: var(--feed-max-width);
    margin: 0 auto;
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }

  .search-loading {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }

  .search-spinner {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: var(--space-2);
    padding: var(--space-4);
    font-size: var(--text-sm);
    color: var(--color-primary);
    font-weight: 500;
  }

  .spinner-svg {
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .search-skeleton {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
    opacity: 0.5;
  }

  .empty-results {
    text-align: center;
    padding: var(--space-12);
    color: var(--color-text-tertiary);
    font-size: var(--text-sm);
  }

  /* Account results */
  .accounts-list {
    display: flex;
    flex-direction: column;
  }

  .account-item {
    display: flex;
    gap: var(--space-3);
    padding: var(--space-3) var(--space-4);
    border-radius: var(--radius-lg);
    text-decoration: none;
    transition: background var(--transition-fast);
  }

  .account-item:hover {
    background: var(--color-surface);
    text-decoration: none;
  }

  .account-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .account-name {
    font-size: var(--text-sm);
    font-weight: 600;
    color: var(--color-text);
  }

  .account-handle {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
  }

  .account-bio {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    margin-block-start: var(--space-1);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* Hashtag results */
  .hashtags-list {
    display: flex;
    flex-direction: column;
  }

  .hashtag-item {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: var(--space-3) var(--space-4);
    border-radius: var(--radius-lg);
    text-decoration: none;
    transition: background var(--transition-fast);
  }

  .hashtag-item:hover {
    background: var(--color-surface);
    text-decoration: none;
  }

  .hashtag-name {
    font-size: var(--text-sm);
    font-weight: 600;
    color: var(--color-primary);
  }

  .hashtag-count {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
  }

  /* Explore tabs */
  .explore-tabs {
    display: flex;
    gap: 2px;
    background: var(--color-surface-container-lowest);
    border: 1px solid var(--color-border);
    border-radius: 14px;
    padding: 3px;
  }

  /* Pin the Local / Global / Trending switcher under the site
     header so tab changes don't force a scroll-to-top. Slight
     blur + translucent fill so the posts scrolling underneath
     fade out visually instead of being abruptly hidden. Inset
     margin keeps the sticky element inside the same horizontal
     gutters as the page body. */
  .explore-tabs-sticky {
    position: sticky;
    inset-block-start: var(--header-height);
    z-index: 20;
    background: color-mix(in oklab, var(--color-surface-container-lowest) 85%, transparent);
    backdrop-filter: saturate(1.4) blur(10px);
    -webkit-backdrop-filter: saturate(1.4) blur(10px);
  }

  .explore-tab {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    padding: 8px 12px;
    background: transparent;
    border: none;
    border-radius: 11px;
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--color-text-secondary);
    cursor: pointer;
    transition: all 150ms ease;
  }

  .explore-tab:hover {
    color: var(--color-text);
    background: var(--color-surface);
  }

  .explore-tab-active {
    background: var(--color-primary);
    color: var(--color-on-primary);
  }

  .explore-tab-active:hover {
    background: var(--color-primary);
    color: var(--color-on-primary);
  }

  .tab-icon {
    font-size: 18px;
  }
</style>
