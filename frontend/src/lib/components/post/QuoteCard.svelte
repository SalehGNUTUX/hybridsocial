<script lang="ts">
  import type { Post } from '$lib/api/types.js';
  import { goto } from '$app/navigation';
  import { relativeTime, fullDateTime } from '$lib/utils/time.js';
  import AccountTypeIndicator from '$lib/components/ui/AccountTypeIndicator.svelte';
  import LazyMedia from '$lib/components/post/LazyMedia.svelte';

  let {
    post,
  }: {
    post: Post;
  } = $props();

  let displayName = $derived(post.account.display_name || post.account.handle);
  let handle = $derived(`@${post.account.handle}`);
  let timeAgo = $derived(relativeTime(post.created_at));
  let fullDate = $derived(fullDateTime(post.created_at));
  let media = $derived(post.media_attachments || []);
  let mediaCount = $derived(media.length);
  let poll = $derived(post.poll);
  let pollVotesTotal = $derived(
    poll ? (poll.votes_count ?? poll.options.reduce((s, o) => s + (o.votes_count || 0), 0)) : 0
  );
  // Match PostCard's grid layout (single / two / three / four).
  let mediaGridClass = $derived(
    mediaCount === 1
      ? 'quote-media-grid-1'
      : mediaCount === 2
        ? 'quote-media-grid-2'
        : mediaCount === 3
          ? 'quote-media-grid-3'
          : 'quote-media-grid-4'
  );

  function navigateToQuote(e: MouseEvent) {
    e.stopPropagation();
    goto(`/post/${post.id}`);
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      e.stopPropagation();
      goto(`/post/${post.id}`);
    }
  }
</script>

<div
  class="quote-card"
  role="article"
  tabindex="0"
  onclick={navigateToQuote}
  onkeydown={handleKeydown}
  aria-label="Quoted post by {displayName}"
>
  <div class="quote-header">
    <img src={post.account.avatar_url || '/images/default-avatar.svg'} alt="" class="quote-avatar" loading="lazy" />
    <span class="quote-name">{displayName}</span>
    <AccountTypeIndicator account={post.account} size={12} />
    <span class="quote-handle">{handle}</span>
    <span class="quote-separator" aria-hidden="true">&middot;</span>
    <time class="quote-time" datetime={post.created_at} title={fullDate}>{timeAgo}</time>
  </div>

  {#if post.content_html}
    <div class="quote-content">
      {@html post.content_html}
    </div>
  {:else if post.content}
    <div class="quote-content">
      <p>{post.content}</p>
    </div>
  {/if}

  {#if mediaCount > 0}
    <div class="quote-media-grid {mediaGridClass}">
      {#each media as m (m.id)}
        <div
          class="quote-media-item"
          class:quote-media-video={m.type === 'video'}
          class:quote-media-audio={m.type === 'audio'}
        >
          <LazyMedia media={m} isRemote={!!m.remote_url} author={post.account} />
        </div>
      {/each}
    </div>
  {/if}

  {#if poll}
    <div class="quote-poll" aria-label="Quoted poll">
      {#each poll.options as option, i (i)}
        {@const pct = pollVotesTotal > 0 ? Math.round(((option.votes_count || 0) / pollVotesTotal) * 100) : 0}
        <div class="quote-poll-option">
          <div class="quote-poll-bar" style="width: {pct}%"></div>
          <span class="quote-poll-label">{option.title}</span>
          <span class="quote-poll-pct">{pct}%</span>
        </div>
      {/each}
      <div class="quote-poll-meta">
        {poll.voters_count ?? pollVotesTotal} {(poll.voters_count ?? pollVotesTotal) === 1 ? 'voter' : 'voters'}
        {#if poll.expired}&middot; closed{/if}
      </div>
    </div>
  {/if}
</div>

<style>
  .quote-card {
    margin-block-start: var(--space-3);
    padding: var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-lg);
    cursor: pointer;
    transition: background-color var(--transition-fast);
  }

  .quote-card:hover {
    background: var(--color-bg-secondary);
  }

  .quote-card:focus-visible {
    outline: 2px solid var(--color-primary);
    outline-offset: 1px;
  }

  .quote-header {
    display: flex;
    align-items: center;
    gap: var(--space-1);
    margin-block-end: var(--space-2);
    font-size: var(--text-sm);
  }

  .quote-avatar {
    width: 20px;
    height: 20px;
    border-radius: var(--radius-full);
    object-fit: cover;
  }

  .quote-avatar-placeholder {
    width: 20px;
    height: 20px;
    border-radius: var(--radius-full);
    background: var(--color-primary);
    color: var(--color-text-inverse);
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: var(--text-xs);
    font-weight: var(--font-semibold);
  }

  .quote-name {
    font-weight: var(--font-semibold);
    color: var(--color-text);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .quote-handle {
    color: var(--color-text-tertiary);
  }

  .quote-separator {
    color: var(--color-text-tertiary);
  }

  .quote-time {
    color: var(--color-text-tertiary);
  }

  .quote-content {
    font-size: var(--text-sm);
    line-height: var(--leading-relaxed);
    color: var(--color-text);
    overflow: hidden;
    display: -webkit-box;
    -webkit-line-clamp: 4;
    -webkit-box-orient: vertical;
  }

  .quote-content :global(a) {
    color: var(--color-primary);
  }

  .quote-media-grid {
    display: grid;
    gap: 2px;
    margin-block-start: var(--space-2);
    border-radius: var(--radius-md);
    overflow: hidden;
    max-height: 320px;
  }

  .quote-media-grid-1 {
    grid-template-columns: 1fr;
  }
  .quote-media-grid-2 {
    grid-template-columns: 1fr 1fr;
  }
  .quote-media-grid-3 {
    grid-template-columns: 1fr 1fr;
    grid-template-rows: 1fr 1fr;
  }
  .quote-media-grid-3 .quote-media-item:first-child {
    grid-row: span 2;
  }
  .quote-media-grid-4 {
    grid-template-columns: 1fr 1fr;
    grid-template-rows: 1fr 1fr;
  }

  .quote-media-item {
    overflow: hidden;
    background: var(--color-surface);
    aspect-ratio: 16 / 9;
    max-height: 320px;
  }

  .quote-media-grid-1 .quote-media-item {
    aspect-ratio: auto;
  }

  .quote-media-video {
    background: #000;
  }

  .quote-media-item :global(img),
  .quote-media-item :global(video) {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }

  .quote-media-grid-1 .quote-media-item :global(img),
  .quote-media-grid-1 .quote-media-item :global(video) {
    object-fit: contain;
    max-height: 320px;
  }

  .quote-poll {
    display: flex;
    flex-direction: column;
    gap: 6px;
    margin-block-start: var(--space-2);
  }

  .quote-poll-option {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 6px 10px;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    overflow: hidden;
    font-size: var(--text-sm);
  }

  .quote-poll-bar {
    position: absolute;
    inset-block: 0;
    inset-inline-start: 0;
    background: var(--color-primary);
    opacity: 0.18;
    transition: width 200ms ease;
  }

  .quote-poll-label,
  .quote-poll-pct {
    position: relative;
    color: var(--color-text);
  }

  .quote-poll-pct {
    color: var(--color-text-secondary);
    font-variant-numeric: tabular-nums;
  }

  .quote-poll-meta {
    color: var(--color-text-tertiary);
    font-size: var(--text-xs);
  }
</style>
