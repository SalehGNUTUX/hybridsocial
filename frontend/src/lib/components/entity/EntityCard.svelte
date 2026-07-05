<script lang="ts">
  import Avatar from '$lib/components/ui/Avatar.svelte';

  // One shared directory card for any entity (Groups, Pages). Both the
  // /groups and /pages lists use it so their grids look identical — a
  // banner, an overlapping avatar, name (+ handle), a clamped
  // description, and a badge + count meta row.
  let {
    name,
    handle = null,
    avatarUrl = null,
    coverUrl = null,
    description = null,
    /** Category / visibility chip (e.g. "Health", "Public"). */
    badge = null,
    /** Numeric count (formatted here); paired with `countLabel`. */
    count = null,
    /** Noun for the count (e.g. "followers", "members"). */
    countLabel = null,
    /** Link target — renders an <a>. If omitted, renders a <button>. */
    href = null,
    onclick,
  }: {
    name: string;
    handle?: string | null;
    avatarUrl?: string | null;
    coverUrl?: string | null;
    description?: string | null;
    badge?: string | null;
    count?: number | null;
    countLabel?: string | null;
    href?: string | null;
    onclick?: () => void;
  } = $props();

  function fmtCount(n: number): string {
    if (n < 1000) return String(n);
    if (n < 1_000_000) return (n / 1000).toFixed(n < 10_000 ? 1 : 0) + 'K';
    return (n / 1_000_000).toFixed(1) + 'M';
  }
</script>

{#snippet inner()}
  <div class="ec-banner">
    {#if coverUrl}
      <img src={coverUrl} alt="" class="ec-banner-img" loading="lazy" />
    {:else}
      <div class="ec-banner-fallback" aria-hidden="true"></div>
    {/if}
  </div>
  <div class="ec-body">
    <div class="ec-avatar">
      <Avatar src={avatarUrl} {name} size="lg" />
    </div>
    <div class="ec-info">
      <h3 class="ec-name" title={name}>{name}</h3>
      {#if handle}<span class="ec-handle">@{handle}</span>{/if}
      {#if description}<p class="ec-desc">{description}</p>{/if}
      {#if badge || count != null}
        <div class="ec-meta">
          {#if badge}<span class="ec-badge">{badge}</span>{/if}
          {#if count != null}
            <span class="ec-count"><strong>{fmtCount(count)}</strong> {countLabel}</span>
          {/if}
        </div>
      {/if}
    </div>
  </div>
{/snippet}

{#if href}
  <a class="ec" {href}>{@render inner()}</a>
{:else}
  <button type="button" class="ec" {onclick}>{@render inner()}</button>
{/if}

<style>
  .ec {
    display: flex;
    flex-direction: column;
    background: var(--color-surface-container-lowest);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-xl);
    overflow: hidden;
    text-align: start;
    color: var(--color-text);
    text-decoration: none;
    cursor: pointer;
    width: 100%;
    padding: 0;
    box-shadow: var(--shadow-sm);
    transition:
      box-shadow var(--transition-base),
      transform var(--transition-base),
      border-color var(--transition-base);
  }

  .ec:hover {
    transform: translateY(-2px);
    box-shadow: 0 2px 4px rgba(25, 28, 29, 0.05), 0 14px 34px rgba(0, 106, 105, 0.1);
    border-color: rgba(0, 106, 105, 0.18);
    text-decoration: none;
  }

  .ec-banner {
    height: 96px;
    overflow: hidden;
  }

  .ec-banner-img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }

  .ec-banner-fallback {
    width: 100%;
    height: 100%;
    background:
      radial-gradient(circle at 80% -20%, rgba(255, 255, 255, 0.25), transparent 45%),
      var(--gradient-primary);
  }

  .ec-body {
    padding: 0 var(--space-4) var(--space-4);
  }

  /* Avatar overlaps the banner, ringed like the profile header. */
  .ec-avatar {
    margin-block-start: -30px;
    margin-block-end: var(--space-2);
    width: fit-content;
  }

  .ec-avatar :global(.avatar) {
    border: 3px solid var(--color-surface-container-lowest);
    box-shadow: var(--shadow-sm);
  }

  .ec-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .ec-name {
    font-size: var(--text-base);
    font-weight: 700;
    color: var(--color-text);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .ec-handle {
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
  }

  .ec-desc {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    line-height: 1.45;
    margin-block-start: var(--space-1);
    /* Two-line clamp keeps card heights uniform across the grid. */
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  .ec-meta {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    flex-wrap: wrap;
    margin-block-start: var(--space-3);
  }

  .ec-badge {
    font-size: var(--text-xs);
    font-weight: 600;
    color: var(--color-primary);
    background: var(--color-primary-soft);
    padding: 2px var(--space-2);
    border-radius: var(--radius-full);
    text-transform: capitalize;
  }

  .ec-count {
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
  }

  .ec-count strong {
    color: var(--color-text);
    font-weight: 700;
  }
</style>
