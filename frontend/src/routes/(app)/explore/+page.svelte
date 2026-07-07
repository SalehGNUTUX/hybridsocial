<script lang="ts">
  import { page } from '$app/state';
  import type { Post, Identity, TrendingTag } from '$lib/api/types.js';
  import { search } from '$lib/api/search.js';
  import { api } from '$lib/api/client.js';
  import Tabs from '$lib/components/ui/Tabs.svelte';
  import DisplayName from '$lib/components/DisplayName.svelte';
  import FeedList from '$lib/components/feed/FeedList.svelte';
  import Avatar from '$lib/components/ui/Avatar.svelte';
  import Skeleton from '$lib/components/ui/Skeleton.svelte';
  import TimelineFeed, { type TimelineTab } from '$lib/components/feed/TimelineFeed.svelte';

  // ── Public feeds (Local / Global / Trending) ─────────────────────────
  async function loadPublic(base: string, cursor: string | null): Promise<Post[]> {
    let endpoint = base;
    if (cursor) endpoint += (endpoint.includes('?') ? '&' : '?') + `max_id=${cursor}`;
    const items = await api.get<Post[]>(endpoint);
    return Array.isArray(items) ? items : [];
  }

  // Local tab shows only posts authored on this instance. Remote federated
  // authors (acct contains '@', or a foreign URL host) belong on Global.
  function isLocalPost(p: Post): boolean {
    const host = typeof window !== 'undefined' ? window.location.host : '';
    const acct = (p.account as any)?.acct ?? '';
    if (!acct.includes('@')) return true;
    const authorHost = (p.account as any)?.url ? new URL((p.account as any).url).host : host;
    return authorHost === host;
  }

  const exploreTabs: TimelineTab[] = [
    {
      id: 'local',
      label: 'Local',
      icon: 'home',
      load: (c) => loadPublic('/api/v1/timelines/public?local=true', c),
      stream: {
        kind: 'public',
        filter: (p) => !(((p.account as any)?.acct ?? '') as string).includes('@'),
      },
      accepts: isLocalPost,
      emptyMessage: 'No local posts yet',
    },
    {
      id: 'global',
      label: 'Global',
      icon: 'public',
      load: (c) => loadPublic('/api/v1/timelines/global', c),
      stream: { kind: 'public' },
      emptyMessage: 'No posts from the fediverse yet',
    },
    {
      id: 'trending',
      label: 'Trending',
      icon: 'trending_up',
      load: (c) => loadPublic('/api/v1/timelines/public?algorithm=trending', c),
      // Algorithmic — a brand-new post shouldn't jump onto Trending.
      stream: null,
      accepts: () => false,
      emptyMessage: 'Nothing trending right now',
    },
  ];

  // ── Search ───────────────────────────────────────────────────────────
  let query = $state('');
  let searchTab = $state('posts');
  let searching = $state(false);
  let hasSearched = $state(false);

  let searchPosts: Post[] = $state([]);
  let searchAccounts: Identity[] = $state([]);
  let searchHashtags: TrendingTag[] = $state([]);

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
      } else if (
        searchHashtags.length > 0 &&
        searchPosts.length === 0 &&
        searchAccounts.length === 0
      ) {
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

  // React to URL query param changes (the search box lives in the header).
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
  <title>Explore - Bassam Social</title>
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
                  <span class="account-name"><DisplayName name={account.display_name || account.acct || account.handle} emojis={account.emojis} /></span>
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
    <TimelineFeed tabs={exploreTabs} filterContext="public" />
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
</style>
