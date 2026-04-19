<script lang="ts">
  import type { MediaAttachment, Identity } from '$lib/api/types.js';
  import { autoLoadRemoteMedia } from '$lib/utils/media-preferences.js';
  import AudioPlayer from './AudioPlayer.svelte';

  let {
    media,
    isRemote,
    author = null,
  }: {
    media: MediaAttachment;
    isRemote: boolean;
    author?: Identity | null;
  } = $props();

  // Local media or "auto-load" preference ON → always render.
  // Remote + opt-out ON → render placeholder until tapped.
  let userTapped = $state(false);
  let shouldRender = $derived(!isRemote || $autoLoadRemoteMedia || userTapped);

  function reveal(e: MouseEvent | KeyboardEvent) {
    e.stopPropagation();
    userTapped = true;
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      reveal(e);
    }
  }

  // Domain pulled from the original remote URL so the placeholder
  // shows where the bytes would come from. Uses URL constructor
  // safely — falls back to empty string on parse failure.
  let originDomain = $derived.by(() => {
    if (!media.remote_url) return '';
    try {
      return new URL(media.remote_url).hostname;
    } catch {
      return '';
    }
  });

  let typeIcon = $derived.by(() => {
    switch (media.type) {
      case 'image':
      case 'gifv':
        return 'image';
      case 'video':
        return 'play_circle';
      case 'audio':
        return 'volume_up';
      default:
        return 'attachment';
    }
  });

  let dimensionsLabel = $derived.by(() => {
    const original = (media.meta as { original?: { width?: number; height?: number } } | undefined)
      ?.original;
    if (original && typeof original.width === 'number' && typeof original.height === 'number') {
      return `${original.width} × ${original.height}`;
    }
    return '';
  });
</script>

{#if shouldRender}
  {#if media.type === 'image' || media.type === 'gifv'}
    <img
      src={media.preview_url || media.url}
      alt={media.description || ''}
      class="media-img"
      loading="lazy"
    />
  {:else if media.type === 'video'}
    <video
      src={media.url}
      controls
      preload="metadata"
      class="media-video"
      aria-label={media.description || 'Video attachment'}
    >
      <track kind="captions" />
    </video>
  {:else if media.type === 'audio'}
    <AudioPlayer {media} {author} />
  {/if}
{:else}
  <button
    type="button"
    class="lazy-placeholder"
    onclick={reveal}
    onkeydown={handleKeydown}
    aria-label={`Load ${media.type} from ${originDomain}`}
  >
    <span class="material-symbols-outlined lazy-icon" aria-hidden="true">{typeIcon}</span>
    <span class="lazy-cta">Tap to load {media.type}</span>
    {#if originDomain}
      <span class="lazy-meta">from {originDomain}{dimensionsLabel ? ` · ${dimensionsLabel}` : ''}</span>
    {/if}
    {#if media.description}
      <span class="lazy-desc">{media.description}</span>
    {/if}
  </button>
{/if}

<style>
  .lazy-placeholder {
    width: 100%;
    height: 100%;
    min-height: 160px;
    background: var(--color-surface-alt, rgba(0, 0, 0, 0.05));
    border: 1px dashed var(--color-border);
    border-radius: var(--radius-md, 8px);
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: var(--space-1, 4px);
    padding: var(--space-3, 12px);
    cursor: pointer;
    color: var(--color-text-secondary);
    text-align: center;
    transition: background-color 0.15s ease, border-color 0.15s ease;
  }

  .lazy-placeholder:hover,
  .lazy-placeholder:focus-visible {
    background: var(--color-surface-hover, rgba(0, 0, 0, 0.08));
    border-color: var(--color-primary, #3b82f6);
    color: var(--color-text);
    outline: none;
  }

  .lazy-icon {
    font-size: 32px !important;
    opacity: 0.7;
  }

  .lazy-cta {
    font-size: var(--text-sm, 0.875rem);
    font-weight: 600;
  }

  .lazy-meta {
    font-size: var(--text-xs, 0.75rem);
    color: var(--color-text-tertiary);
  }

  .lazy-desc {
    font-size: var(--text-xs, 0.75rem);
    color: var(--color-text-tertiary);
    font-style: italic;
    max-width: 80%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .media-img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }

  .media-video {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
    background: black;
  }
</style>
