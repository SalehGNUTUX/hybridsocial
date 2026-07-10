<script lang="ts">
  // Grid of media tiles distilled from a list of posts. Each post can
  // have multiple attachments; we flatten them so the grid reads
  // attachment-first ("show me the photos") rather than post-first.
  // Click anywhere on a tile to jump to the originating post.

  import type { Post, MediaAttachment } from '$lib/api/types.js';
  import Spinner from '$lib/components/ui/Spinner.svelte';

  let {
    posts,
    loading = false,
    onloadmore,
    hasMore = false,
    emptyMessage = 'No media yet.',
  }: {
    posts: Post[];
    loading?: boolean;
    onloadmore?: () => void;
    hasMore?: boolean;
    emptyMessage?: string;
  } = $props();

  type Tile = {
    postId: string;
    attachment: MediaAttachment;
  };

  // Drop posts without media, then flatten so the grid is a flat list
  // of tiles keyed by attachment id. Image / gifv / video tiles render;
  // audio-only attachments are skipped because a square thumb of a
  // waveform doesn't carry information at this size.
  let tiles = $derived.by(() => {
    const out: Tile[] = [];
    for (const post of posts) {
      const atts = post.media_attachments || [];
      for (const att of atts) {
        if (att.type === 'image' || att.type === 'gifv' || att.type === 'video') {
          out.push({ postId: post.id, attachment: att });
        }
      }
    }
    return out;
  });
</script>

<div class="media-grid-wrapper">
  {#if tiles.length === 0 && !loading}
    <p class="media-empty">{emptyMessage}</p>
  {:else}
    <div class="media-grid">
      {#each tiles as t (t.attachment.id)}
        <a
          class="media-tile"
          href="/post/{t.postId}"
          aria-label="Open post"
        >
          {#if t.attachment.preview_url || t.attachment.url}
            <img
              src={t.attachment.preview_url || t.attachment.url}
              alt={t.attachment.description || ''}
              loading="lazy"
            />
          {/if}
          {#if t.attachment.type === 'video' || t.attachment.type === 'gifv'}
            <!-- Play-glyph overlay so videos read as distinct from
                 still images at thumbnail size. -->
            <span class="media-tile-badge" aria-hidden="true">
              <svg width="28" height="28" viewBox="0 0 24 24" fill="currentColor">
                <path d="M8 5v14l11-7z" />
              </svg>
            </span>
          {/if}
        </a>
      {/each}
    </div>
  {/if}

  {#if loading}
    <div class="media-loading"><Spinner /></div>
  {:else if hasMore && tiles.length > 0}
    <button type="button" class="media-load-more" onclick={() => onloadmore?.()}>
      Load more
    </button>
  {/if}
</div>

<style>
  .media-grid-wrapper {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }

  .media-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
    gap: 4px;
  }

  .media-tile {
    position: relative;
    display: block;
    aspect-ratio: 1 / 1;
    background: var(--color-surface);
    border-radius: var(--radius-sm);
    overflow: hidden;
    text-decoration: none;
    transition: transform var(--transition-fast);
  }

  .media-tile:hover {
    transform: scale(1.02);
  }

  .media-tile img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }

  .media-tile-badge {
    position: absolute;
    inset-block-end: 6px;
    inset-inline-end: 6px;
    width: 32px;
    height: 32px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    background: var(--scrim-medium);
    color: #fff;
    pointer-events: none;
  }

  .media-empty {
    color: var(--color-text-tertiary);
    text-align: center;
    padding: var(--space-6);
    font-size: var(--text-sm);
  }

  .media-loading {
    display: flex;
    justify-content: center;
    padding: var(--space-4);
  }

  .media-load-more {
    align-self: center;
    padding: var(--space-2) var(--space-4);
    background: transparent;
    border: 1px solid var(--color-border);
    color: var(--color-text-secondary);
    border-radius: var(--radius-md);
    cursor: pointer;
    font: inherit;
    font-size: var(--text-sm);
  }

  .media-load-more:hover {
    background: var(--color-surface);
    color: var(--color-text);
  }
</style>
