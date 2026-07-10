<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api/client.js';
  import { relativeTime } from '$lib/utils/time.js';
  import Spinner from '$lib/components/ui/Spinner.svelte';
  import { instanceName } from '$lib/stores/instance.js';

  interface NewUser {
    id: string;
    handle: string;
    display_name: string | null;
    avatar_url: string | null;
    bio: string | null;
    joined_at: string;
  }

  let users: NewUser[] = $state([]);
  let loading = $state(true);
  let error = $state('');

  async function load() {
    loading = true;
    error = '';
    try {
      users = await api.get<NewUser[]>('/api/v1/directory/new', { limit: '50' });
    } catch {
      error = 'Failed to load the directory.';
    } finally {
      loading = false;
    }
  }

  onMount(load);
</script>

<svelte:head>
  <title>Directory — {$instanceName}</title>
</svelte:head>

<div class="directory-page">
  <header class="page-header">
    <h1 class="page-title">Directory</h1>
    <p class="page-sub">
      The 50 most recent members who chose to appear here. You can opt out in
      <a href="/settings/privacy">Settings → Privacy</a>.
    </p>
  </header>

  {#if loading}
    <div class="state-center"><Spinner /></div>
  {:else if error}
    <div class="state-center">
      <p>{error}</p>
      <button type="button" class="btn btn-outline" onclick={load}>Retry</button>
    </div>
  {:else if users.length === 0}
    <div class="state-center">
      <p>No members to show yet.</p>
    </div>
  {:else}
    <ul class="directory-list">
      {#each users as user (user.id)}
        <li>
          <a href="/@{user.handle}" class="directory-item">
            <img
              src={user.avatar_url || '/images/default-avatar.svg'}
              alt=""
              class="directory-avatar"
            />
            <div class="directory-info">
              <div class="directory-name">
                {user.display_name || user.handle}
                <span class="directory-joined">joined {relativeTime(user.joined_at)}</span>
              </div>
              <div class="directory-handle">@{user.handle}</div>
              {#if user.bio}
                <div class="directory-bio">{user.bio}</div>
              {/if}
            </div>
          </a>
        </li>
      {/each}
    </ul>
  {/if}
</div>

<style>
  .directory-page {
    max-width: var(--feed-max-width);
    margin: 0 auto;
  }

  .page-header {
    margin-block-end: var(--space-4);
  }

  .page-title {
    font-size: var(--text-xl);
    font-weight: 700;
    color: var(--color-text);
  }

  .page-sub {
    margin-block-start: var(--space-1);
    color: var(--color-text-tertiary);
    font-size: var(--text-sm);
  }

  .page-sub a {
    color: var(--color-primary);
    text-decoration: none;
  }

  .page-sub a:hover {
    text-decoration: underline;
  }

  .state-center {
    text-align: center;
    padding: var(--space-12) var(--space-4);
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: var(--space-3);
  }

  .directory-list {
    list-style: none;
    padding: 0;
    margin: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }

  .directory-item {
    display: flex;
    align-items: flex-start;
    gap: var(--space-3);
    padding: var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-lg);
    background: var(--color-surface);
    text-decoration: none;
    color: inherit;
    transition: background-color 150ms ease;
  }

  .directory-item:hover {
    background: var(--color-surface-hover);
  }

  .directory-avatar {
    width: 48px;
    height: 48px;
    border-radius: 50%;
    object-fit: cover;
    flex-shrink: 0;
  }

  .directory-info {
    flex: 1;
    min-width: 0;
  }

  .directory-name {
    font-weight: 700;
    color: var(--color-text);
    display: flex;
    align-items: baseline;
    gap: var(--space-2);
    flex-wrap: wrap;
  }

  .directory-joined {
    font-weight: 400;
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
  }

  .directory-handle {
    font-size: var(--text-sm);
    color: var(--color-text-tertiary);
  }

  .directory-bio {
    margin-block-start: var(--space-2);
    font-size: var(--text-sm);
    color: var(--color-text);
    line-height: 1.4;
  }
</style>
