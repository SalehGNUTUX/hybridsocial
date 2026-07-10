<script lang="ts">
  import { goto } from '$app/navigation';
  import Avatar from '$lib/components/ui/Avatar.svelte';
  import Dropdown from '$lib/components/ui/Dropdown.svelte';
  import { currentUser, isLoggedIn, clearAuth } from '$lib/stores/auth.js';
  import { unreadCount } from '$lib/stores/notifications.js';
  import { dmUnreadTotal } from '$lib/stores/dm-unread.js';
  import { api } from '$lib/api/client.js';
  import type { Identity } from '$lib/api/types.js';
  import { themeStore, resolvedMode } from '$lib/stores/theme.js';
  import { instanceName } from '$lib/stores/instance.js';

  let user: Identity | null = $state(null);
  let authenticated = $state(false);
  let searchQuery = $state('');
  let searchExpanded = $state(false);
  let searchInputEl: HTMLInputElement | undefined = $state();
  let searchHoverTimer: ReturnType<typeof setTimeout> | null = null;
  let notifCount = $state(0);
  let dmCount = $state(0);

  currentUser.subscribe((v) => (user = v));
  isLoggedIn.subscribe((v) => (authenticated = v));
  unreadCount.subscribe((v) => (notifCount = v));
  dmUnreadTotal.subscribe((v) => (dmCount = v));

  function handleSearch(e: Event) {
    e.preventDefault();
    if (searchQuery.trim()) {
      const q = searchQuery.trim();
      searchQuery = '';
      searchExpanded = false;
      goto(`/explore?q=${encodeURIComponent(q)}`);
    }
  }

  function expandSearch() {
    searchExpanded = true;
    setTimeout(() => searchInputEl?.focus(), 50);
  }

  // Called from `onblur` on the input. Previously collapsed eagerly
  // on every blur which destroyed typed text the moment the user
  // clicked a dropdown item / an autocomplete suggestion. The new
  // contract: blur alone never closes — the search stays put while
  // the user has typed something. They can still dismiss explicitly
  // via Escape or by submitting.
  function collapseSearch() {
    if (!searchQuery.trim() && !isMouseOverSearch) {
      searchExpanded = false;
    }
  }

  // Escape key dismisses — lets users back out without a submit.
  function handleSearchKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      searchQuery = '';
      searchExpanded = false;
    }
  }

  let searchCloseTimer: ReturnType<typeof setTimeout> | null = null;
  let isMouseOverSearch = $state(false);

  function handleSearchHoverOut() {
    isMouseOverSearch = false;

    if (searchHoverTimer) {
      clearTimeout(searchHoverTimer);
      searchHoverTimer = null;
    }
    // Keep the search open when there's any text — nothing the user
    // typed should vanish because of mouse movement. Only the
    // empty-state hover bubble auto-closes.
    if (searchExpanded && !searchQuery.trim()) {
      searchCloseTimer = setTimeout(() => {
        if (!searchQuery.trim()) {
          searchExpanded = false;
        }
      }, 200);
    }
  }

  function handleSearchHoverIn() {
    isMouseOverSearch = true;

    if (searchCloseTimer) {
      clearTimeout(searchCloseTimer);
      searchCloseTimer = null;
    }
    searchHoverTimer = setTimeout(expandSearch, 200);
  }

  async function handleLogout() {
    try {
      await api.post('/api/v1/auth/logout');
    } catch {
      // Proceed with logout even if API call fails
    }
    clearAuth();
    goto('/login');
  }
</script>

<header class="header">
  <div class="header-inner">
    <!-- Logo + Nav -->
    <div class="header-start">
      <a href="/home" class="header-logo" aria-label="{$instanceName} home">
        {#if $themeStore?.logo_url || $themeStore?.dark_logo_url}
          <img
            src={$resolvedMode === 'dark'
              ? $themeStore?.dark_logo_url || $themeStore?.logo_url
              : $themeStore?.logo_url || $themeStore?.dark_logo_url}
            alt={$instanceName}
            class="header-logo-img"
          />
        {:else}
          <svg class="logo-mark" width="32" height="32" viewBox="0 0 32 32" fill="none">
            <rect width="32" height="32" rx="10" fill="url(#logo-grad)" />
            <text x="16" y="22" text-anchor="middle" fill="white" font-size="16" font-weight="800" font-family="'Manrope', sans-serif">H</text>
            <defs>
              <linearGradient id="logo-grad" x1="0" y1="0" x2="32" y2="32">
                <stop offset="0%" stop-color="#6c3edd" />
                <stop offset="100%" stop-color="#7183da" />
              </linearGradient>
            </defs>
          </svg>
          <span class="header-logo-text">{$instanceName}</span>
        {/if}
      </a>

    </div>

    <!-- Search -->
    <div
      class="header-search-wrap"
      class:search-expanded={searchExpanded}
      onmouseenter={handleSearchHoverIn}
      onmouseleave={handleSearchHoverOut}
    >
      {#if searchExpanded}
        <form class="header-search" onsubmit={handleSearch}>
          <span class="material-symbols-outlined search-form-icon">search</span>
          <input
            bind:this={searchInputEl}
            type="search"
            bind:value={searchQuery}
            placeholder="Search..."
            class="search-input"
            aria-label="Search"
            onblur={collapseSearch}
            onkeydown={handleSearchKeydown}
          />
        </form>
      {:else}
        <button
          type="button"
          class="header-icon-btn search-toggle-btn"
          onclick={expandSearch}
          aria-label="Search"
        >
          <span class="material-symbols-outlined">search</span>
        </button>
      {/if}
    </div>

    <!-- Actions -->
    <div class="header-actions">
      {#if authenticated && user}
        <!-- Notifications -->
        <a href="/notifications" class="header-icon-btn header-quick-link" aria-label="Notifications">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9" />
            <path d="M13.73 21a2 2 0 0 1-3.46 0" />
          </svg>
          {#if notifCount > 0}
            <span class="icon-badge">{notifCount > 99 ? '99+' : notifCount}</span>
          {/if}
        </a>

        <!-- Messages -->
        <a href="/messages" class="header-icon-btn header-quick-link" aria-label="Messages">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z" />
            <polyline points="22,6 12,13 2,6" />
          </svg>
          {#if dmCount > 0}
            <span class="icon-badge">{dmCount > 99 ? '99+' : dmCount}</span>
          {/if}
        </a>

        <!-- User avatar dropdown -->
        <Dropdown align="end">
          {#snippet trigger()}
            <button class="avatar-btn" type="button" aria-label="Account menu">
              <span class="avatar-ring">
                <Avatar src={user!.avatar_url} name={user!.display_name || user!.handle} size="sm" />
              </span>
            </button>
          {/snippet}
          <a href="/@{user.handle}">Profile</a>
          <a href="/settings">Settings</a>
          {#if user.is_admin}
            <a href="/admin">Admin</a>
          {/if}
          <div class="dropdown-divider"></div>
          <button class="dropdown-item-danger" onclick={handleLogout} type="button">Log out</button>
        </Dropdown>
      {/if}
    </div>
  </div>
</header>

<style>
  .header {
    position: fixed;
    top: 0;
    inset-inline: 0;
    height: var(--header-height);
    background: var(--color-glass);
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    border-block-end: var(--ghost-border);
    z-index: var(--z-header);
  }

  .header-inner {
    display: flex;
    align-items: center;
    gap: var(--space-6);
    max-width: var(--layout-max-width);
    margin: 0 auto;
    height: 100%;
    padding: 0 var(--space-6);
  }

  /* --- Logo + Nav group --- */
  .header-start {
    display: flex;
    align-items: center;
    gap: var(--space-6);
    flex-shrink: 0;
  }

  .header-logo {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    text-decoration: none;
    color: var(--color-on-surface);
    flex-shrink: 0;
  }

  .header-logo:hover {
    text-decoration: none;
  }

  .header-logo-text {
    font-family: var(--font-headline);
    font-weight: 800;
    font-size: var(--text-lg);
    color: var(--color-primary);
    letter-spacing: -0.02em;
  }

  .header-logo-img {
    height: 34px;
    width: auto;
    max-width: 170px;
    display: block;
  }

  /* --- Search --- */
  .header-search-wrap {
    position: relative;
    display: flex;
    align-items: center;
  }

  .search-toggle-btn .material-symbols-outlined {
    font-size: 22px;
  }

  .header-search {
    display: flex;
    align-items: center;
    position: relative;
    animation: search-expand 0.25s cubic-bezier(0.22, 1, 0.36, 1);
  }

  @keyframes search-expand {
    from {
      width: 40px;
      opacity: 0;
    }
    to {
      width: 260px;
      opacity: 1;
    }
  }

  .search-form-icon {
    position: absolute;
    inset-inline-start: 12px;
    font-size: 20px;
    color: var(--color-text-tertiary);
    pointer-events: none;
  }

  .search-input {
    width: 260px;
    height: 40px;
    padding: var(--space-2) var(--space-4);
    padding-inline-start: 40px;
    border: none;
    border-radius: var(--radius-full);
    font-family: var(--font-body);
    font-size: var(--text-sm);
    background: var(--color-surface-container-high);
    color: var(--color-on-surface);
    transition: background var(--transition-fast), box-shadow var(--transition-fast);
  }

  .search-input::placeholder {
    color: var(--color-text-tertiary);
  }

  .search-input:focus {
    outline: none;
    background: var(--color-surface-container-lowest);
    box-shadow: 0 0 0 2px var(--color-primary);
  }

  /* --- Actions --- */
  .header-actions {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    flex-shrink: 0;
    margin-inline-start: auto;
  }

  .header-icon-btn {
    position: relative;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 40px;
    height: 40px;
    border: none;
    background: none;
    border-radius: var(--radius-full);
    color: var(--color-on-surface-variant);
    text-decoration: none;
    cursor: pointer;
    transition: background var(--transition-fast), color var(--transition-fast);
  }

  .header-icon-btn:hover {
    background: var(--color-surface-container-low);
    color: var(--color-on-surface);
    text-decoration: none;
  }

  .icon-badge {
    position: absolute;
    top: 4px;
    inset-inline-end: 4px;
    min-width: 18px;
    height: 18px;
    padding: 0 5px;
    font-family: var(--font-body);
    font-size: 0.65rem;
    font-weight: 700;
    line-height: 18px;
    text-align: center;
    color: var(--color-on-primary);
    background: var(--color-error);
    border-radius: var(--radius-full);
    /* Ring matches the bar behind it (separates the badge) — flips with
       the theme instead of staying white. */
    border: 2px solid var(--color-surface);
  }

  .avatar-btn {
    background: none;
    border: none;
    padding: 0;
    cursor: pointer;
    border-radius: var(--radius-full);
  }

  .avatar-ring {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2px;
    border: 2px solid var(--color-primary);
    border-radius: var(--radius-full);
    transition: border-color var(--transition-fast);
  }

  .avatar-btn:hover .avatar-ring {
    border-color: var(--color-primary-container);
  }

  /* --- Responsive --- */
  @media (max-width: 768px) {
    .header-inner {
      padding: 0 var(--space-3);
      gap: var(--space-3);
    }

    .header-logo-text {
      display: none;
    }

    /* Mobile top bar = logo (left) + search + avatar (right). Notifications
       live in the bottom bar and Messages in the "More" sheet, so those two
       quick-links are dropped; the avatar (account menu) stays. */
    .header-quick-link {
      display: none;
    }

    .header-search-wrap {
      margin-inline-start: auto;
    }

    /* Solid bar on mobile: a fixed bar with backdrop-filter blur repaints
       on every scroll frame and flickers on mobile GPUs (#10). */
    .header {
      background: var(--color-surface);
      backdrop-filter: none;
      -webkit-backdrop-filter: none;
    }

    .search-input {
      width: 180px;
    }

    @keyframes search-expand {
      from { width: 40px; opacity: 0; }
      to { width: 180px; opacity: 1; }
    }
  }
</style>
