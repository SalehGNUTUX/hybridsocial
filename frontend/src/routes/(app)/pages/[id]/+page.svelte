<script lang="ts">
  import { page } from '$app/stores';
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { getPage, updatePage, deletePage } from '$lib/api/pages.js';
  import { api } from '$lib/api/client.js';
  import { currentUser, isStaffMember } from '$lib/stores/auth.js';
  import type { Post } from '$lib/api/types.js';
  import Avatar from '$lib/components/ui/Avatar.svelte';
  import Tabs from '$lib/components/ui/Tabs.svelte';
  import FeedList from '$lib/components/feed/FeedList.svelte';
  import Spinner from '$lib/components/ui/Spinner.svelte';
  import AdminProfileActions from '$lib/components/admin/AdminProfileActions.svelte';

  let pageId = $state('');
  let pageData: any = $state(null);
  let loading = $state(true);
  let error = $state('');
  let activeTab = $state('posts');
  let posts: Post[] = $state([]);
  let postsLoading = $state(false);
  let isFollowing = $state(false);
  let followLoading = $state(false);

  // Owner detection — backend serialize_page returns
  // organization.owner_id (the identity_id of the page's creator).
  // Compare against the current user so the Edit/Delete bar only
  // appears for the actual owner. Instance admins/mods see the
  // existing AdminProfileActions component on the page header
  // since pages are identities; their moderation tools live there.
  let isOwner = $derived(
    !!pageData &&
      !!$currentUser &&
      pageData.organization?.owner_id === $currentUser.id,
  );

  // Edit dialog state
  let showEditDialog = $state(false);
  let editForm = $state({
    display_name: '',
    bio: '',
    avatar_url: '',
    header_url: '',
    website: '',
    category: '',
  });
  let editSaving = $state(false);
  let editError = $state('');

  // Delete confirm
  let showDeleteConfirm = $state(false);
  let deleting = $state(false);

  function openEditDialog() {
    if (!pageData) return;
    editForm = {
      display_name: pageData.display_name || '',
      bio: pageData.bio || '',
      avatar_url: pageData.avatar_url || '',
      header_url: pageData.header_url || '',
      website: pageData.organization?.website || pageData.website || '',
      category: pageData.organization?.category || pageData.category || '',
    };
    editError = '';
    showEditDialog = true;
  }

  async function saveEdit() {
    editSaving = true;
    editError = '';
    try {
      const updated = await updatePage(pageId, {
        display_name: editForm.display_name.trim() || null,
        bio: editForm.bio.trim() || null,
        avatar_url: editForm.avatar_url.trim() || null,
        header_url: editForm.header_url.trim() || null,
        website: editForm.website.trim() || null,
        category: editForm.category.trim() || null,
      });
      pageData = { ...pageData, ...updated };
      showEditDialog = false;
    } catch (e: any) {
      editError = e?.body?.message || 'Failed to save page changes.';
    } finally {
      editSaving = false;
    }
  }

  async function confirmDelete() {
    deleting = true;
    try {
      await deletePage(pageId);
      goto('/pages');
    } catch {
      deleting = false;
      showDeleteConfirm = false;
    }
  }

  const tabs = [
    { id: 'posts', label: 'Posts' },
    { id: 'about', label: 'About' },
  ];

  const unsub = page.subscribe(($page) => {
    pageId = $page.params.id!;
  });

  async function loadPage() {
    loading = true;
    error = '';
    try {
      pageData = await getPage(pageId);
      isFollowing = pageData?.is_following ?? false;
      await loadPosts();
    } catch {
      error = 'Failed to load page.';
    } finally {
      loading = false;
    }
  }

  async function loadPosts() {
    if (!pageData) return;
    postsLoading = true;
    try {
      // Endpoint returns PaginatedResponse<Post> ({data, next_cursor,
      // prev_cursor}) — keep the bare-array branch as a fallback in
      // case an older deploy / proxy still returns the legacy shape.
      const result = await api.get<{ data?: Post[] } | Post[]>(
        `/api/v1/pages/${pageId}/statuses`,
      );
      posts = Array.isArray(result) ? result : (result.data ?? []);
    } catch {
      posts = [];
    } finally {
      postsLoading = false;
    }
  }

  async function toggleFollow() {
    if (!pageData) return;
    followLoading = true;
    try {
      if (isFollowing) {
        await api.post(`/api/v1/pages/${pageId}/unfollow`);
        isFollowing = false;
      } else {
        await api.post(`/api/v1/pages/${pageId}/follow`);
        isFollowing = true;
      }
    } catch {
      // Error handled silently
    } finally {
      followLoading = false;
    }
  }

  onMount(() => {
    loadPage();
    return () => unsub();
  });
</script>

<svelte:head>
  <title>{pageData?.display_name || pageData?.name || 'Page'} - HybridSocial</title>
</svelte:head>

<div class="page-detail">
  {#if loading}
    <div class="loading-state">
      <Spinner />
    </div>
  {:else if error}
    <div class="error-state">
      <p>{error}</p>
      <button type="button" class="btn btn-outline" onclick={loadPage}>Retry</button>
    </div>
  {:else if pageData}
    <div class="page-profile">
      <!-- Cover image -->
      <div class="page-cover">
        {#if pageData.header_url || pageData.cover_url}
          <img src={pageData.header_url || pageData.cover_url} alt="" class="cover-img" />
        {:else}
          <div class="cover-gradient" aria-hidden="true"></div>
        {/if}
      </div>

      <div class="page-info-section">
        <div class="page-avatar-row">
          <div class="page-avatar-wrapper">
            <Avatar
              src={pageData.avatar_url || pageData.logo_url}
              name={pageData.display_name || pageData.name || pageData.handle}
              size="xl"
            />
          </div>
          <div class="page-actions">
            {#if $isStaffMember && !isOwner && pageData}
              <AdminProfileActions account={pageData} />
            {/if}
            {#if isOwner || ($isStaffMember && pageData)}
              <button type="button" class="btn btn-outline" onclick={openEditDialog}>
                Edit page
              </button>
              <a class="btn btn-outline" href={`/pages/${pageId}/settings`}>
                Manage
              </a>
              <button
                type="button"
                class="btn btn-outline btn-danger-outline"
                onclick={() => (showDeleteConfirm = true)}
              >
                Delete
              </button>
            {:else if pageData?.viewer_role && pageData.viewer_role !== null}
              <!-- Non-owners with admin/editor/moderator role on the
                   page see the Manage button (no Edit/Delete which
                   only the org owner can do). -->
              <a class="btn btn-outline" href={`/pages/${pageId}/settings`}>
                Manage
              </a>
              <button
                type="button"
                class="btn {isFollowing ? 'btn-outline' : 'btn-primary'}"
                onclick={toggleFollow}
                disabled={followLoading}
              >
                {isFollowing ? 'Following' : 'Follow'}
              </button>
            {:else}
              <button
                type="button"
                class="btn {isFollowing ? 'btn-outline' : 'btn-primary'}"
                onclick={toggleFollow}
                disabled={followLoading}
              >
                {isFollowing ? 'Following' : 'Follow'}
              </button>
            {/if}
          </div>
        </div>

        <div class="page-identity">
          <h1 class="page-name">{pageData.display_name || pageData.name || pageData.handle}</h1>
          <span class="page-handle">@{pageData.handle}</span>
          {#if pageData.category}
            <span class="page-category-badge">{pageData.category}</span>
          {/if}
        </div>

        {#if pageData.description || pageData.bio}
          <p class="page-description">{pageData.description || pageData.bio}</p>
        {/if}

        <!-- Business details -->
        <div class="business-details">
          {#if pageData.website}
            <div class="detail-item">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                <circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 014 10 15.3 15.3 0 01-4 10 15.3 15.3 0 01-4-10 15.3 15.3 0 014-10z"/>
              </svg>
              <a href={pageData.website} class="detail-link" target="_blank" rel="noopener">{pageData.website}</a>
            </div>
          {/if}
          {#if pageData.email}
            <div class="detail-item">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                <path d="M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z"/><polyline points="22,6 12,13 2,6"/>
              </svg>
              <a href="mailto:{pageData.email}" class="detail-link">{pageData.email}</a>
            </div>
          {/if}
          {#if pageData.phone}
            <div class="detail-item">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                <path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72 12.84 12.84 0 00.7 2.81 2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45 12.84 12.84 0 002.81.7A2 2 0 0122 16.92z"/>
              </svg>
              <span>{pageData.phone}</span>
            </div>
          {/if}
          {#if pageData.address}
            <div class="detail-item">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                <path d="M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0118 0z"/><circle cx="12" cy="10" r="3"/>
              </svg>
              <span>{pageData.address}</span>
            </div>
          {/if}
        </div>

        {#if pageData.social_links && pageData.social_links.length > 0}
          <div class="social-links">
            {#each pageData.social_links.slice(0, 4) as link (link.url || link)}
              <a href={link.url || link} class="social-link" target="_blank" rel="noopener">
                {link.label || link.url || link}
              </a>
            {/each}
          </div>
        {/if}

        {#if pageData.followers_count !== undefined}
          <div class="page-stats">
            <span class="stat-item">
              <strong>{pageData.followers_count}</strong>
              <span class="stat-label">Followers</span>
            </span>
          </div>
        {/if}
      </div>
    </div>

    <div class="page-feed-section">
      <Tabs {tabs} bind:active={activeTab}>
        {#if activeTab === 'posts'}
          <button
            type="button"
            class="scope-compose-btn"
            onclick={() =>
              window.dispatchEvent(
                new CustomEvent('open-composer', {
                  detail: {
                    pageId: pageData.id,
                    contextLabel: `Posting to ${pageData.title || pageData.name || 'page'}`,
                  },
                }),
              )}
          >
            <span class="material-symbols-outlined">edit</span>
            New post on this page
          </button>
          <FeedList
            {posts}
            loading={postsLoading}
            hasMore={false}
            viewerContext="page"
            emptyMessage="No posts yet"
          />
        {:else if activeTab === 'about'}
          <div class="about-section">
            {#if pageData.description || pageData.bio}
              <div class="about-block">
                <h3 class="about-heading">About</h3>
                <p class="about-text">{pageData.description || pageData.bio}</p>
              </div>
            {/if}
            {#if pageData.category}
              <div class="about-block">
                <h3 class="about-heading">Category</h3>
                <p class="about-text">{pageData.category}</p>
              </div>
            {/if}
            {#if pageData.created_at}
              <div class="about-block">
                <h3 class="about-heading">Created</h3>
                <p class="about-text">{new Date(pageData.created_at).toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' })}</p>
              </div>
            {/if}
          </div>
        {/if}
      </Tabs>
    </div>
  {/if}
</div>

{#if showEditDialog}
  <div class="modal-overlay" role="dialog" aria-modal="true" aria-label="Edit page" onclick={(e) => { if (e.target === e.currentTarget) showEditDialog = false; }}>
    <div class="modal-card">
      <div class="modal-header">
        <h3>Edit page</h3>
        <button type="button" class="modal-close" onclick={() => (showEditDialog = false)} aria-label="Close">✕</button>
      </div>
      <form class="modal-form" onsubmit={(e) => { e.preventDefault(); saveEdit(); }}>
        <label class="modal-field">
          <span>Display name</span>
          <input type="text" bind:value={editForm.display_name} maxlength="50" />
        </label>
        <label class="modal-field">
          <span>Bio</span>
          <textarea bind:value={editForm.bio} maxlength="500" rows="3" dir="auto"></textarea>
        </label>
        <label class="modal-field">
          <span>Avatar URL</span>
          <input type="url" bind:value={editForm.avatar_url} maxlength="2048" placeholder="https://…" />
        </label>
        <label class="modal-field">
          <span>Header URL</span>
          <input type="url" bind:value={editForm.header_url} maxlength="2048" placeholder="https://…" />
        </label>
        <label class="modal-field">
          <span>Website</span>
          <input type="url" bind:value={editForm.website} placeholder="https://…" />
        </label>
        <label class="modal-field">
          <span>Category</span>
          <input type="text" bind:value={editForm.category} maxlength="60" placeholder="Business / Tech / Arts / …" />
        </label>
        {#if editError}
          <p class="modal-error">{editError}</p>
        {/if}
        <div class="modal-actions">
          <button type="button" class="btn btn-ghost" onclick={() => (showEditDialog = false)}>Cancel</button>
          <button type="submit" class="btn btn-primary" disabled={editSaving}>
            {editSaving ? 'Saving…' : 'Save'}
          </button>
        </div>
      </form>
    </div>
  </div>
{/if}

{#if showDeleteConfirm}
  <div class="modal-overlay" role="dialog" aria-modal="true" aria-label="Delete page" onclick={(e) => { if (e.target === e.currentTarget) showDeleteConfirm = false; }}>
    <div class="modal-card modal-card-narrow">
      <h3 class="modal-title-danger">Delete this page?</h3>
      <p class="modal-message">
        This permanently deletes <strong>{pageData?.display_name || pageData?.handle}</strong>
        and every post made to it. The action cannot be undone.
      </p>
      <div class="modal-actions">
        <button type="button" class="btn btn-ghost" onclick={() => (showDeleteConfirm = false)} disabled={deleting}>Cancel</button>
        <button type="button" class="btn btn-danger" onclick={confirmDelete} disabled={deleting}>
          {deleting ? 'Deleting…' : 'Delete page'}
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .page-detail {
    max-width: var(--feed-max-width);
    margin: 0 auto;
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }

  .loading-state {
    display: flex;
    justify-content: center;
    padding: var(--space-16);
  }

  .error-state {
    text-align: center;
    padding: var(--space-16) var(--space-4);
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: var(--space-3);
    color: var(--color-text-secondary);
  }

  .page-profile {
    background: var(--color-surface-raised);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-xl);
    /* No overflow clipping — the moderation popover anchored inside
       .page-actions needs to escape the card. The cover clips itself. */
  }

  .page-cover {
    height: 180px;
    overflow: hidden;
    border-top-left-radius: var(--radius-xl);
    border-top-right-radius: var(--radius-xl);
  }

  .cover-img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }

  .cover-gradient {
    width: 100%;
    height: 100%;
    background: linear-gradient(var(--gradient-direction, 135deg), var(--gradient-start, var(--color-primary)), var(--gradient-end, #0d9488));
  }

  .page-info-section {
    padding: 0 var(--space-6) var(--space-6);
  }

  .page-avatar-row {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    margin-block-start: -40px;
  }

  .page-avatar-wrapper {
    border: 4px solid var(--color-surface-raised);
    border-radius: var(--radius-full);
    background: var(--color-surface-raised);
  }

  .page-actions {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    padding-block-start: var(--space-10);
  }

  .page-identity {
    margin-block-start: var(--space-3);
    display: flex;
    flex-direction: column;
    gap: var(--space-1);
  }

  .page-name {
    font-size: var(--text-xl);
    font-weight: 700;
    color: var(--color-text);
  }

  .page-handle {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
  }

  .page-category-badge {
    display: inline-block;
    align-self: flex-start;
    font-size: var(--text-xs);
    color: var(--color-primary);
    background: var(--color-primary-soft);
    padding: 2px var(--space-2);
    border-radius: var(--radius-sm);
    margin-block-start: var(--space-1);
  }

  .page-description {
    margin-block-start: var(--space-3);
    font-size: var(--text-sm);
    color: var(--color-text);
    line-height: var(--leading-relaxed);
    white-space: pre-wrap;
  }

  .business-details {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    margin-block-start: var(--space-3);
  }

  .detail-item {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
  }

  .detail-link {
    color: var(--color-primary);
    text-decoration: none;
  }

  .detail-link:hover {
    text-decoration: underline;
  }

  .social-links {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
    margin-block-start: var(--space-3);
  }

  .social-link {
    font-size: var(--text-xs);
    color: var(--color-primary);
    background: var(--color-primary-soft);
    padding: var(--space-1) var(--space-2);
    border-radius: var(--radius-sm);
    text-decoration: none;
  }

  .social-link:hover {
    text-decoration: underline;
  }

  .page-stats {
    display: flex;
    gap: var(--space-5);
    margin-block-start: var(--space-3);
  }

  .stat-item {
    display: inline-flex;
    align-items: center;
    gap: var(--space-1);
    font-size: var(--text-sm);
    color: var(--color-text);
  }

  .stat-item strong {
    font-weight: 700;
  }

  .stat-label {
    color: var(--color-text-secondary);
  }

  .page-feed-section {
    background: var(--color-surface-raised);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-xl);
    padding: 0 var(--space-4) var(--space-4);
  }

  /* About */
  .about-section {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }

  .about-block {
    display: flex;
    flex-direction: column;
    gap: var(--space-1);
  }

  .about-heading {
    font-size: var(--text-sm);
    font-weight: 600;
    color: var(--color-text);
  }

  .about-text {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    line-height: var(--leading-relaxed);
    white-space: pre-wrap;
  }

  /* Buttons */
  .btn {
    display: inline-flex;
    align-items: center;
    gap: var(--space-1);
    padding: var(--space-2) var(--space-3);
    border: none;
    border-radius: var(--radius-md);
    font-size: var(--text-sm);
    font-weight: 500;
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .btn-primary {
    background: var(--color-primary);
    color: var(--color-text-inverse);
  }

  .btn-primary:hover:not(:disabled) {
    background: var(--color-primary-hover);
  }

  .btn-primary:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .btn-outline {
    background: transparent;
    border: 1px solid var(--color-border);
    color: var(--color-text);
  }

  .btn-outline:hover {
    background: var(--color-surface);
  }

  .btn-danger-outline {
    color: #dc2626;
    border-color: rgba(220, 38, 38, 0.4);
  }

  .btn-danger-outline:hover {
    background: rgba(220, 38, 38, 0.08);
  }

  .btn-danger {
    background: #dc2626;
    color: #fff;
    border: 0;
  }

  .btn-danger:hover:not(:disabled) {
    background: #b91c1c;
  }

  .btn-danger:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .btn-ghost {
    background: transparent;
    border: 0;
    color: var(--color-text-secondary);
  }

  .btn-ghost:hover:not(:disabled) {
    background: var(--color-surface);
    color: var(--color-text);
  }

  /* --- Edit / Delete modal --- */
  .modal-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: var(--space-4);
    z-index: 1000;
  }

  .modal-card {
    background: var(--color-surface-raised);
    border-radius: var(--radius-xl);
    padding: var(--space-6);
    max-width: 520px;
    width: 100%;
    max-height: 90vh;
    overflow-y: auto;
  }

  .modal-card-narrow {
    max-width: 420px;
  }

  .modal-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-block-end: var(--space-3);
  }

  .modal-header h3,
  .modal-title-danger {
    margin: 0;
    font-size: var(--text-lg);
    font-weight: 700;
  }

  .modal-title-danger {
    color: #dc2626;
    margin-block-end: var(--space-2);
  }

  .modal-message {
    color: var(--color-text-secondary);
    line-height: 1.5;
    margin-block-end: var(--space-4);
  }

  .modal-close {
    background: transparent;
    border: 0;
    font-size: 1rem;
    cursor: pointer;
    color: var(--color-text-tertiary);
  }

  .modal-form {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }

  .modal-field {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .modal-field span {
    font-size: var(--text-xs);
    font-weight: 700;
    color: var(--color-text-secondary);
  }

  .modal-field input,
  .modal-field textarea {
    padding: var(--space-2) var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    background: var(--color-bg);
    color: var(--color-text);
    font-size: var(--text-sm);
    font-family: inherit;
  }

  .modal-field input:focus,
  .modal-field textarea:focus {
    outline: none;
    border-color: var(--color-primary);
  }

  .modal-error {
    color: #dc2626;
    font-size: var(--text-sm);
    margin: 0;
  }

  .modal-actions {
    display: flex;
    justify-content: flex-end;
    gap: var(--space-2);
    margin-block-start: var(--space-3);
  }

  @media (max-width: 480px) {
    .page-cover {
      height: 120px;
    }

    .page-info-section {
      padding: 0 var(--space-4) var(--space-4);
    }
  }

  .scope-compose-btn {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 10px 16px;
    margin-block-end: var(--space-3);
    background: var(--color-primary);
    color: var(--color-text-on-primary);
    border: 0;
    border-radius: var(--radius-lg);
    font-size: var(--text-sm);
    font-weight: 600;
    cursor: pointer;
  }

  .scope-compose-btn:hover {
    background: var(--color-primary-hover);
  }

  .scope-compose-btn .material-symbols-outlined {
    font-size: 18px;
  }
</style>
