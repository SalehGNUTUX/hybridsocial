<script lang="ts">
  import { page } from '$app/stores';
  import { goto } from '$app/navigation';
  import { onMount } from 'svelte';
  import { addToast } from '$lib/stores/toast.js';
  import {
    getAdminPost, adminDeletePost, adminForceSensitive, adminRemoveSensitive,
    type AdminPostDetail
  } from '$lib/api/admin.js';

  // SvelteKit types `params.id` as possibly-undefined because in
  // principle the segment can be missing. The route file name
  // guarantees it'll be present, so fall back to empty string to keep
  // the type checker happy — the getAdminPost call will 404 and the
  // not_found branch renders if this ever actually fires with nothing.
  let postId = $derived($page.params.id ?? '');
  let post: AdminPostDetail | null = $state(null);
  let loading = $state(true);
  let notFound = $state(false);
  let acting = $state(false);

  type Report = AdminPostDetail['reports'][number];
  let openReports: Report[] = $derived.by(() => {
    const p = post;
    return p ? p.reports.filter((r: Report) => r.status === 'pending') : [];
  });
  let closedReports: Report[] = $derived.by(() => {
    const p = post;
    return p ? p.reports.filter((r: Report) => r.status !== 'pending') : [];
  });

  onMount(() => {
    load();
  });

  async function load() {
    loading = true;
    notFound = false;
    try {
      post = await getAdminPost(postId);
    } catch (err: unknown) {
      const e = err as { body?: { error?: string } };
      if (e?.body?.error === 'post.not_found') {
        notFound = true;
      } else {
        addToast('Failed to load post', 'error');
      }
    } finally {
      loading = false;
    }
  }

  async function handleDelete() {
    if (!post) return;
    const reason = prompt('Reason for deletion (optional, logged for audit):');
    if (reason === null) return;
    acting = true;
    try {
      await adminDeletePost(post.id, reason || undefined);
      addToast('Post deleted', 'success');
      await load();
    } catch {
      addToast('Failed to delete post', 'error');
    } finally {
      acting = false;
    }
  }

  async function handleToggleSensitive() {
    if (!post) return;
    acting = true;
    try {
      if (post.sensitive) {
        await adminRemoveSensitive(post.id);
        addToast('Sensitive flag removed', 'success');
      } else {
        await adminForceSensitive(post.id);
        addToast('Marked as sensitive', 'success');
      }
      await load();
    } catch {
      addToast('Failed to update sensitivity', 'error');
    } finally {
      acting = false;
    }
  }

  function formatDate(iso: string | null): string {
    if (!iso) return '—';
    return new Date(iso).toLocaleString(undefined, {
      year: 'numeric', month: 'short', day: 'numeric',
      hour: '2-digit', minute: '2-digit'
    });
  }

  function mediaSrc(m: AdminPostDetail['media'][number]): string {
    return m.storage_path || m.remote_url || '';
  }
</script>

<svelte:head>
  <title>Post {postId.slice(0, 8)} — Admin</title>
</svelte:head>

<div class="post-detail-page">
  <a class="back-link" href="/admin/moderation">← Moderation</a>

  {#if loading}
    <div class="skeleton" style="height: 200px"></div>
  {:else if notFound}
    <div class="not-found card">
      <h1 class="not-found-title">Post not found</h1>
      <p class="not-found-text">
        The post id <code>{postId}</code> doesn't exist or has been hard-deleted.
      </p>
    </div>
  {:else if post}
    <div class="layout">
      <!-- LEFT: post preview + reports + audit log -->
      <div class="main-col">
        <!-- Post preview card -->
        <section class="card post-card" class:post-deleted={!!post.deleted_at}>
          <header class="post-header">
            <div class="author">
              {#if post.identity}
                <a href="/@{post.identity.handle}" class="author-name">
                  {post.identity.display_name || post.identity.handle}
                </a>
                <span class="author-handle">@{post.identity.handle}</span>
              {:else}
                <span class="author-name">(unknown author)</span>
              {/if}
            </div>
            <div class="post-meta">
              <span class="visibility-badge vis-{post.visibility}">{post.visibility}</span>
              {#if post.sensitive}<span class="badge badge-warning">sensitive</span>{/if}
              {#if post.deleted_at}<span class="badge badge-danger">deleted</span>{/if}
              {#if post.edited_at}<span class="badge badge-neutral">edited</span>{/if}
              {#if post.is_pinned}<span class="badge badge-info">pinned</span>{/if}
            </div>
          </header>

          {#if post.spoiler_text}
            <p class="spoiler">CW: {post.spoiler_text}</p>
          {/if}

          {#if post.content_html}
            <div class="post-body">{@html post.content_html}</div>
          {:else if post.content}
            <div class="post-body post-body-plain">{post.content}</div>
          {:else}
            <div class="post-body post-body-empty">(no text content)</div>
          {/if}

          {#if post.media && post.media.length > 0}
            <div class="media-grid">
              {#each post.media as m (m.id)}
                {#if m.content_type.startsWith('image/')}
                  <img src={mediaSrc(m)} alt={m.alt_text || ''} class="media-thumb" />
                {:else if m.content_type.startsWith('video/')}
                  <video src={mediaSrc(m)} controls muted class="media-thumb"></video>
                {:else}
                  <div class="media-unknown">
                    <span>{m.content_type}</span>
                  </div>
                {/if}
              {/each}
            </div>
          {/if}

          <footer class="post-footer">
            <span>{post.reply_count} replies</span>
            <span>{post.boost_count} boosts</span>
            <span>{post.reaction_count} reactions</span>
          </footer>
        </section>

        <!-- Open reports -->
        <section class="card section">
          <header class="section-header">
            <h2 class="section-title">Open reports</h2>
            <span class="section-count">{openReports.length}</span>
          </header>
          {#if openReports.length === 0}
            <p class="empty-text">No pending reports against this post.</p>
          {:else}
            <ul class="report-list">
              {#each openReports as r (r.id)}
                <li class="report-row">
                  <div class="report-head">
                    <span class="report-category">{r.category}</span>
                    {#if r.reporter}
                      <a href="/@{r.reporter.handle}">@{r.reporter.handle}</a>
                    {:else}
                      <span class="muted">(anonymous)</span>
                    {/if}
                    <span class="muted">· {formatDate(r.created_at)}</span>
                  </div>
                  {#if r.comment}
                    <p class="report-comment">{r.comment}</p>
                  {/if}
                </li>
              {/each}
            </ul>
          {/if}
        </section>

        <!-- Resolved reports -->
        {#if closedReports.length > 0}
          <section class="card section">
            <header class="section-header">
              <h2 class="section-title">Resolved / dismissed reports</h2>
              <span class="section-count">{closedReports.length}</span>
            </header>
            <ul class="report-list">
              {#each closedReports as r (r.id)}
                <li class="report-row report-closed">
                  <div class="report-head">
                    <span class="report-category">{r.category}</span>
                    <span class="report-status">{r.status}</span>
                    {#if r.reporter}
                      <a href="/@{r.reporter.handle}">@{r.reporter.handle}</a>
                    {/if}
                    <span class="muted">· {formatDate(r.created_at)}</span>
                  </div>
                  {#if r.comment}
                    <p class="report-comment">{r.comment}</p>
                  {/if}
                </li>
              {/each}
            </ul>
          </section>
        {/if}

        <!-- Audit log -->
        <section class="card section">
          <header class="section-header">
            <h2 class="section-title">Audit log for this post</h2>
            <span class="section-count">{post.audit_log.length}</span>
          </header>
          {#if post.audit_log.length === 0}
            <p class="empty-text">No admin actions recorded on this post yet.</p>
          {:else}
            <ul class="audit-list">
              {#each post.audit_log as a (a.id)}
                <li class="audit-row">
                  <span class="audit-action">{a.action}</span>
                  {#if a.actor}
                    <span>by <a href="/@{a.actor.handle}">@{a.actor.handle}</a></span>
                  {:else}
                    <span class="muted">by system</span>
                  {/if}
                  <span class="muted">· {formatDate(a.created_at)}</span>
                  {#if a.details && Object.keys(a.details).length > 0}
                    <details class="audit-details">
                      <summary>details</summary>
                      <pre>{JSON.stringify(a.details, null, 2)}</pre>
                    </details>
                  {/if}
                </li>
              {/each}
            </ul>
          {/if}
        </section>
      </div>

      <!-- RIGHT: actions sidebar -->
      <aside class="actions-col">
        <section class="card actions-card">
          <h2 class="actions-title">Actions</h2>
          {#if post.deleted_at}
            <p class="muted">This post is soft-deleted. No further actions available.</p>
          {:else}
            <button
              class="btn btn-outline btn-full"
              type="button"
              disabled={acting}
              onclick={handleToggleSensitive}
            >
              {post.sensitive ? 'Remove sensitive flag' : 'Mark as sensitive'}
            </button>
            <button
              class="btn btn-danger btn-full"
              type="button"
              disabled={acting}
              onclick={handleDelete}
            >
              Delete post
            </button>
          {/if}
        </section>

        <section class="card meta-card">
          <h2 class="meta-title">Metadata</h2>
          <dl class="meta-list">
            <dt>Post ID</dt>
            <dd class="mono">{post.id}</dd>
            {#if post.ap_id}
              <dt>AP ID</dt>
              <dd class="mono wrap">{post.ap_id}</dd>
            {/if}
            <dt>Created</dt>
            <dd>{formatDate(post.created_at)}</dd>
            {#if post.published_at && post.published_at !== post.created_at}
              <dt>Published</dt>
              <dd>{formatDate(post.published_at)}</dd>
            {/if}
            {#if post.edited_at}
              <dt>Edited</dt>
              <dd>{formatDate(post.edited_at)}</dd>
            {/if}
            {#if post.deleted_at}
              <dt>Deleted</dt>
              <dd>{formatDate(post.deleted_at)}</dd>
            {/if}
            {#if post.parent_id}
              <dt>Reply to</dt>
              <dd><a href="/admin/posts/{post.parent_id}" class="mono">{post.parent_id.slice(0, 8)}…</a></dd>
            {/if}
            {#if post.quote_id}
              <dt>Quoting</dt>
              <dd><a href="/admin/posts/{post.quote_id}" class="mono">{post.quote_id.slice(0, 8)}…</a></dd>
            {/if}
          </dl>
        </section>

        {#if post.identity}
          <section class="card author-card">
            <h2 class="author-title">Author</h2>
            <p>
              <a href="/@{post.identity.handle}" class="author-link">
                @{post.identity.handle}
              </a>
            </p>
            <p class="author-stat">
              Pending reports against this user:
              <strong class:stat-hot={post.author_pending_reports > 0}>
                {post.author_pending_reports}
              </strong>
            </p>
            <p class="author-stat">
              <a href="/admin/user-management/users?id={post.identity.id}">Manage user →</a>
            </p>
          </section>
        {/if}
      </aside>
    </div>
  {/if}
</div>

<style>
  .post-detail-page {
    max-width: 1200px;
  }

  .back-link {
    display: inline-block;
    margin-block-end: var(--space-4);
    color: var(--color-text-secondary);
    font-size: var(--text-sm);
    text-decoration: none;
  }

  .back-link:hover {
    color: var(--color-primary);
  }

  .not-found {
    padding: var(--space-8);
    text-align: center;
  }

  .not-found-title {
    font-size: var(--text-xl);
    font-weight: 700;
    margin-block-end: var(--space-2);
  }

  .not-found-text {
    color: var(--color-text-secondary);
    font-size: var(--text-sm);
  }

  .layout {
    display: grid;
    grid-template-columns: minmax(0, 1fr) 320px;
    gap: var(--space-4);
    align-items: flex-start;
  }

  .main-col {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    min-width: 0;
  }

  .actions-col {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
    position: sticky;
    top: var(--space-4);
  }

  /* Post card */
  .post-card {
    padding: var(--space-5);
  }

  .post-deleted {
    opacity: 0.65;
  }

  .post-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: var(--space-3);
    margin-block-end: var(--space-3);
    flex-wrap: wrap;
  }

  .author {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .author-name {
    font-weight: 700;
    font-size: var(--text-base);
    color: var(--color-text);
    text-decoration: none;
  }

  .author-handle {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
  }

  .post-meta {
    display: flex;
    gap: var(--space-1);
    flex-wrap: wrap;
  }

  .visibility-badge, .badge {
    font-size: 0.7rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    padding: 2px 8px;
    border-radius: var(--radius-full);
  }

  .vis-public, .badge-info { background: var(--color-info-soft); color: #1e40af; }
  .vis-unlisted { background: var(--color-surface); color: var(--color-text-secondary); }
  .vis-followers { background: var(--color-secondary-container); color: var(--color-primary); }
  .vis-direct { background: #fef3c7; color: #92400e; }
  .badge-warning { background: #fef3c7; color: #92400e; }
  .badge-danger { background: var(--color-danger-soft); color: #991b1b; }
  .badge-neutral { background: var(--color-surface); color: var(--color-text-secondary); }

  .spoiler {
    font-size: var(--text-sm);
    padding: var(--space-2) var(--space-3);
    background: #fef3c7;
    border-radius: var(--radius-md);
    color: #92400e;
    margin-block-end: var(--space-3);
  }

  .post-body {
    font-size: var(--text-base);
    line-height: 1.6;
    word-break: break-word;
  }

  .post-body-plain {
    white-space: pre-wrap;
  }

  .post-body-empty {
    color: var(--color-text-tertiary);
    font-style: italic;
  }

  .media-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
    gap: var(--space-2);
    margin-block-start: var(--space-3);
  }

  .media-thumb {
    width: 100%;
    max-height: 240px;
    object-fit: cover;
    border-radius: var(--radius-md);
    background: var(--color-surface);
  }

  .media-unknown {
    display: flex;
    align-items: center;
    justify-content: center;
    min-height: 120px;
    background: var(--color-surface);
    border-radius: var(--radius-md);
    color: var(--color-text-secondary);
    font-size: var(--text-xs);
    font-family: var(--font-mono);
  }

  .post-footer {
    display: flex;
    gap: var(--space-4);
    margin-block-start: var(--space-4);
    padding-block-start: var(--space-3);
    border-block-start: 1px solid var(--color-border);
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
  }

  /* Sections */
  .section {
    padding: var(--space-5);
  }

  .section-header {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    margin-block-end: var(--space-3);
  }

  .section-title {
    font-size: var(--text-base);
    font-weight: 700;
  }

  .section-count {
    font-size: var(--text-xs);
    font-weight: 600;
    color: var(--color-text-secondary);
    background: var(--color-surface);
    padding: 2px 8px;
    border-radius: var(--radius-full);
  }

  .empty-text {
    font-size: var(--text-sm);
    color: var(--color-text-tertiary);
  }

  .report-list, .audit-list {
    list-style: none;
    padding: 0;
    margin: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }

  .report-row {
    padding: var(--space-2) var(--space-3);
    background: var(--color-surface);
    border-radius: var(--radius-md);
    border-inline-start: 3px solid var(--color-danger);
  }

  .report-closed {
    border-inline-start-color: var(--color-border);
    opacity: 0.7;
  }

  .report-head {
    display: flex;
    gap: var(--space-2);
    align-items: baseline;
    flex-wrap: wrap;
    font-size: var(--text-sm);
  }

  .report-category {
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    font-size: var(--text-xs);
    color: var(--color-danger);
  }

  .report-status {
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
    text-transform: uppercase;
  }

  .report-comment {
    font-size: var(--text-sm);
    color: var(--color-text);
    margin-block-start: var(--space-1);
  }

  .audit-row {
    padding: var(--space-2);
    font-size: var(--text-sm);
    border-block-end: 1px solid var(--color-border);
  }

  .audit-row:last-child {
    border: none;
  }

  .audit-action {
    font-family: var(--font-mono);
    font-size: var(--text-xs);
    font-weight: 600;
    color: var(--color-primary);
    margin-inline-end: var(--space-2);
  }

  .audit-details {
    margin-block-start: var(--space-1);
  }

  .audit-details summary {
    cursor: pointer;
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
  }

  .audit-details pre {
    font-family: var(--font-mono);
    font-size: var(--text-xs);
    background: var(--color-surface);
    padding: var(--space-2);
    border-radius: var(--radius-sm);
    overflow-x: auto;
  }

  .muted {
    color: var(--color-text-tertiary);
  }

  /* Sidebar */
  .actions-card, .meta-card, .author-card {
    padding: var(--space-4);
  }

  .actions-title, .meta-title, .author-title {
    font-size: var(--text-sm);
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--color-text-secondary);
    margin-block-end: var(--space-3);
  }

  .btn-full {
    display: block;
    width: 100%;
    margin-block-end: var(--space-2);
  }

  .meta-list {
    display: grid;
    grid-template-columns: auto 1fr;
    gap: var(--space-2) var(--space-3);
    margin: 0;
    font-size: var(--text-xs);
  }

  .meta-list dt {
    color: var(--color-text-secondary);
    font-weight: 600;
  }

  .meta-list dd {
    margin: 0;
    min-width: 0;
    word-break: break-word;
  }

  .mono {
    font-family: var(--font-mono);
  }

  .wrap {
    word-break: break-all;
  }

  .author-link {
    font-weight: 600;
    color: var(--color-primary);
    text-decoration: none;
  }

  .author-stat {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    margin-block-start: var(--space-2);
  }

  .stat-hot {
    color: var(--color-danger);
  }

  @media (max-width: 1000px) {
    .layout {
      grid-template-columns: 1fr;
    }

    .actions-col {
      position: static;
    }
  }
</style>
