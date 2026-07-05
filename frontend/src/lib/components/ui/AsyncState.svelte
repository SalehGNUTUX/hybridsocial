<script lang="ts">
  import type { Snippet } from 'svelte';

  // Shared loading / error / empty scaffold for pages that fetch a list
  // into local state (scheduled, streams, lists, …). The caller owns the
  // data + the loaded markup (`children`); this component just decides
  // which of the four states to show and provides consistent skeleton,
  // error-with-retry, and empty visuals. Feeds use `FeedList` instead —
  // it has its own scaffold plus pagination.
  let {
    loading = false,
    error = '',
    isEmpty = false,
    emptyTitle = 'Nothing here yet',
    emptyText = '',
    skeletonCount = 3,
    onretry,
    skeleton,
    empty,
    children,
  }: {
    loading?: boolean;
    /** Non-empty string switches to the error state and is shown as the message. */
    error?: string;
    isEmpty?: boolean;
    emptyTitle?: string;
    emptyText?: string;
    /** How many generic skeleton rows to render when no `skeleton` snippet is given. */
    skeletonCount?: number;
    onretry?: () => void;
    /** Custom skeleton markup matching the page's real layout. */
    skeleton?: Snippet;
    /** Custom empty-state markup (overrides emptyTitle/emptyText). */
    empty?: Snippet;
    children: Snippet;
  } = $props();
</script>

{#if loading}
  {#if skeleton}
    {@render skeleton()}
  {:else}
    <div class="async-skel" aria-hidden="true">
      {#each Array(skeletonCount) as _, i (i)}
        <div class="async-skel-card">
          <div class="async-skel-line lg"></div>
          <div class="async-skel-line sm"></div>
        </div>
      {/each}
    </div>
  {/if}
{:else if error}
  <div class="async-state" role="alert">
    <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="var(--color-text-tertiary)" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <circle cx="12" cy="12" r="10" /><line x1="12" y1="8" x2="12" y2="12" /><line x1="12" y1="16" x2="12.01" y2="16" />
    </svg>
    <p class="async-state-title">{error}</p>
    {#if onretry}
      <button type="button" class="async-retry" onclick={onretry}>Retry</button>
    {/if}
  </div>
{:else if isEmpty}
  {#if empty}
    {@render empty()}
  {:else}
    <div class="async-state">
      <p class="async-state-title">{emptyTitle}</p>
      {#if emptyText}<p class="async-state-text">{emptyText}</p>{/if}
    </div>
  {/if}
{:else}
  {@render children()}
{/if}

<style>
  .async-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: var(--space-3);
    padding: var(--space-16) var(--space-4);
    text-align: center;
  }

  .async-state-title {
    font-size: var(--text-base);
    font-weight: 600;
    color: var(--color-text);
  }

  .async-state-text {
    font-size: var(--text-sm);
    color: var(--color-text-tertiary);
    max-width: 320px;
    line-height: 1.5;
  }

  .async-retry {
    display: inline-flex;
    align-items: center;
    padding: var(--space-2) var(--space-4);
    background: transparent;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    font-size: var(--text-sm);
    color: var(--color-text);
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .async-retry:hover {
    background: var(--color-surface);
  }

  /* Generic fallback skeleton */
  .async-skel {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }

  .async-skel-card {
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: var(--space-4);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-xl);
  }

  .async-skel-line {
    height: 12px;
    border-radius: var(--radius-sm);
    background: var(--color-border);
  }

  .async-skel-line.lg { width: 80%; }
  .async-skel-line.sm { width: 45%; }

  @media (prefers-reduced-motion: no-preference) {
    .async-skel-line {
      animation: async-skel-pulse 1.5s ease-in-out infinite;
    }
  }

  @keyframes async-skel-pulse {
    0%, 100% { opacity: 0.4; }
    50% { opacity: 0.7; }
  }
</style>
